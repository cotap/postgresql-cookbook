# frozen_string_literal: true
#
# Cookbook:: postgresql
# Recipe:: server
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

Chef::Log.warn 'This cookbook is being re-written to use resources, not recipes and will only be Chef 13.8+ compatible. Please version pin to 6.1.1 to prevent the breaking changes from taking effect. See https://github.com/sous-chefs/postgresql/issues/512 for details'

::Chef::Recipe.send(:include, OpenSSLCookbook::RandomPassword)

include_recipe 'postgresql::client'

# randomly generate postgres password, unless using solo - see README
if Chef::Config[:solo]
  missing_attrs = %w(
    postgres
  ).select do |attr|
    node['postgresql']['password'][attr].nil?
  end.map { |attr| "node['postgresql']['password']['#{attr}']" }

  unless missing_attrs.empty?
    Chef::Log.fatal([
      "You must set #{missing_attrs.join(', ')} in chef-solo mode.",
      'For more information, see https://github.com/opscode-cookbooks/postgresql#chef-solo-note',
    ].join(' '))
    raise
  end
else
  # TODO: The "secure_password" is randomly generated plain text, so it
  # should be converted to a PostgreSQL specific "encrypted password" if
  # it should actually install a password (as opposed to disable password
  # login for user 'postgres'). However, a random password wouldn't be
  # useful if it weren't saved as clear text in Chef Server for later
  # retrieval.
  unless node.key?('postgresql') && node['postgresql'].key?('password') && node['postgresql']['password'].key?('postgres')
    node.normal_unless['postgresql']['password']['postgres'] = random_password(length: 20, mode: :base64)
    node.save
  end
end

# Include the right "family" recipe for installing the server
# since they do things slightly differently.
case node['platform_family']
when 'rhel', 'fedora'
  node.normal['postgresql']['dir'] = "/var/lib/pgsql/#{node['postgresql']['version']}/data"
  node.normal['postgresql']['config']['data_directory'] = "/var/lib/pgsql/#{node['postgresql']['version']}/data"
  include_recipe 'postgresql::server_redhat'
when 'debian'
  node.normal['postgresql']['config']['data_directory'] = "/var/lib/postgresql/9.3/main"
  include_recipe 'postgresql::server_debian'
when 'suse'
  node.normal['postgresql']['config']['data_directory'] = node['postgresql']['dir']
  include_recipe 'postgresql::server_redhat'
end

# Versions prior to 9.2 do not have a config file option to set the SSL
# key and cert path, and instead expect them to be in a specific location.

link ::File.join('/var/lib/postgresql/9.3/main/', 'server.crt') do
  to node['postgresql']['config']['ssl_cert_file']
  only_if { node['postgresql']['version'].to_f < 9.2 && node['postgresql']['config'].attribute?('ssl_cert_file') }
end

link ::File.join('/var/lib/postgresql/9.3/main/', 'server.key') do
  to node['postgresql']['config']['ssl_key_file']
  only_if { node['postgresql']['version'].to_f < 9.2 && node['postgresql']['config'].attribute?('ssl_key_file') }
end

# NOTE: Consider two facts before modifying "assign-postgres-password":
# (1) Passing the "ALTER ROLE ..." through the psql command only works
#     if passwordless authorization was configured for local connections.
#     For example, if pg_hba.conf has a "local all postgres ident" rule.
# (2) It is probably fruitless to optimize this with a not_if to avoid
#     setting the same password. This chef recipe doesn't have access to
#     the plain text password, and testing the encrypted (md5 digest)
#     version is not straight-forward.
bash 'assign-postgres-password' do
  user 'postgres'
  code <<-EOH
  echo "ALTER ROLE postgres ENCRYPTED PASSWORD \'#{node['postgresql']['password']['postgres']}\';" | psql -p #{node['postgresql']['config']['port']}
  EOH
  action :run
  not_if "ls /var/lib/postgresql/9.3/main/recovery.conf"
  only_if { node['postgresql']['assign_postgres_password'] }
end
