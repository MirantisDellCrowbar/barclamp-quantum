# recipe must be call from nova-compute node to install agents
quantum = search(:node, "roles:quantum-server AND quantum_config_environment:quantum-config-#{node[:nova][:quantum_instance]}").first

# Nova controller
nova = search(:node, "roles:nova-multi-controller").first

# Keystone server
keystone = search(:node, "recipes:keystone\\:\\:server AND keystone_config_environment:keystone-config-#{quantum[:quantum][:keystone_instance]}").first

# Rabbit server
rabbit = search(:node, "roles:rabbitmq-server AND rabbitmq_config_environment:rabbitmq-config-#{quantum[:quantum][:rabbitmq_instance]}").first

# Prepare network for quantum plugin
if quantum[:quantum][:networking_plugin] == "openvswitch"

  package "linux-headers-#{`uname -r`.strip}"
  execute "rmmod openvswitch" do
    only_if "modinfo openvswitch -Fintree | grep Y && lsmod | grep openvswitch"
  end
  package "openvswitch-datapath-dkms"
  package "openvswitch-switch"
  service "openvswitch-switch" do
    supports :status => true, :restart => true
    action [ :enable, :start ]
  end

  interface_driver = "quantum.agent.linux.interface.OVSInterfaceDriver"
  physnet = quantum[:quantum][:networking_mode] == 'gre' ? "br-tunnel" : "br-fixed"
  external_network_bridge = "br-public"
  # We always need br-int.  Quantum uses this bridge internally.
  execute "create_int_br" do
    command "ovs-vsctl add-br br-int"
    not_if "ovs-vsctl list-br | grep -q br-int"
  end
  # Make sure br-int is always up.
  ruby_block "Bring up the internal bridge" do
    block do
      ::Nic.new('br-int').up
    end
  end

  # Create the bridges Quantum needs.
  # Usurp config as needed.
  [ [ "nova_fixed", "fixed" ],
    [ "os_sdn", "tunnel" ],
    [ "public", "public"] ].each do |net|
    bound_if = (node[:crowbar_wall][:network][:nets][net[0]].last rescue nil)
    next unless bound_if
    name = "br-#{net[1]}"
    execute "Quantum: create #{name}" do
      command "ovs-vsctl add-br #{name}; ip link set #{name} up"
      not_if "ovs-vsctl list-br |grep -q #{name}"
    end
    next if net[1] == "tunnel"
    execute "Quantum: add #{bound_if} to #{name}" do
      command "ovs-vsctl del-port #{name} #{bound_if} ; ovs-vsctl add-port #{name} #{bound_if}"
      not_if "ovs-dpctl show system@#{name} | grep -q #{bound_if}"
    end
    ruby_block "Have #{name} usurp config from #{bound_if}" do
      block do
        target = ::Nic.new(name)
        res = target.usurp(bound_if)
        Chef::Log.info("#{name} usurped #{res[0].join(", ")} addresses from #{bound_if}") unless res[0].empty?
        Chef::Log.info("#{name} usurped #{res[1].join(", ")} routes from #{bound_if}") unless res[1].empty?
      end
    end
  end

elsif quantum[:quantum][:networking_plugin] == "linuxbridge"

  interface_driver = "quantum.agent.linux.interface.BridgeInterfaceDriver"
  physnet = (node[:crowbar_wall][:network][:nets][:nova_fixed].first rescue nil)
  external_network_bridge = ""

end

# Install quantum agents
agents = ["quantum-dhcp-agent","quantum-l3-agent","quantum-metadata-agent"]
agents << "quantum-openvswitch-agent" if quantum[:quantum][:networking_plugin] == "openvswitch"

unless quantum[:quantum][:use_gitrepo]
  agents.each do |agent|
    package agent
    service agent do
      supports :status => true, :restart => true, :reload => true
      action :nothing
    end
  end
