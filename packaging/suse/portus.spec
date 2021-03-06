#
# spec file for package portus
#
# Copyright (c) 2019 SUSE LINUX Products GmbH, Nuernberg, Germany.
#
# All modifications and additions to the file contributed by third parties
# remain the property of their copyright owners, unless otherwise agreed
# upon. The license for this file, and modifications and additions to the
# file, is the same license as for the pristine package itself (unless the
# license for the pristine package is not an Open Source License, in which
# case the license is the MIT License). An "Open Source License" is a
# license that conforms to the Open Source Definition (Version 1.9)
# published by the Open Source Initiative.

# Please submit bugfixes or comments via http://bugs.opensuse.org/
#

%define portusdir /srv/Portus

Name:           portus
Version:        0
Release:        0
License:        Apache-2.0
Summary:        Authorization service and fronted for Docker registry (v2)
Url:            https://github.com/SUSE/Portus
Group:          System/Management

Source0:        Portus-%{version}.tar.gz
# Generated with `yarn install` which produces a reproduceable `node_modules`
# directory thanks to the yarn.lock file defined in the Portus repo.
Source1:        node_modules.tar.gz
Source2:        yarn.lock

Requires:       timezone
Requires:       net-tools
Requires:       portusctl
%if 0%{?suse_version} >= 1210
BuildRequires: systemd-rpm-macros
%endif
BuildRequires:  fdupes
BuildRequires:  gcc-c++
BuildRequires:  ruby-macros >= 5
%{?systemd_requires}
Provides:       Portus = %{version}
Obsoletes:      Portus < %{version}
# Portus-20151120162040 was accidentaly released when it should have been Portus-2.0
# This is the reason why we are obsoleting it
Obsoletes:      Portus = 20151120162040

# Javascript engine to build assets. Note that yarn-packaging will automatically
# create the provides for the JS libs
BuildRequires:  nodejs6
BuildRequires:  nodejs-yarn
BuildRequires:  yarn-packaging

BuildRequires: libcurl-devel
Requires: libcurl4
BuildRequires: libffi-devel
BuildRequires: libxml2-devel libxslt-devel

# DB-related libraries.
BuildRequires: mysql-devel
BuildRequires: pkgconfig(libpq)

Requires: ruby(abi) = 2.6.0
BuildRequires: ruby2.6-devel
BuildRequires: rubygem(ruby:2.6.0:bundler)
BuildRequires: rubygem(ruby:2.6.0:gem2rpm)

BuildRoot:      %{_tmppath}/%{name}-%{version}-build

%description
Portus targets version 2 of the Docker registry API. It aims to act both as an
authoritzation server and as a user interface for the next generation of the
Docker registry.

%prep
%setup -q -n Portus-%{version}

%build
# Untar Javascript dependencies
cp %{SOURCE1} .
tar xzf node_modules.tar.gz

# Deal with Ruby gems.
# obs-service-bundle_gems will install gems in SOURCE/vendor/cache when using the cpio strategy
# https://github.com/openSUSE/obs-service-bundle_gems/
mkdir -p vendor/cache && cp %{_sourcedir}/vendor/cache/*.gem vendor/cache

# set up gem paths with vendor folder
export GEM_HOME=$PWD/vendor GEM_PATH=$PWD/vendor PATH=$PWD/vendor/bin:$PATH

#gem install vendor/cache/*.gem
bundle config build.nokogiri --use-system-libraries
bundle install --retry=3 --local --deployment --without test development

# Compile assets
PORTUS_SECRET_KEY_BASE="ap" PORTUS_KEY_PATH="ap" PORTUS_PASSWORD="ap" \
  INCLUDE_ASSETS_GROUP=yes RAILS_ENV=production NODE_ENV=production \
  bundle exec rake portus:assets:compile

# Install the final gems (i.e. exclude the `assets` group from the final
# bundle). Unfortunately, bundler does not have a way to remove gems from a
# given group. So, we have to remove all of them, and then install the ones we
# want...
rm -r vendor/bundle/ruby
bundle install --retry=3 --local --deployment --without test development assets
rm -r vendor/bundle/ruby/*/cache/*

# Patch landing_page
APPLICATION_CSS=$(find . -name application-*.css 2>/dev/null)
cp $APPLICATION_CSS public/landing.css

# Fix schema.rb softlink to its final destination
rm db/schema.rb
ln -s %{portusdir}/db/schema.mysql.rb db/schema.rb

# Save the commit so it can later be used by Portus.
echo "%{version}" > .gitcommit

# Remove unneeded directories/files
rm -rf \
   vendor/cache \
   node_modules \
   public/assets/application-*.js* \
   vendor/assets \
   examples \
   packaging \
   tmp \
   log \
   docker \
   doc \
   *.orig

# Removing irrelevant files for production.
declare -a ary=(
  ".gitignore" ".travis.yml" ".pelusa.yml" ".keep" ".rspec" ".codeclimate.yml"
  ".yardopts" ".ruby-gemset" ".rubocop.yml" ".document" ".eslintrc"
  ".eslintignore" ".env" ".dockerignore" ".editorconfig" ".erdconfig"
  "*.pem" ".rubocop_todo.yml" ".concourse.yml" "Dockerfile" "Vagrantfile"
  "node_modules.tar.gz" ".babelrc" "docker-compose.yml"
)
for i in "${ary[@]}"; do
  find . -name "$i" -type f -delete
done

# Remove directories.
find . -name "spec" -type d -exec rm -rf {} +
find vendor/bundle -name "test" -type d ! -path "*rack*/test" -exec rm -rf {} +
find . -name ".github" -type d -exec rm -rf {} +
find . -name ".empty_directory" -type d -delete

# Remove empty files which are not important.
find . -size 0 ! -path "*gem.build_complete" -delete

%install
install -d %{buildroot}%{portusdir}

cp -a . %{buildroot}%{portusdir}

mkdir %{buildroot}%{portusdir}/log
mkdir %{buildroot}%{portusdir}/tmp

%fdupes %{buildroot}%{portusdir}

%files
%defattr(-,root,root)
%dir %{portusdir}
%{portusdir}/.bundle
%{portusdir}/.gitcommit
%{portusdir}/.ruby-version
%{portusdir}/Gemfile
%{portusdir}/Gemfile.lock
%{portusdir}/Guardfile
%{portusdir}/Rakefile
%{portusdir}/VERSION
%{portusdir}/app
%{portusdir}/bin
%{portusdir}/config.ru
%{portusdir}/db
%{portusdir}/lib
%{portusdir}/log
%{portusdir}/package.json
%{portusdir}/public
%{portusdir}/tmp
%{portusdir}/vendor
%{portusdir}/yarn.lock

%doc %{portusdir}/README.md
%doc %{portusdir}/CONTRIBUTING.md
%doc %{portusdir}/CHANGELOG.md
%doc %{portusdir}/LICENSE

%config(noreplace) %{portusdir}/config

%changelog
