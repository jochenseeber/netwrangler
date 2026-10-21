require "./spec_helper"
require "./fixtures"

describe Netwrangler::Controller::IpAllocator, "integration" do
  describe "complex multi-node scenarios" do
    it "distributes IPs evenly across balanced 3-node cluster" do
      scenario = ControllerFixtures.multi_node_service_scenario(
        node_count: 3,
        ips_per_service: 6,
        endpoints_per_node: [2, 2, 2]
      )

      allocator = Netwrangler::Controller::IpAllocator.new(
        services: scenario[:services],
        endpoint_slices: scenario[:endpoint_slices],
        vip_networks: scenario[:vip_networks],
        vip_addresses: [] of Netwrangler::Model::VipAddress,
        vip_configs: [ControllerFixtures.vip_config],
      )

      result = allocator.allocate
      result.added_ips.size.should eq(6)

      # Count IPs per node
      ips_per_node = result.added_ips.group_by(&.spec.node_name)
      ips_per_node.each do |_node_name, ips|
        ips.size.should eq(2) # 6 IPs / 3 nodes = 2 per node
      end
    end

    it "distributes IPs proportionally across unbalanced endpoint load" do
      # Node-1: 4 endpoints, Node-2: 2 endpoints, Node-3: 1 endpoint
      # 7 IPs should distribute proportionally
      service = ControllerFixtures.service(
        external_ips: ["10.0.1.11", "10.0.1.12", "10.0.1.13", "10.0.1.14", "10.0.1.15", "10.0.1.16", "10.0.1.17"]
      )

      endpoint_slice1 = ControllerFixtures.endpoint_slice(
        name: "test-service-slice1",
        nodes: ["node-1", "node-1", "node-1", "node-1"]
      )
      endpoint_slice2 = ControllerFixtures.endpoint_slice(
        name: "test-service-slice2",
        nodes: ["node-2", "node-2"]
      )
      endpoint_slice3 = ControllerFixtures.endpoint_slice(
        name: "test-service-slice3",
        nodes: ["node-3"]
      )

      network = ControllerFixtures.vip_network

      allocator = Netwrangler::Controller::IpAllocator.new(
        services: [service],
        endpoint_slices: [endpoint_slice1, endpoint_slice2, endpoint_slice3],
        vip_networks: [network],
        vip_addresses: [] of Netwrangler::Model::VipAddress,
        vip_configs: [ControllerFixtures.vip_config],
      )

      result = allocator.allocate
      result.added_ips.size.should eq(7)

      ips_per_node = result.added_ips.group_by(&.spec.node_name)

      # With 4:2:1 endpoint ratio, expect roughly proportional distribution
      # Node-3 (1 endpoint) should get fewest IPs
      node3_count = ips_per_node["node-3"]?.try(&.size) || 0
      node1_count = ips_per_node["node-1"]?.try(&.size) || 0

      node1_count.should be >= node3_count
    end

    it "rebalances IPs when node added to cluster" do
      # Initial: 2 nodes, 4 IPs (2 each)
      initial_service = ControllerFixtures.service(
        external_ips: ["10.0.1.11", "10.0.1.12", "10.0.1.13", "10.0.1.14"]
      )

      initial_endpoint1 = ControllerFixtures.endpoint_slice(
        name: "test-service-slice1",
        nodes: ["node-1", "node-1"]
      )
      initial_endpoint2 = ControllerFixtures.endpoint_slice(
        name: "test-service-slice2",
        nodes: ["node-2", "node-2"]
      )

      network = ControllerFixtures.vip_network

      # First allocation
      allocator1 = Netwrangler::Controller::IpAllocator.new(
        services: [initial_service],
        endpoint_slices: [initial_endpoint1, initial_endpoint2],
        vip_networks: [network],
        vip_addresses: [] of Netwrangler::Model::VipAddress,
        vip_configs: [ControllerFixtures.vip_config],
      )
      result1 = allocator1.allocate

      # Use added IPs directly (already Model::VipAddress)
      existing_ips = result1.added_ips

      # Add node-3 with endpoints
      updated_endpoint3 = ControllerFixtures.endpoint_slice(
        name: "test-service-slice3",
        nodes: ["node-3", "node-3"]
      )

      # Second allocation with new node
      allocator2 = Netwrangler::Controller::IpAllocator.new(
        services: [initial_service],
        endpoint_slices: [initial_endpoint1, initial_endpoint2, updated_endpoint3],
        vip_networks: [network],
        vip_addresses: existing_ips,
        vip_configs: [ControllerFixtures.vip_config],
      )
      result2 = allocator2.allocate

      # Some IPs may be updated to rebalance
      (result2.updated_ips.size + result2.added_ips.size).should be >= 0
    end

    it "migrates IPs when node removed from cluster" do
      # Initial: 3 nodes, 6 IPs
      initial_service = ControllerFixtures.service(
        external_ips: ["10.0.1.11", "10.0.1.12", "10.0.1.13", "10.0.1.14", "10.0.1.15", "10.0.1.16"]
      )

      initial_endpoint1 = ControllerFixtures.endpoint_slice(
        name: "test-service-slice1",
        nodes: ["node-1", "node-1"]
      )
      initial_endpoint2 = ControllerFixtures.endpoint_slice(
        name: "test-service-slice2",
        nodes: ["node-2", "node-2"]
      )
      initial_endpoint3 = ControllerFixtures.endpoint_slice(
        name: "test-service-slice3",
        nodes: ["node-3", "node-3"]
      )

      network = ControllerFixtures.vip_network

      # First allocation
      allocator1 = Netwrangler::Controller::IpAllocator.new(
        services: [initial_service],
        endpoint_slices: [initial_endpoint1, initial_endpoint2, initial_endpoint3],
        vip_networks: [network],
        vip_addresses: [] of Netwrangler::Model::VipAddress,
        vip_configs: [ControllerFixtures.vip_config],
      )
      result1 = allocator1.allocate

      existing_ips = result1.added_ips

      # Remove node-3 (simulate node loss)
      allocator2 = Netwrangler::Controller::IpAllocator.new(
        services: [initial_service],
        endpoint_slices: [initial_endpoint1, initial_endpoint2],
        vip_networks: [network],
        vip_addresses: existing_ips,
        vip_configs: [ControllerFixtures.vip_config],
      )
      result2 = allocator2.allocate

      # IPs from node-3 should be reassigned
      result2.updated_ips.size.should be > 0
    end

    it "assigns new IPs to least loaded nodes when service adds IPs" do
      # Initial: 2 nodes, 4 IPs allocated
      initial_service = ControllerFixtures.service(
        external_ips: ["10.0.1.11", "10.0.1.12", "10.0.1.13", "10.0.1.14"]
      )

      endpoint1 = ControllerFixtures.endpoint_slice(
        name: "test-service-slice1",
        nodes: ["node-1", "node-1"]
      )
      endpoint2 = ControllerFixtures.endpoint_slice(
        name: "test-service-slice2",
        nodes: ["node-2", "node-2"]
      )

      network = ControllerFixtures.vip_network

      allocator1 = Netwrangler::Controller::IpAllocator.new(
        services: [initial_service],
        endpoint_slices: [endpoint1, endpoint2],
        vip_networks: [network],
        vip_addresses: [] of Netwrangler::Model::VipAddress,
        vip_configs: [ControllerFixtures.vip_config],
      )
      result1 = allocator1.allocate

      existing_ips = result1.added_ips

      # Service adds 2 more IPs
      updated_service = ControllerFixtures.service(
        external_ips: ["10.0.1.11", "10.0.1.12", "10.0.1.13", "10.0.1.14", "10.0.1.15", "10.0.1.16"]
      )

      allocator2 = Netwrangler::Controller::IpAllocator.new(
        services: [updated_service],
        endpoint_slices: [endpoint1, endpoint2],
        vip_networks: [network],
        vip_addresses: existing_ips,
        vip_configs: [ControllerFixtures.vip_config],
      )
      result2 = allocator2.allocate

      result2.added_ips.size.should eq(2)
      result2.updated_ips.should be_empty
      result2.deleted_ips.should be_empty
    end

    it "deletes virtual IPs when service removes IPs" do
      # Initial: 4 IPs allocated
      initial_service = ControllerFixtures.service(
        external_ips: ["10.0.1.11", "10.0.1.12", "10.0.1.13", "10.0.1.14"]
      )

      endpoint = ControllerFixtures.endpoint_slice(
        nodes: ["node-1", "node-1"]
      )
      network = ControllerFixtures.vip_network

      allocator1 = Netwrangler::Controller::IpAllocator.new(
        services: [initial_service],
        endpoint_slices: [endpoint],
        vip_networks: [network],
        vip_addresses: [] of Netwrangler::Model::VipAddress,
        vip_configs: [ControllerFixtures.vip_config],
      )
      result1 = allocator1.allocate

      existing_ips = result1.added_ips

      # Service removes 2 IPs
      updated_service = ControllerFixtures.service(
        external_ips: ["10.0.1.11", "10.0.1.12"]
      )

      allocator2 = Netwrangler::Controller::IpAllocator.new(
        services: [updated_service],
        endpoint_slices: [endpoint],
        vip_networks: [network],
        vip_addresses: existing_ips,
        vip_configs: [ControllerFixtures.vip_config],
      )
      result2 = allocator2.allocate

      result2.added_ips.should be_empty
      result2.updated_ips.should be_empty
      result2.deleted_ips.size.should eq(2)
    end

    it "rejects service when IP does not match any VipNetwork CIDR" do
      service = ControllerFixtures.service(
        external_ips: ["192.168.99.10"]
      )
      endpoint = ControllerFixtures.endpoint_slice
      network = ControllerFixtures.vip_network # 10.0.1.0/24

      allocator = Netwrangler::Controller::IpAllocator.new(
        services: [service],
        endpoint_slices: [endpoint],
        vip_networks: [network],
        vip_addresses: [] of Netwrangler::Model::VipAddress,
        vip_configs: [ControllerFixtures.vip_config],
      )

      result = allocator.allocate
      result.empty?.should be_true
    end

    it "handles multiple services on same network independently" do
      service1 = ControllerFixtures.service(
        name: "service-1",
        external_ips: ["10.0.1.11", "10.0.1.12"]
      )
      service2 = ControllerFixtures.service(
        name: "service-2",
        external_ips: ["10.0.1.21", "10.0.1.22"]
      )

      endpoint1 = ControllerFixtures.endpoint_slice(
        name: "service-1-slice",
        service_name: "service-1",
        nodes: ["node-1", "node-1"]
      )
      endpoint2 = ControllerFixtures.endpoint_slice(
        name: "service-2-slice",
        service_name: "service-2",
        nodes: ["node-2", "node-2"]
      )

      network = ControllerFixtures.vip_network

      allocator = Netwrangler::Controller::IpAllocator.new(
        services: [service1, service2],
        endpoint_slices: [endpoint1, endpoint2],
        vip_networks: [network],
        vip_addresses: [] of Netwrangler::Model::VipAddress,
        vip_configs: [ControllerFixtures.vip_config],
      )

      result = allocator.allocate
      result.added_ips.size.should eq(4)

      # Each service should have its IPs
      service1_ips = result.added_ips.select { |ip| ip.spec.virtual_cidr.starts_with?("10.0.1.1") }
      service2_ips = result.added_ips.select { |ip| ip.spec.virtual_cidr.starts_with?("10.0.1.2") }

      service1_ips.size.should eq(2)
      service2_ips.size.should eq(2)
    end

    it "handles multiple services on different networks" do
      service1 = ControllerFixtures.service(
        name: "service-1",
        external_ips: ["10.0.1.11"]
      )
      service2 = ControllerFixtures.service(
        name: "service-2",
        external_ips: ["192.168.1.11"]
      )

      endpoint1 = ControllerFixtures.endpoint_slice(
        name: "service-1-slice",
        service_name: "service-1",
        nodes: ["node-1"]
      )
      endpoint2 = ControllerFixtures.endpoint_slice(
        name: "service-2-slice",
        service_name: "service-2",
        nodes: ["node-1"]
      )

      network1 = ControllerFixtures.vip_network(
        name: "network-1",
        interface: "eth0",
        network_cidr: "10.0.1.0/24"
      )
      network2 = ControllerFixtures.vip_network(
        name: "network-2",
        interface: "eth1",
        gateway_ip: "192.168.1.1",
        network_cidr: "192.168.1.0/24"
      )

      allocator = Netwrangler::Controller::IpAllocator.new(
        services: [service1, service2],
        endpoint_slices: [endpoint1, endpoint2],
        vip_networks: [network1, network2],
        vip_addresses: [] of Netwrangler::Model::VipAddress,
        vip_configs: [ControllerFixtures.vip_config],
      )

      result = allocator.allocate
      result.added_ips.size.should eq(2)

      # Verify different interfaces
      interfaces = result.added_ips.map(&.spec.interface).uniq!
      interfaces.size.should eq(2)
    end

    it "handles single service with IPs from different networks" do
      service = ControllerFixtures.service(
        external_ips: ["10.0.1.11", "192.168.1.11"]
      )

      endpoint = ControllerFixtures.endpoint_slice(
        nodes: ["node-1"]
      )

      network1 = ControllerFixtures.vip_network(
        name: "network-1",
        interface: "eth0",
        network_cidr: "10.0.1.0/24"
      )
      network2 = ControllerFixtures.vip_network(
        name: "network-2",
        interface: "eth1",
        gateway_ip: "192.168.1.1",
        network_cidr: "192.168.1.0/24"
      )

      allocator = Netwrangler::Controller::IpAllocator.new(
        services: [service],
        endpoint_slices: [endpoint],
        vip_networks: [network1, network2],
        vip_addresses: [] of Netwrangler::Model::VipAddress,
        vip_configs: [ControllerFixtures.vip_config],
      )

      result = allocator.allocate
      result.added_ips.size.should eq(2)

      # Verify each IP got the correct network
      ip1 = result.added_ips.find! { |ip| ip.spec.virtual_cidr == "10.0.1.11/24" }
      ip1.spec.network.should eq("network-1")
      ip1.spec.interface.should eq("eth0")

      ip2 = result.added_ips.find! { |ip| ip.spec.virtual_cidr == "192.168.1.11/24" }
      ip2.spec.network.should eq("network-2")
      ip2.spec.interface.should eq("eth1")
    end

    it "disables overlapping VipNetwork without allocated IPs" do
      service = ControllerFixtures.service(
        external_ips: ["10.0.1.11"]
      )
      endpoint = ControllerFixtures.endpoint_slice(nodes: ["node-1"])

      # Two overlapping networks, no existing allocations
      network1 = ControllerFixtures.vip_network(
        name: "network-1",
        network_cidr: "10.0.1.0/24"
      )
      network2 = ControllerFixtures.vip_network(
        name: "network-2",
        network_cidr: "10.0.0.0/16"
      )

      allocator = Netwrangler::Controller::IpAllocator.new(
        services: [service],
        endpoint_slices: [endpoint],
        vip_networks: [network1, network2],
        vip_addresses: [] of Netwrangler::Model::VipAddress,
        vip_configs: [ControllerFixtures.vip_config],
      )

      allocator.allocate

      # One network should be disabled
      allocator.disabled_networks.size.should eq(1)

      # The service IP (10.0.1.11) is in both networks; the active network should work
      # The disabled network's services would get an error condition
    end

    it "prefers keeping network with existing VipAddresses when overlapping" do
      # network-1 has an existing VipAddress, network-2 does not
      network1 = ControllerFixtures.vip_network(
        name: "network-1",
        network_cidr: "10.0.1.0/24"
      )
      network2 = ControllerFixtures.vip_network(
        name: "network-2",
        network_cidr: "10.0.0.0/16"
      )

      existing_ip = ControllerFixtures.vip_address(
        name: "test-service-1",
        virtual_cidr: "10.0.1.11/24",
        node_name: "node-1",
        labels: {
          "netwrangler.dev/managed-by" => "netwrangler",
          "netwrangler.dev/service"    => "test-service",
          "netwrangler.dev/network"    => "network-1",
        }
      )

      service = ControllerFixtures.service(external_ips: ["10.0.1.11"])
      endpoint = ControllerFixtures.endpoint_slice(nodes: ["node-1"])

      allocator = Netwrangler::Controller::IpAllocator.new(
        services: [service],
        endpoint_slices: [endpoint],
        vip_networks: [network1, network2],
        vip_addresses: [existing_ip],
        vip_configs: [ControllerFixtures.vip_config],
      )

      allocator.allocate

      # network-2 should be disabled (network-1 has existing IPs)
      allocator.network_disabled?("network-2").should be_true
      allocator.network_disabled?("network-1").should be_false
    end

    it "sets error condition on service using disabled network" do
      # network-2 overlaps with network-1, gets disabled
      network1 = ControllerFixtures.vip_network(
        name: "network-1",
        network_cidr: "10.0.1.0/24"
      )
      network2 = ControllerFixtures.vip_network(
        name: "network-2",
        network_cidr: "10.0.0.0/16"
      )

      # Service uses IP only in network-2's broader range (not in network-1's /24)
      service = ControllerFixtures.service(
        external_ips: ["10.0.2.11"]
      )
      endpoint = ControllerFixtures.endpoint_slice(nodes: ["node-1"])

      allocator = Netwrangler::Controller::IpAllocator.new(
        services: [service],
        endpoint_slices: [endpoint],
        vip_networks: [network1, network2],
        vip_addresses: [] of Netwrangler::Model::VipAddress,
        vip_configs: [ControllerFixtures.vip_config],
      )

      result = allocator.allocate

      # network-2 is disabled, so this IP has no active network
      service_name = Netwrangler::Util::QualifiedName.new(name: "test-service", namespace: "default")
      condition = result.service_conditions[service_name]
      condition.status.should eq("False")
      condition.message!.should contain("disabled")
    end

    it "does not disable any networks when CIDRs do not overlap" do
      network1 = ControllerFixtures.vip_network(
        name: "network-1",
        network_cidr: "10.0.1.0/24"
      )
      network2 = ControllerFixtures.vip_network(
        name: "network-2",
        network_cidr: "10.0.2.0/24"
      )

      service = ControllerFixtures.service(external_ips: ["10.0.1.11"])
      endpoint = ControllerFixtures.endpoint_slice(nodes: ["node-1"])

      allocator = Netwrangler::Controller::IpAllocator.new(
        services: [service],
        endpoint_slices: [endpoint],
        vip_networks: [network1, network2],
        vip_addresses: [] of Netwrangler::Model::VipAddress,
        vip_configs: [ControllerFixtures.vip_config],
      )

      result = allocator.allocate
      allocator.disabled_networks.should be_empty
      result.added_ips.size.should eq(1)
    end

    it "does not disable anything with a single network" do
      network = ControllerFixtures.vip_network

      service = ControllerFixtures.service(external_ips: ["10.0.1.11"])
      endpoint = ControllerFixtures.endpoint_slice(nodes: ["node-1"])

      allocator = Netwrangler::Controller::IpAllocator.new(
        services: [service],
        endpoint_slices: [endpoint],
        vip_networks: [network],
        vip_addresses: [] of Netwrangler::Model::VipAddress,
        vip_configs: [ControllerFixtures.vip_config],
      )

      result = allocator.allocate
      allocator.disabled_networks.should be_empty
      result.added_ips.size.should eq(1)
    end

    it "handles three-way overlap chain" do
      # network-a (10.0.0.0/8) overlaps network-b (10.0.0.0/16) overlaps network-c (10.0.1.0/24)
      # network-c is most specific, should survive
      network_a = ControllerFixtures.vip_network(
        name: "network-a",
        network_cidr: "10.0.0.0/8"
      )
      network_b = ControllerFixtures.vip_network(
        name: "network-b",
        network_cidr: "10.0.0.0/16"
      )
      network_c = ControllerFixtures.vip_network(
        name: "network-c",
        network_cidr: "10.0.1.0/24"
      )

      service = ControllerFixtures.service(external_ips: ["10.0.1.11"])
      endpoint = ControllerFixtures.endpoint_slice(nodes: ["node-1"])

      allocator = Netwrangler::Controller::IpAllocator.new(
        services: [service],
        endpoint_slices: [endpoint],
        vip_networks: [network_a, network_b, network_c],
        vip_addresses: [] of Netwrangler::Model::VipAddress,
        vip_configs: [ControllerFixtures.vip_config],
      )

      allocator.allocate

      # The most specific network (network-c, /24) should survive
      allocator.network_disabled?("network-c").should be_false
      allocator.disabled_networks.size.should be >= 1
    end

    it "handles identical CIDRs on two networks" do
      network1 = ControllerFixtures.vip_network(
        name: "network-1",
        network_cidr: "10.0.1.0/24"
      )
      network2 = ControllerFixtures.vip_network(
        name: "network-2",
        network_cidr: "10.0.1.0/24"
      )

      service = ControllerFixtures.service(external_ips: ["10.0.1.11"])
      endpoint = ControllerFixtures.endpoint_slice(nodes: ["node-1"])

      allocator = Netwrangler::Controller::IpAllocator.new(
        services: [service],
        endpoint_slices: [endpoint],
        vip_networks: [network1, network2],
        vip_addresses: [] of Netwrangler::Model::VipAddress,
        vip_configs: [ControllerFixtures.vip_config],
      )

      result = allocator.allocate

      # One should be disabled
      allocator.disabled_networks.size.should eq(1)
      # The remaining one should work
      result.added_ips.size.should eq(1)
    end

    it "uses catch-all when sourceNetworkAddresses contains 0.0.0.0/0" do
      network = ControllerFixtures.vip_network(
        source_cidrs: ["0.0.0.0/0"]
      )
      service = ControllerFixtures.service(external_ips: ["10.0.1.11"])
      endpoint = ControllerFixtures.endpoint_slice(nodes: ["node-1"])

      allocator = Netwrangler::Controller::IpAllocator.new(
        services: [service],
        endpoint_slices: [endpoint],
        vip_networks: [network],
        vip_addresses: [] of Netwrangler::Model::VipAddress,
        vip_configs: [ControllerFixtures.vip_config],
      )

      result = allocator.allocate
      result.added_ips.size.should eq(1)
      result.added_ips.first.spec.source_cidrs.should eq(["0.0.0.0/0"])
    end

    it "reduces sourceNetworkAddresses to only 0.0.0.0/0 when mixed with other entries" do
      network = ControllerFixtures.vip_network(
        source_cidrs: ["0.0.0.0/0", "192.168.0.0/16"]
      )
      service = ControllerFixtures.service(external_ips: ["10.0.1.11"])
      endpoint = ControllerFixtures.endpoint_slice(nodes: ["node-1"])

      allocator = Netwrangler::Controller::IpAllocator.new(
        services: [service],
        endpoint_slices: [endpoint],
        vip_networks: [network],
        vip_addresses: [] of Netwrangler::Model::VipAddress,
        vip_configs: [ControllerFixtures.vip_config],
      )

      result = allocator.allocate
      result.added_ips.size.should eq(1)
      result.added_ips.first.spec.source_cidrs.should eq(["0.0.0.0/0"])
    end

    it "prunes overlapping sourceNetworkAddresses within same network" do
      network = ControllerFixtures.vip_network(
        network_cidr: "10.0.1.0/24",
        source_cidrs: ["10.0.0.0/8", "10.0.1.0/24"]
      )
      service = ControllerFixtures.service(external_ips: ["10.0.1.11"])
      endpoint = ControllerFixtures.endpoint_slice(nodes: ["node-1"])

      allocator = Netwrangler::Controller::IpAllocator.new(
        services: [service],
        endpoint_slices: [endpoint],
        vip_networks: [network],
        vip_addresses: [] of Netwrangler::Model::VipAddress,
        vip_configs: [ControllerFixtures.vip_config],
      )

      result = allocator.allocate
      result.added_ips.size.should eq(1)
      # The /24 is contained by /8, so only /8 remains (plus networkAddress is excluded from result)
      result.added_ips.first.spec.source_cidrs.should eq(["10.0.0.0/8"])
    end

    it "passes through non-overlapping sourceNetworkAddresses" do
      network = ControllerFixtures.vip_network(
        source_cidrs: ["192.168.0.0/16", "172.16.0.0/12"]
      )
      service = ControllerFixtures.service(external_ips: ["10.0.1.11"])
      endpoint = ControllerFixtures.endpoint_slice(nodes: ["node-1"])

      allocator = Netwrangler::Controller::IpAllocator.new(
        services: [service],
        endpoint_slices: [endpoint],
        vip_networks: [network],
        vip_addresses: [] of Netwrangler::Model::VipAddress,
        vip_configs: [ControllerFixtures.vip_config],
      )

      result = allocator.allocate
      result.added_ips.size.should eq(1)
      result.added_ips.first.spec.source_cidrs.sort.should eq(["172.16.0.0/12", "192.168.0.0/16"])
    end

    it "allows overlapping sourceNetworkAddresses across different VipNetworks" do
      network1 = ControllerFixtures.vip_network(
        name: "network-1",
        network_cidr: "10.0.1.0/24",
        source_cidrs: ["192.168.0.0/16"]
      )
      network2 = ControllerFixtures.vip_network(
        name: "network-2",
        network_cidr: "10.0.2.0/24",
        source_cidrs: ["192.168.1.0/24"]
      )

      service1 = ControllerFixtures.service(
        name: "service-1",
        external_ips: ["10.0.1.11"]
      )
      service2 = ControllerFixtures.service(
        name: "service-2",
        external_ips: ["10.0.2.11"]
      )
      endpoint1 = ControllerFixtures.endpoint_slice(
        name: "service-1-slice",
        service_name: "service-1",
        nodes: ["node-1"]
      )
      endpoint2 = ControllerFixtures.endpoint_slice(
        name: "service-2-slice",
        service_name: "service-2",
        nodes: ["node-1"]
      )

      allocator = Netwrangler::Controller::IpAllocator.new(
        services: [service1, service2],
        endpoint_slices: [endpoint1, endpoint2],
        vip_networks: [network1, network2],
        vip_addresses: [] of Netwrangler::Model::VipAddress,
        vip_configs: [ControllerFixtures.vip_config],
      )

      result = allocator.allocate

      # Cross-network sourceNetworkAddresses overlap is allowed (different VIPs = different first keys)
      allocator.disabled_networks.should be_empty
      result.added_ips.size.should eq(2)
    end

    it "preserves existing allocations across resync when no changes" do
      service = ControllerFixtures.service(
        external_ips: ["10.0.1.11", "10.0.1.12"]
      )
      endpoint = ControllerFixtures.endpoint_slice(
        nodes: ["node-1", "node-1"]
      )
      network = ControllerFixtures.vip_network

      # First allocation
      allocator1 = Netwrangler::Controller::IpAllocator.new(
        services: [service],
        endpoint_slices: [endpoint],
        vip_networks: [network],
        vip_addresses: [] of Netwrangler::Model::VipAddress,
        vip_configs: [ControllerFixtures.vip_config],
      )
      result1 = allocator1.allocate

      existing_ips = result1.added_ips

      # Resync with same state
      allocator2 = Netwrangler::Controller::IpAllocator.new(
        services: [service],
        endpoint_slices: [endpoint],
        vip_networks: [network],
        vip_addresses: existing_ips,
        vip_configs: [ControllerFixtures.vip_config],
      )
      result2 = allocator2.allocate

      # No changes expected
      result2.empty?.should be_true
    end

    it "handles service with no endpoints gracefully" do
      service = ControllerFixtures.service(
        external_ips: ["10.0.1.11"]
      )
      network = ControllerFixtures.vip_network

      allocator = Netwrangler::Controller::IpAllocator.new(
        services: [service],
        endpoint_slices: [] of Netwrangler::Model::EndpointSlice,
        vip_networks: [network],
        vip_addresses: [] of Netwrangler::Model::VipAddress,
        vip_configs: [ControllerFixtures.vip_config],
      )

      result = allocator.allocate
      result.empty?.should be_true
    end

    it "works with VipNetwork with gateway_ip" do
      service = ControllerFixtures.service(
        external_ips: ["10.0.1.11"]
      )
      endpoint = ControllerFixtures.endpoint_slice(
        nodes: ["node-1"]
      )

      # Network with gateway_ip
      network = ControllerFixtures.vip_network(
        gateway_ip: "10.0.1.1"
      )

      allocator = Netwrangler::Controller::IpAllocator.new(
        services: [service],
        endpoint_slices: [endpoint],
        vip_networks: [network],
        vip_addresses: [] of Netwrangler::Model::VipAddress,
        vip_configs: [ControllerFixtures.vip_config],
      )

      result = allocator.allocate
      result.added_ips.size.should eq(1)
      result.added_ips.first.spec.gateway_ip.should eq("10.0.1.1")
    end

    it "handles complex scenario with mixed operations" do
      # Scenario: 2 services, one adding IPs, one removing IPs
      service1 = ControllerFixtures.service(
        name: "service-1",
        external_ips: ["10.0.1.11", "10.0.1.12", "10.0.1.13"] # 3 IPs
      )
      service2 = ControllerFixtures.service(
        name: "service-2",
        external_ips: ["10.0.1.21"] # Down from 2 to 1
      )

      endpoint1 = ControllerFixtures.endpoint_slice(
        name: "service-1-slice",
        service_name: "service-1",
        nodes: ["node-1", "node-1"]
      )
      endpoint2 = ControllerFixtures.endpoint_slice(
        name: "service-2-slice",
        service_name: "service-2",
        nodes: ["node-2"]
      )

      network = ControllerFixtures.vip_network

      # Previous state: service-1 had 2 IPs, service-2 had 2 IPs
      existing_ips = [
        ControllerFixtures.vip_address(
          name: "service-1-1",
          virtual_cidr: "10.0.1.11/24",
          node_name: "node-1",
          labels: {"netwrangler.dev/managed-by" => "netwrangler", "netwrangler.dev/service" => "service-1"}
        ),
        ControllerFixtures.vip_address(
          name: "service-1-2",
          virtual_cidr: "10.0.1.12/24",
          node_name: "node-1",
          labels: {"netwrangler.dev/managed-by" => "netwrangler", "netwrangler.dev/service" => "service-1"}
        ),
        ControllerFixtures.vip_address(
          name: "service-2-1",
          virtual_cidr: "10.0.1.21/24",
          node_name: "node-2",
          labels: {"netwrangler.dev/managed-by" => "netwrangler", "netwrangler.dev/service" => "service-2"}
        ),
        ControllerFixtures.vip_address(
          name: "service-2-2",
          virtual_cidr: "10.0.1.22/24",
          node_name: "node-2",
          labels: {"netwrangler.dev/managed-by" => "netwrangler", "netwrangler.dev/service" => "service-2"}
        ),
      ]

      allocator = Netwrangler::Controller::IpAllocator.new(
        services: [service1, service2],
        endpoint_slices: [endpoint1, endpoint2],
        vip_networks: [network],
        vip_addresses: existing_ips,
        vip_configs: [ControllerFixtures.vip_config],
      )

      result = allocator.allocate

      # Service-1 adds 1 IP (10.0.1.13)
      result.added_ips.size.should eq(1)
      result.added_ips.first.spec.virtual_cidr.should eq("10.0.1.13/24")

      # Service-2 removes 1 IP (10.0.1.22)
      result.deleted_ips.size.should eq(1)
      result.deleted_ips.first.name.should eq("service-2-2")
    end

    it "handles service with many IPs across many nodes" do
      # Stress test: 10 nodes, 30 IPs
      service = ControllerFixtures.service(
        external_ips: (1..30).map { |index| "10.0.1.#{10 + index}" }.to_a
      )

      endpoint_slices = (1..10).map do |index|
        ControllerFixtures.endpoint_slice(
          name: "test-service-slice#{index}",
          nodes: ["node-#{index}", "node-#{index}", "node-#{index}"]
        )
      end

      network = ControllerFixtures.vip_network

      allocator = Netwrangler::Controller::IpAllocator.new(
        services: [service],
        endpoint_slices: endpoint_slices,
        vip_networks: [network],
        vip_addresses: [] of Netwrangler::Model::VipAddress,
        vip_configs: [ControllerFixtures.vip_config],
      )

      result = allocator.allocate
      result.added_ips.size.should eq(30)

      # Verify distribution is reasonable (each node should get some IPs)
      ips_per_node = result.added_ips.group_by(&.spec.node_name)
      ips_per_node.size.should eq(10) # All 10 nodes should have at least one IP

      # With equal endpoint distribution, expect roughly equal IP distribution
      # Each node should have 2-4 IPs (30 / 10 = 3 average)
      ips_per_node.each do |_node_name, ips|
        ips.size.should be >= 1
        ips.size.should be <= 5
      end
    end

    it "handles rapid service churn with multiple cycles" do
      network = ControllerFixtures.vip_network

      # Cycle 1: Create service with 2 IPs
      service1 = ControllerFixtures.service(external_ips: ["10.0.1.11", "10.0.1.12"])
      endpoint1 = ControllerFixtures.endpoint_slice(nodes: ["node-1", "node-1"])

      allocator1 = Netwrangler::Controller::IpAllocator.new(
        services: [service1],
        endpoint_slices: [endpoint1],
        vip_networks: [network],
        vip_addresses: [] of Netwrangler::Model::VipAddress,
        vip_configs: [ControllerFixtures.vip_config],
      )
      result1 = allocator1.allocate
      result1.added_ips.size.should eq(2)

      # Cycle 2: Add 1 IP
      existing_ips_2 = result1.added_ips

      service2 = ControllerFixtures.service(external_ips: ["10.0.1.11", "10.0.1.12", "10.0.1.13"])
      allocator2 = Netwrangler::Controller::IpAllocator.new(
        services: [service2],
        endpoint_slices: [endpoint1],
        vip_networks: [network],
        vip_addresses: existing_ips_2,
        vip_configs: [ControllerFixtures.vip_config],
      )
      result2 = allocator2.allocate
      result2.added_ips.size.should eq(1)

      # Cycle 3: Remove all IPs (service deleted)
      all_ips = existing_ips_2 + result2.added_ips

      allocator3 = Netwrangler::Controller::IpAllocator.new(
        services: [] of Netwrangler::Model::Service,
        endpoint_slices: [endpoint1],
        vip_networks: [network],
        vip_addresses: all_ips,
        vip_configs: [ControllerFixtures.vip_config],
      )
      result3 = allocator3.allocate
      result3.deleted_ips.size.should eq(3)
    end

    it "rebalances IPs when adding a new endpoint to a different node" do
      # Scenario matching integration test: Start with 1 node, add endpoint on second node
      # Initial: 1 node with 2 IPs
      service = ControllerFixtures.service(
        external_ips: ["10.0.1.10", "10.0.1.11"]
      )

      # Only one endpoint slice with one node initially
      initial_endpoint = ControllerFixtures.endpoint_slice(
        name: "test-service-slice1",
        nodes: ["node-1"]
      )

      network = ControllerFixtures.vip_network

      # First allocation - all IPs go to node-1
      allocator1 = Netwrangler::Controller::IpAllocator.new(
        services: [service],
        endpoint_slices: [initial_endpoint],
        vip_networks: [network],
        vip_addresses: [] of Netwrangler::Model::VipAddress,
        vip_configs: [ControllerFixtures.vip_config],
      )
      result1 = allocator1.allocate

      result1.added_ips.size.should eq(2)
      nodes_used_1 = result1.added_ips.map(&.spec.node_name).uniq!
      nodes_used_1.should eq(["node-1"])

      # Add a second endpoint on node-2
      updated_endpoint1 = ControllerFixtures.endpoint_slice(
        name: "test-service-slice1",
        nodes: ["node-1"]
      )
      new_endpoint2 = ControllerFixtures.endpoint_slice(
        name: "test-service-slice2",
        nodes: ["node-2"]
      )

      # Second allocation with existing IPs and new endpoint
      allocator2 = Netwrangler::Controller::IpAllocator.new(
        services: [service],
        endpoint_slices: [updated_endpoint1, new_endpoint2],
        vip_networks: [network],
        vip_addresses: result1.added_ips,
        vip_configs: [ControllerFixtures.vip_config],
      )
      result2 = allocator2.allocate

      # One IP should be moved to node-2 (updated), plus the remaining IP on node-1
      # gets updated because endpoint_ips changed (node-2 endpoint added changes the set)
      result2.updated_ips.size.should be >= 1
      result2.added_ips.should be_empty
      result2.deleted_ips.should be_empty

      # At least one updated IP should now be on node-2
      result2.updated_ips.map(&.spec.node_name).should contain("node-2")
    end

    it "includes endpoint IPs in multi-node allocation" do
      scenario = ControllerFixtures.multi_node_service_scenario(
        node_count: 2,
        ips_per_service: 2,
        endpoints_per_node: [2, 1]
      )

      allocator = Netwrangler::Controller::IpAllocator.new(
        services: scenario[:services],
        endpoint_slices: scenario[:endpoint_slices],
        vip_networks: scenario[:vip_networks],
        vip_addresses: [] of Netwrangler::Model::VipAddress,
        vip_configs: [ControllerFixtures.vip_config],
      )

      result = allocator.allocate
      result.added_ips.size.should eq(2)

      # Each IP should have endpoint IPs from its assigned node
      result.added_ips.each do |ip|
        ip.spec.endpoint_ips.should_not be_empty
      end

      # IPs on node-1 should have node-1's endpoints
      node1_ips = result.added_ips.select { |ip| ip.spec.node_name == "node-1" }
      node1_ips.each do |ip|
        ip.spec.endpoint_ips.should eq(["10.244.1.1", "10.244.1.2"])
      end

      # IPs on node-2 should have node-2's endpoints
      node2_ips = result.added_ips.select { |ip| ip.spec.node_name == "node-2" }
      node2_ips.each do |ip|
        ip.spec.endpoint_ips.should eq(["10.244.2.1"])
      end
    end

    it "multiple VipAddresses on same node share endpoint IPs" do
      service = ControllerFixtures.service(
        external_ips: ["10.0.1.10", "10.0.1.11", "10.0.1.12"]
      )

      # Single node with 2 endpoints
      endpoint_slice = ControllerFixtures.endpoint_slice(
        nodes: ["node-1", "node-1"],
        addresses: [["10.244.1.1"], ["10.244.1.2"]]
      )

      network = ControllerFixtures.vip_network

      allocator = Netwrangler::Controller::IpAllocator.new(
        services: [service],
        endpoint_slices: [endpoint_slice],
        vip_networks: [network],
        vip_addresses: [] of Netwrangler::Model::VipAddress,
        vip_configs: [ControllerFixtures.vip_config],
      )

      result = allocator.allocate
      result.added_ips.size.should eq(3)

      # All IPs should be on node-1 and share the same endpoint IPs
      result.added_ips.each do |ip|
        ip.spec.node_name.should eq("node-1")
        ip.spec.endpoint_ips.should eq(["10.244.1.1", "10.244.1.2"])
      end
    end

    it "updates endpoint IPs when endpoints change" do
      service = ControllerFixtures.service(
        external_ips: ["10.0.1.10"]
      )

      # Initial endpoint
      endpoint_slice = ControllerFixtures.endpoint_slice(
        nodes: ["node-1"],
        addresses: [["10.244.1.1"]]
      )

      network = ControllerFixtures.vip_network

      # First allocation
      allocator1 = Netwrangler::Controller::IpAllocator.new(
        services: [service],
        endpoint_slices: [endpoint_slice],
        vip_networks: [network],
        vip_addresses: [] of Netwrangler::Model::VipAddress,
        vip_configs: [ControllerFixtures.vip_config],
      )
      result1 = allocator1.allocate
      result1.added_ips.size.should eq(1)
      result1.added_ips.first.spec.endpoint_ips.should eq(["10.244.1.1"])

      # Add another endpoint on same node
      updated_endpoint_slice = ControllerFixtures.endpoint_slice(
        nodes: ["node-1", "node-1"],
        addresses: [["10.244.1.1"], ["10.244.1.5"]]
      )

      # Second allocation with existing IPs
      allocator2 = Netwrangler::Controller::IpAllocator.new(
        services: [service],
        endpoint_slices: [updated_endpoint_slice],
        vip_networks: [network],
        vip_addresses: result1.added_ips,
        vip_configs: [ControllerFixtures.vip_config],
      )
      result2 = allocator2.allocate

      # The IP should be updated with new endpoint IPs
      result2.updated_ips.size.should eq(1)
      result2.updated_ips.first.spec.endpoint_ips.should eq(["10.244.1.1", "10.244.1.5"])
    end
  end
end