else
  quantum_path = "/opt/quantum"
  venv_path = quantum[:quantum][:use_virtualenv] ? "#{quantum_path}/.venv" : nil

  pfs_and_install_deps "quantum" do
    cookbook "quantum"
    cnode quantum
    virtualenv venv_path
    path quantum_path
    wrap_bins ["quantum-rootwrap"]
  end

  pfs_and_install_deps "keystone" do
    cookbook "keystone"
    cnode keystone
    path File.join(quantum_path,".keystone")
    virtualenv venv_path
  end

  create_user_and_dirs quantum[:quantum][:platform]["user"]

  arguments = {
      "quantum-l3-agent" => "--config-file /etc/quantum/l3_agent.ini",
      "quantum-metadata-agent" => "--config-file /etc/quantum/metadata_agent.ini",
      "quantum-dhcp-agent" => "--config-file /etc/quantum/dhcp_agent.ini",
      "quantum-openvswitch-agent" => "--config-file /etc/quantum/ovs_agent.ini"
  }

  agents.each do |agent|
    link_service agent do
      virtualenv venv_path
      bin_name "#{agent} --config-dir /etc/quantum/ #{arguments[agent]}"
    end.run_action(:run)
    service agent do
      supports :status => true, :restart => true, :reload => true, :enable => true
      action :nothing
    end
  end

  execute "quantum_cp_policy.json" do
    command "cp /opt/quantum/etc/policy.json /etc/quantum/"
    creates "/etc/quantum/policy.json"
  end
  execute "quantum_cp_rootwrap" do
    command "cp -r /opt/quantum/etc/quantum/rootwrap.d /etc/quantum/rootwrap.d"
    creates "/etc/quantum/rootwrap.d"
  end
  cookbook_file "/etc/quantum/rootwrap.conf" do
    cookbook "quantum"
    source "quantum-rootwrap.conf"
    mode 00644
    owner "quantum"
  end
end

node[:quantum] ||= Mash.new
if not node[:quantum].has_key?("rootwrap")
  unless quantum[:quantum][:use_gitrepo]
    node.set[:quantum][:rootwrap] = "/usr/bin/quantum-rootwrap"
  else
    node.set[:quantum][:rootwrap] = "/usr/local/bin/quantum-rootwrap"
  end
end

# Update path to quantum-rootwrap in case the path above is wrong
ruby_block "Find quantum rootwrap" do
  block do
    found = false
    ENV['PATH'].split(':').each do |p|
      f = File.join(p,"quantum-rootwrap")
      next unless File.executable?(f)
      node.set[:quantum][:rootwrap] = f
      node.save
      found = true
      break
    end
    raise("Could not find quantum rootwrap binary!") unless found
  end
end

template "/etc/sudoers.d/quantum-rootwrap" do
  cookbook "quantum"
  source "quantum-rootwrap.erb"
  mode 0440
  variables(:user => "quantum", :binary => node[:quantum][:rootwrap])
end

# Collect keystone settings
keystone_settings = {
    :host => keystone[:fqdn],
    :protocol => keystone["keystone"]["api"]["protocol"],
    :service_port => keystone["keystone"]["api"]["service_port"],
    :admin_port => keystone["keystone"]["api"]["admin_port"],
    :service_tenant => keystone["keystone"]["service"]["tenant"],
    :service_user => quantum["quantum"]["service_user"],
    :service_password => quantum["quantum"]["service_password"]
}

# Collect metadate settings
metadata_settings = {
    :debug => quantum[:quantum][:debug],
    :region => "RegionOne",
    :host => Chef::Recipe::Barclamp::Inventory.get_network_by_type(nova, "admin").address,
    :port => "8775",
    :secret => (nova[:nova][:quantum_metadata_proxy_shared_secret] rescue '')
}

# Collect rabbit settings
rabbit_settings = {
    :address => Chef::Recipe::Barclamp::Inventory.get_network_by_type(rabbit, "admin").address,
    :port => rabbit[:rabbitmq][:port],
    :user => rabbit[:rabbitmq][:user],
    :password => rabbit[:rabbitmq][:password],
    :vhost => rabbit[:rabbitmq][:vhost]
}

# Configure OVS agent
template "/etc/quantum/ovs_agent.ini" do
  cookbook "quantum"
  source "ovs_agent.ini"
  owner "quantum"
  group "root"
  mode "0640"
  notifies :restart, "service[quantum-openvswitch-agent]", :immediately
end if quantum[:quantum][:networking_plugin] == "openvswitch"

