# frozen_string_literal: true

# == Schema Information
#
# Table name: registries
#
#  id                :integer          not null, primary key
#  name              :string(255)      not null
#  hostname          :string(255)      not null
#  created_at        :datetime         not null
#  updated_at        :datetime         not null
#  use_ssl           :boolean
#  external_hostname :string(255)
#
# Indexes
#
#  index_registries_on_hostname  (hostname) UNIQUE
#  index_registries_on_name      (name) UNIQUE
#

# Registry holds data regarding the registries registered in the Portus
# application.
#
# NOTE: currently only one Registry is allowed to exist in the database. This
# might change in the future.
class Registry < ApplicationRecord
  include PublicActivity::Common

  has_many :namespaces, dependent: :destroy

  validates :name, presence: true, uniqueness: true
  validates :hostname, presence: true, uniqueness: true
  validates :external_hostname, presence: false
  validates :use_ssl, inclusion: [true, false]

  # On create, make sure that all the needed namespaces are in place.
  after_create :create_namespaces!

  # Today the data model supports many registries however Portus just supports
  # on Registry therefore to avoid confusion, define just one way to ask for the
  # registy
  def self.get
    Registry.first
  end

  # Finds the registry with the given hostname. It first looks for the
  # `hostname` column, and then it fallbacks to `external_hostname`.
  def self.by_hostname_or_external(hostname)
    registry = Registry.find_by(hostname: hostname)
    if registry.nil?
      Rails.logger.debug("No hostname matching `#{hostname}', testing external_hostname")
      registry = Registry.find_by(external_hostname: hostname)
    end
    registry
  end

  # Returns the global namespace owned by this registry.
  def global_namespace
    Namespace.find_by(registry: self, global: true)
  end

  # Returns a registry client based on this registry that authenticates with
  # the credentials of the "portus" user.
  def client
    Portus::RegistryClient.new(hostname, use_ssl)
  end

  # Find the registry for the given push event.
  def self.find_from_event(event)
    request_hostname = event["request"]["host"]
    registry = Registry.find_by(hostname: request_hostname)
    if registry.nil?
      logger.debug("No hostname matching #{request_hostname}, testing external_hostname")
      registry = Registry.find_by(external_hostname: request_hostname)
    end
    logger.info("Ignoring event coming from unknown registry #{request_hostname}") if registry.nil?
    registry
  end

  # Fetch the information regarding a namespace on this registry for the given
  # event. If no namespace was found, then it returns nil. Otherwise, it
  # returns three values:
  #   - A Namespace object.
  #   - A String containing the name of the repository.
  #   - A String containing the name of the tag or nil if the `fetch_tag`
  #     parameter has been set to false.
  def get_namespace_from_event(event, fetch_tag = true)
    repo = event["target"]["repository"]
    if repo.include?("/")
      namespace_name, repo = repo.split("/", 2)
      namespace = namespaces.find_by(name: namespace_name)
    else
      namespace = global_namespace
    end

    if namespace.nil?
      logger.error "Cannot find namespace #{namespace_name} under registry #{hostname}"
      return
    end

    if fetch_tag
      tag_name = get_tag_from_target(namespace, repo, event["target"])
      return if tag_name.nil?
    else
      tag_name = nil
    end

    [namespace, repo, tag_name]
  end

  # Returns a Repository object for the given event. It returns nil if no
  # repository could be found from the given event.
  def get_repository_from_event(event, fetch_tag = true)
    ns, repo_name, = get_namespace_from_event(event, fetch_tag)
    return if ns.nil?

    repo = ns.repositories.find_by(name: repo_name)
    return if repo.nil? || repo.marked?

    repo
  end

  # Checks whether this registry is reachable. If it is, then an empty string
  # is returned. Otherwise a string will be returned containing the reasoning
  # of the reachability failure.
  def reachable?
    r = client.reachable?

    # All possible errors are already handled by the `reachable` method through
    # the `::Portus::Request` exception. If we are still facing an issue, the
    # assumption is that the given registry does not implement v2.
    r ? "" : "Error: registry does not implement v2 of the API."
  rescue ::Portus::RequestError => e
    e.message
  end

  # Returns the hostname value that should be priotized and used by the user.
  # In other words, whenever external hostname is present, that would be returned.
  # Otherwise the internal hostname is returned.1
  def reachable_hostname
    external_hostname.presence || hostname
  end

  protected

  # Fetch the tag being pushed through the given target object.
  def get_tag_from_target(namespace, repo, target)
    # Since Docker Distribution 2.4 the registry finally sends the tag, so we
    # don't have to perform requests afterwards.
    return target["tag"] if target["tag"].present?

    # Tough luck, we should now perform requests to fetch the tag. Note that
    # depending on the Manifest version we have to do one thing or another
    # because they expose different information.
    case target["mediaType"]
    when "application/vnd.docker.distribution.manifest.v1+json",
      "application/vnd.docker.distribution.manifest.v1+prettyjws"
      get_tag_from_manifest(target)
    when "application/vnd.docker.distribution.manifest.v2+json",
      "application/vnd.docker.distribution.manifest.list.v2+json"
      get_tag_from_list(namespace, repo)
    else
      raise ::Portus::RegistryClient::UnsupportedMediaType,
            "unsupported media type \"#{target["mediaType"]}\""
    end
  rescue ::Portus::RequestError, ::Portus::Errors::NotFoundError,
         ::Portus::RegistryClient::UnsupportedMediaType,
         ::Portus::RegistryClient::ManifestError => e
    logger.info("Could not fetch the tag for target #{target}")
    logger.info("Reason: #{e.message}")
    nil
  end

  # Fetch the tag by making the difference of what we've go on the DB, and
  # what's available on the registry. Returns a string with the tag on success,
  # otherwise it returns nil.
  def get_tag_from_list(namespace, repository)
    full_repo_name = namespace.global? ? repository : "#{namespace.name}/#{repository}"
    tags = client.tags(full_repo_name)
    return if tags.nil?

    repo = Repository.find_by(name: repository, namespace: namespace)
    return tags.first if repo.nil?

    resulting = tags - repo.tags.pluck(:name)

    # Note that it might happen that there are multiple tags not yet in sync
    # with Portus' DB. This means that the registry might have been
    # unresponsive for a long time. In this case, it's not such a problem to
    # pick up the first label, and wait for the CatalogJob to update the
    # rest.
    resulting.first
  end

  # Fetch the tag of the image contained in the current event. The Manifest API
  # is used to fetch it, thus the repo name and the digest are needed (and
  # they are contained inside the event's target).
  #
  # This method calls `::Portus::RegistryClient#manifest` but does not rescue
  # the possible exceptions. It's up to the called to rescue them.
  #
  # Returns the name of the tag if found, nil otherwise.
  def get_tag_from_manifest(target)
    manifest = client.manifest(target["repository"], target["digest"])
    manifest.mf["tag"]
  end

  # Create the global namespace for this registry and create the personal
  # namespace for all the existing users.
  def create_namespaces!
    count = Registry.count

    # Create the global team/namespace.
    team = Team.create(
      name:   "portus_global_team_#{count}",
      owners: User.where(admin: true),
      hidden: true
    )
    Namespace.create!(
      name:        "portus_global_namespace_#{count}",
      registry:    self,
      visibility:  Namespace.visibilities[:visibility_public],
      global:      true,
      description: "The global namespace for the registry #{Registry.name}.",
      team:        team
    )

    # TODO: change code once we support multiple registries
    User.find_each(&:create_personal_namespace!)
  end
end
