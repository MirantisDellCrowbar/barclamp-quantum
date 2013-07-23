
# Copyright (c) 2011 Dell Inc.
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

default[:quantum][:debug] = false
default[:quantum][:verbose] = false
default[:quantum][:dhcp_domain] = "openstack.local"
default[:quantum][:networking_mode] = "local"
default[:quantum][:networking_plugin] = "openvswitch"

default[:quantum][:db][:database] = "neutron"
default[:quantum][:db][:user] = "neutron"
default[:quantum][:db][:password] = "" # Set by Recipe
default[:quantum][:db][:ovs_database] = "ovs"
default[:quantum][:db][:ovs_user] = "ovs"
default[:quantum][:db][:ovs_password] = "" # Set by Recipe
default[:quantum][:network][:fixed_router] = "127.0.0.1" # Set by Recipe
default[:quantum][:network][:private_networks] = [] # Set by Recipe
# Default range for GRE tunnels
default[:quantum][:network][:gre_start] = 1
default[:quantum][:network][:gre_stop] = 1000


default[:quantum][:api][:protocol] = "http"
default[:quantum][:api][:service_port] = "9696"
default[:quantum][:api][:service_host] = "0.0.0.0"

default[:quantum][:sql][:idle_timeout] = 30
default[:quantum][:sql][:min_pool_size] = 5
default[:quantum][:sql][:max_pool_size] = 10
default[:quantum][:sql][:pool_timeout] = 200

default[:quantum][:ssl][:insecure] = false
default[:quantum][:ssl][:certfile] = "/etc/neutron/ssl/certs/signing_cert.pem"
default[:quantum][:ssl][:keyfile] = "/etc/neutron/ssl/private/signing_key.pem"
default[:quantum][:ssl][:cert_required] = false
default[:quantum][:ssl][:ca_certs] = "/etc/neutron/ssl/certs/ca.pem"

default[:quantum][:quantum_server] = false


case node["platform"]
when "suse"
  default[:quantum][:platform] = {
    :pkgs => [ "openstack-neutron-server",
               "openstack-neutron-l3-agent",
               "openstack-neutron-dhcp-agent",
               "openstack-neutron-metadata-agent" ],
    :service_name => "openstack-neutron",
    :ovs_agent_pkg => "openstack-neutron-openvswitch-agent",
    :ovs_agent_name => "openstack-neutron-openvswitch-agent",
    :lb_agent_pkg => "openstack-neutron-linuxbridge-agent",
    :lb_agent_name => "openstack-neutron-linuxbridge-agent",
    :metadata_agent_name => "openstack-neutron-metadata-agent",
    :dhcp_agent_name => "openstack-neutron-dhcp-agent",
    :l3_agent_name => "openstack-neutron-l3-agent",
    :ovs_pkgs => [ "openvswitch",
                   "openvswitch-switch",
                   "openvswitch-kmp-default" ],
    :user => "openstack-neutron",
    :ovs_modprobe => "modprobe openvswitch"
  }
else
  default[:quantum][:platform] = {
    :pkgs => [ "neutron-server",
               "neutron-l3-agent",
               "neutron-dhcp-agent",
               "neutron-plugin-openvswitch",
               "neutron-metadata-agent" ],
    :service_name => "neutron-server",
    :ovs_agent_pkg => "neutron-plugin-openvswitch-agent",
    :ovs_agent_name => "neutron-plugin-openvswitch-agent",
    :lb_agent_pkg => "neutron-plugin-linuxbridge-agent",
    :lb_agent_name => "neutron-plugin-linuxbridge-agent",
    :metadata_agent_name => "neutron-metadata-agent",
    :dhcp_agent_name => "neutron-dhcp-agent",
    :l3_agent_name => "neutron-l3-agent",
    :ovs_pkgs => [ "linux-headers-#{`uname -r`.strip}",
                   "openvswitch-switch",
                   "openvswitch-datapath-dkms" ],
    :user => "neutron",
    :ovs_modprobe => "modprobe openvswitch"
  }
end