# Configure L3 agent
template "/etc/quantum/l3_agent.ini" do
  cookbook "quantum"
  source "l3_agent.ini.erb"
  owner "quantum"
  group "root"
  mode "0640"
  variables(
      :debug => quantum[:quantum][:debug],
      :verbose => quantum[:quantum][:verbose],
      :interface_driver => interface_driver,
      :use_namespaces => "True",
      :handle_internal_only_routers => "True",
      :metadata_port => 9697,
      :send_arp_for_ha => 3,
      :periodic_interval => 40,
      :periodic_fuzzy_delay => 5
  )
  notifies :restart, "service[quantum-l3-agent]", :immediately
end

# configure DHCP agent
template "/etc/quantum/dhcp_agent.ini" do
  cookbook "quantum"
  source "dhcp_agent.ini.erb"
  owner "quantum"
  group "root"
  mode "0640"
  variables(
      :debug => quantum[:quantum][:debug],
      :verbose => quantum[:quantum][:verbose],
      :interface_driver => interface_driver,
      :use_namespaces => "True",
      :resync_interval => 5,
      :dhcp_driver => "quantum.agent.linux.dhcp.Dnsmasq",
      :dhcp_domain => quantum[:quantum][:dhcp_domain],
      :enable_isolated_metadata => "True",
      :enable_metadata_network => "False",
      :nameservers => quantum[:dns][:forwarders].join(" ")
  )
  notifies :restart, "service[quantum-dhcp-agent]", :immediately
end

# configure METADATA agent
template "/etc/quantum/metadata_agent.ini" do
  cookbook "quantum"
  source "metadata_agent.ini.erb"
  owner "quantum"
  group "root"
  mode "0640"
  variables(
      :debug => quantum[:quantum][:debug],
      :verbose => quantum[:quantum][:verbose],
      :keystone => keystone_settings,
      :metadata => metadata_settings
  )
  notifies :restart, "service[quantum-metadata-agent]", :immediately
end

# configure Quantum API paste
template "/etc/quantum/api-paste.ini" do
  cookbook "quantum"
  source "api-paste.ini.erb"
  owner "quantum"
  group "root"
  mode "0640"
  variables(
      :keystone => keystone_settings
  )
  notifies :restart, "service[quantum-l3-agent]", :immediately
  notifies :restart, "service[quantum-dhcp-agent]", :immediately
  notifies :restart, "service[quantum-metadata-agent]", :immediately
end

# configure Quantum
vlan = {
    :start => node[:network][:networks][:nova_fixed][:vlan],
    :end => node[:network][:networks][:nova_fixed][:vlan] + 2000
}
template "/etc/quantum/quantum.conf" do
  cookbook "quantum"
  source "quantum.conf.erb"
  mode "0640"
  owner node[:quantum][:platform][:user]
  variables(
      :sql_connection => quantum[:quantum][:db][:sql_connection],
      :sql_idle_timeout => quantum[:quantum][:sql][:idle_timeout],
      :sql_min_pool_size => quantum[:quantum][:sql][:min_pool_size],
      :sql_max_pool_size => quantum[:quantum][:sql][:max_pool_size],
      :sql_pool_timeout => quantum[:quantum][:sql][:pool_timeout],
      :debug => quantum[:quantum][:debug],
      :verbose => quantum[:quantum][:verbose],
      :service_port => quantum[:quantum][:api][:service_port], # Compute port
      :service_host => quantum[:quantum][:api][:service_host],
      :use_syslog => quantum[:quantum][:use_syslog],
      :networking_mode => quantum[:quantum][:networking_mode],
      :networking_plugin => quantum[:quantum][:networking_plugin],
      :rootwrap_bin =>  node[:quantum][:rootwrap],
      :quantum_server => false,
      :rabbit => rabbit_settings,
      :vlan => vlan,
      :per_tenant_vlan => (quantum[:quantum][:networking_mode] == 'vlan' ? true : false),
      :physnet => physnet,
      :interface_driver => interface_driver,
      :external_network_bridge => external_network_bridge,
      :metadata => metadata_settings
  )
  # TODO: return this if really needed
  notifies :restart, "service[quantum-l3-agent]", :immediately
  notifies :restart, "service[quantum-dhcp-agent]", :immediately
  notifies :restart, "service[quantum-metadata-agent]", :immediately
  notifies :restart, "service[quantum-openvswitch-agent]", :immediately if quantum[:quantum][:networking_plugin] == "openvswitch"
end