require "./spec_helper"
require "./fixtures"

describe Netwrangler::Controller::IpAllocator do
  describe "initialization" do
    it "creates services index correctly" do
      service = ControllerFixtures.service
      allocator = Netwrangler::Controller::IpAllocator.new(
        services: [service],
        endpoint_slices: [] of Netwrangler::Model::EndpointSlice,
        vip_networks: [] of Netwrangler::Model::VipNetwork,
        vip_addresses: [] of Netwrangler::Model::VipAddress,
        vip_configs: [ControllerFixtures.vip_config],
      )

      allocator.services.size.should eq(1)
      allocator.services.has_key?(Netwrangler::Util::QualifiedName.new(name: "test-service", namespace: "default")).should be_true
    end

    it "creates endpoint_slices index correctly" do
      endpoint_slice = ControllerFixtures.endpoint_slice
      allocator = Netwrangler::Controller::IpAllocator.new(
        services: [] of Netwrangler::Model::Service,
        endpoint_slices: [endpoint_slice],
        vip_networks: [] of Netwrangler::Model::VipNetwork,
        vip_addresses: [] of Netwrangler::Model::VipAddress,
        vip_configs: [ControllerFixtures.vip_config],
      )

      allocator.endpoint_slices.size.should eq(1)
    end

    it "creates vip_networks index by name" do
      network = ControllerFixtures.vip_network(name: "my-network")
      allocator = Netwrangler::Controller::IpAllocator.new(
        services: [] of Netwrangler::Model::Service,
        endpoint_slices: [] of Netwrangler::Model::EndpointSlice,
        vip_networks: [network],
        vip_addresses: [] of Netwrangler::Model::VipAddress,
        vip_configs: [ControllerFixtures.vip_config],
      )

      allocator.vip_networks.has_key?("my-network").should be_true
    end

    it "creates vip_addresses index by QualifiedName" do
      vip_address = ControllerFixtures.vip_address
      allocator = Netwrangler::Controller::IpAllocator.new(
        services: [] of Netwrangler::Model::Service,
        endpoint_slices: [] of Netwrangler::Model::EndpointSlice,
        vip_networks: [] of Netwrangler::Model::VipNetwork,
        vip_addresses: [vip_address],
        vip_configs: [ControllerFixtures.vip_config],
      )

      allocator.vip_addresses.size.should eq(1)
    end

    it "creates vip_addresses_by_node index" do
      vip_address = ControllerFixtures.vip_address(node_name: "node-5")
      allocator = Netwrangler::Controller::IpAllocator.new(
        services: [] of Netwrangler::Model::Service,
        endpoint_slices: [] of Netwrangler::Model::EndpointSlice,
        vip_networks: [] of Netwrangler::Model::VipNetwork,
        vip_addresses: [vip_address],
        vip_configs: [ControllerFixtures.vip_config],
      )

      allocator.vip_addresses_by_node.has_key?("node-5").should be_true
      allocator.vip_addresses_by_node["node-5"].size.should eq(1)
    end

    it "handles empty arrays" do
      allocator = Netwrangler::Controller::IpAllocator.new(
        services: [] of Netwrangler::Model::Service,
        endpoint_slices: [] of Netwrangler::Model::EndpointSlice,
        vip_networks: [] of Netwrangler::Model::VipNetwork,
        vip_addresses: [] of Netwrangler::Model::VipAddress,
        vip_configs: [ControllerFixtures.vip_config],
      )

      allocator.services.should be_empty
      allocator.endpoint_slices.should be_empty
      allocator.vip_networks.should be_empty
      allocator.vip_addresses.should be_empty
    end

    it "preserves debug flag" do
      allocator = Netwrangler::Controller::IpAllocator.new(
        services: [] of Netwrangler::Model::Service,
        endpoint_slices: [] of Netwrangler::Model::EndpointSlice,
        vip_networks: [] of Netwrangler::Model::VipNetwork,
        vip_addresses: [] of Netwrangler::Model::VipAddress,
        vip_configs: [ControllerFixtures.vip_config],
        debug: true
      )

      allocator.debug?.should be_true
    end
  end

  describe Netwrangler::Controller::IpAllocator::NodeInfo do
    describe "initialization" do
      it "creates node with name and endpoint_count" do
        node = Netwrangler::Controller::IpAllocator::NodeInfo.new("node-1", endpoint_count: 2)

        node.name.should eq("node-1")
        node.endpoint_count.should eq(2)
        node.endpoint_ips.should be_empty
        node.vip_addresses.should be_empty
      end

      it "creates node with endpoint_ips" do
        node = Netwrangler::Controller::IpAllocator::NodeInfo.new("node-1", endpoint_count: 2, endpoint_ips: ["10.244.1.1", "10.244.1.2"])

        node.endpoint_ips.should eq(["10.244.1.1", "10.244.1.2"])
      end

      it "raises if endpoint_count is 0" do
        expect_raises(ArgumentError, /must be greater than 0/) do
          Netwrangler::Controller::IpAllocator::NodeInfo.new("node-1", endpoint_count: 0)
        end
      end

      it "raises if endpoint_count is negative" do
        expect_raises(ArgumentError, /must be greater than 0/) do
          Netwrangler::Controller::IpAllocator::NodeInfo.new("node-1", endpoint_count: -1)
        end
      end
    end

    describe "#quota_deviation" do
      it "returns large negative value when node has no IPs" do
        node = Netwrangler::Controller::IpAllocator::NodeInfo.new("node-1", endpoint_count: 2)
        node.quota = 1.0_f32

        # Should return a very negative value to prioritize nodes with no IPs
        node.quota_deviation.should be < -999_999
      end

      it "returns 0 when node has IPs equal to quota" do
        node = Netwrangler::Controller::IpAllocator::NodeInfo.new("node-1", endpoint_count: 2)
        node.quota = 1.0_f32
        node.add_ip(Netwrangler::Controller::IpAllocator::VipAddressInfo.new(
          name: Netwrangler::Util::QualifiedName.new(name: "test", namespace: "default"),
          network: "net",
          virtual_cidr: Netwrangler::Util::IPv4Network.parse("10.0.0.1/24"),
          service_name: Netwrangler::Util::QualifiedName.new(name: "svc", namespace: "default"),
          service_uid: "uid",
          interface: "eth0",
        ))

        node.quota_deviation.should eq(0.0_f32)
      end

      it "returns positive when node is over quota" do
        node = Netwrangler::Controller::IpAllocator::NodeInfo.new("node-1", endpoint_count: 2)
        node.quota = 1.0_f32
        2.times do |index|
          node.add_ip(Netwrangler::Controller::IpAllocator::VipAddressInfo.new(
            name: Netwrangler::Util::QualifiedName.new(name: "test-#{index}", namespace: "default"),
            network: "net",
            virtual_cidr: Netwrangler::Util::IPv4Network.parse("10.0.0.#{index + 1}/24"),
            service_name: Netwrangler::Util::QualifiedName.new(name: "svc", namespace: "default"),
            service_uid: "uid",
            interface: "eth0",
          ))
        end

        node.quota_deviation.should eq(1.0_f32) # 2 IPs - 1.0 quota = 1.0
      end

      it "returns negative when node is under quota but has IPs" do
        node = Netwrangler::Controller::IpAllocator::NodeInfo.new("node-1", endpoint_count: 2)
        node.quota = 2.0_f32
        node.add_ip(Netwrangler::Controller::IpAllocator::VipAddressInfo.new(
          name: Netwrangler::Util::QualifiedName.new(name: "test", namespace: "default"),
          network: "net",
          virtual_cidr: Netwrangler::Util::IPv4Network.parse("10.0.0.1/24"),
          service_name: Netwrangler::Util::QualifiedName.new(name: "svc", namespace: "default"),
          service_uid: "uid",
          interface: "eth0",
        ))

        node.quota_deviation.should eq(-1.0_f32) # 1 IP - 2.0 quota = -1.0
      end
    end

    describe "#has_ips?" do
      it "returns false when node has no IPs" do
        node = Netwrangler::Controller::IpAllocator::NodeInfo.new("node-1", endpoint_count: 2)

        node.has_ips?.should be_false
      end

      it "returns true when node has IPs" do
        node = Netwrangler::Controller::IpAllocator::NodeInfo.new("node-1", endpoint_count: 2)
        node.add_ip(Netwrangler::Controller::IpAllocator::VipAddressInfo.new(
          name: Netwrangler::Util::QualifiedName.new(name: "test", namespace: "default"),
          network: "net",
          virtual_cidr: Netwrangler::Util::IPv4Network.parse("10.0.0.1/24"),
          service_name: Netwrangler::Util::QualifiedName.new(name: "svc", namespace: "default"),
          service_uid: "uid",
          interface: "eth0",
        ))

        node.has_ips?.should be_true
      end
    end

    describe "#at_capacity?" do
      it "returns false when no capacity is set" do
        node = Netwrangler::Controller::IpAllocator::NodeInfo.new("node-1", endpoint_count: 2)

        node.at_capacity?.should be_false
      end

      it "returns false when under capacity" do
        node = Netwrangler::Controller::IpAllocator::NodeInfo.new("node-1", endpoint_count: 2)
        node.capacity = 3
        node.add_ip(Netwrangler::Controller::IpAllocator::VipAddressInfo.new(
          name: Netwrangler::Util::QualifiedName.new(name: "test", namespace: "default"),
          network: "net",
          virtual_cidr: Netwrangler::Util::IPv4Network.parse("10.0.0.1/24"),
          service_name: Netwrangler::Util::QualifiedName.new(name: "svc", namespace: "default"),
          service_uid: "uid",
          interface: "eth0",
        ))

        node.at_capacity?.should be_false
      end

      it "returns true when at capacity" do
        node = Netwrangler::Controller::IpAllocator::NodeInfo.new("node-1", endpoint_count: 2)
        node.capacity = 1
        node.add_ip(Netwrangler::Controller::IpAllocator::VipAddressInfo.new(
          name: Netwrangler::Util::QualifiedName.new(name: "test", namespace: "default"),
          network: "net",
          virtual_cidr: Netwrangler::Util::IPv4Network.parse("10.0.0.1/24"),
          service_name: Netwrangler::Util::QualifiedName.new(name: "svc", namespace: "default"),
          service_uid: "uid",
          interface: "eth0",
        ))

        node.at_capacity?.should be_true
      end

      it "returns true when capacity is zero" do
        node = Netwrangler::Controller::IpAllocator::NodeInfo.new("node-1", endpoint_count: 2)
        node.capacity = 0

        node.at_capacity?.should be_true
      end
    end

    describe "#add_ip" do
      it "adds IP to node and sets node_name" do
        node = Netwrangler::Controller::IpAllocator::NodeInfo.new("node-1", endpoint_count: 2)
        ip = Netwrangler::Controller::IpAllocator::VipAddressInfo.new(
          name: Netwrangler::Util::QualifiedName.new(name: "test", namespace: "default"),
          network: "net",
          virtual_cidr: Netwrangler::Util::IPv4Network.parse("10.0.0.1/24"),
          service_name: Netwrangler::Util::QualifiedName.new(name: "svc", namespace: "default"),
          service_uid: "uid",
          interface: "eth0",
        )

        node.add_ip(ip)

        node.vip_addresses.size.should eq(1)
        ip.node_name.should eq("node-1")
      end

      it "raises if IP already belongs to a node" do
        node = Netwrangler::Controller::IpAllocator::NodeInfo.new("node-1", endpoint_count: 2)
        ip = Netwrangler::Controller::IpAllocator::VipAddressInfo.new(
          name: Netwrangler::Util::QualifiedName.new(name: "test", namespace: "default"),
          network: "net",
          virtual_cidr: Netwrangler::Util::IPv4Network.parse("10.0.0.1/24"),
          service_name: Netwrangler::Util::QualifiedName.new(name: "svc", namespace: "default"),
          service_uid: "uid",
          interface: "eth0",

          node_name: "other-node"
        )

        expect_raises(ArgumentError, /already belongs to node/) do
          node.add_ip(ip)
        end
      end
    end

    describe "#remove_last_ip" do
      it "removes and returns the last IP" do
        node = Netwrangler::Controller::IpAllocator::NodeInfo.new("node-1", endpoint_count: 2)
        ip = Netwrangler::Controller::IpAllocator::VipAddressInfo.new(
          name: Netwrangler::Util::QualifiedName.new(name: "test", namespace: "default"),
          network: "net",
          virtual_cidr: Netwrangler::Util::IPv4Network.parse("10.0.0.1/24"),
          service_name: Netwrangler::Util::QualifiedName.new(name: "svc", namespace: "default"),
          service_uid: "uid",
          interface: "eth0",
        )
        node.add_ip(ip)

        removed = node.remove_last_ip

        removed.should eq(ip)
        removed.node_name.should be_nil
        node.vip_addresses.should be_empty
      end

      it "clears node_name on removed IP" do
        node = Netwrangler::Controller::IpAllocator::NodeInfo.new("node-1", endpoint_count: 2)
        ip = Netwrangler::Controller::IpAllocator::VipAddressInfo.new(
          name: Netwrangler::Util::QualifiedName.new(name: "test", namespace: "default"),
          network: "net",
          virtual_cidr: Netwrangler::Util::IPv4Network.parse("10.0.0.1/24"),
          service_name: Netwrangler::Util::QualifiedName.new(name: "svc", namespace: "default"),
          service_uid: "uid",
          interface: "eth0",
        )
        node.add_ip(ip)
        ip.node_name.should eq("node-1")

        removed = node.remove_last_ip
        removed.node_name.should be_nil
      end
    end
  end

  describe Netwrangler::Controller::IpAllocator::ServiceInfo do
    describe "initialization" do
      it "creates service info with name and generation" do
        service_info = Netwrangler::Controller::IpAllocator::ServiceInfo.new(
          Netwrangler::Util::QualifiedName.new(name: "svc", namespace: "default"),
          generation: 1_i64
        )

        service_info.service_name.name.should eq("svc")
        service_info.service_name.namespace.should eq("default")
        service_info.generation.should eq(1_i64)
        service_info.nodes.should be_empty
      end
    end
  end

  describe Netwrangler::Controller::IpAllocator::AllocationResult do
    it "initializes with arrays" do
      result = Netwrangler::Controller::IpAllocator::AllocationResult.new(
        added_ips: [] of Netwrangler::Model::VipAddress,
        updated_ips: [] of Netwrangler::Model::VipAddress,
        deleted_ips: [] of Netwrangler::Model::ObjectReference,
        service_conditions: {} of Netwrangler::Util::QualifiedName => Netwrangler::Model::Condition
      )

      result.added_ips.should be_empty
      result.updated_ips.should be_empty
      result.deleted_ips.should be_empty
      result.service_conditions.should be_empty
    end

    it "returns true for empty? when all arrays empty" do
      result = Netwrangler::Controller::IpAllocator::AllocationResult.new(
        added_ips: [] of Netwrangler::Model::VipAddress,
        updated_ips: [] of Netwrangler::Model::VipAddress,
        deleted_ips: [] of Netwrangler::Model::ObjectReference,
        service_conditions: {} of Netwrangler::Util::QualifiedName => Netwrangler::Model::Condition
      )

      result.empty?.should be_true
    end

    it "returns false for empty? when added_ips not empty" do
      metadata = Netwrangler::Model::ObjectMeta.new(name: "test", namespace: "default")
      spec = Netwrangler::Model::VipAddress::Spec.new(
        network: "net",
        node_name: "node-1",
        virtual_cidr: "10.0.0.1",
        interface: "eth0",
      )
      vip_address = Netwrangler::Model::VipAddress.new(metadata: metadata, spec: spec)

      result = Netwrangler::Controller::IpAllocator::AllocationResult.new(
        added_ips: [vip_address],
        updated_ips: [] of Netwrangler::Model::VipAddress,
        deleted_ips: [] of Netwrangler::Model::ObjectReference,
        service_conditions: {} of Netwrangler::Util::QualifiedName => Netwrangler::Model::Condition
      )

      result.empty?.should be_false
    end

    it "returns correct arrays via getters" do
      metadata = Netwrangler::Model::ObjectMeta.new(name: "test", namespace: "default")
      spec = Netwrangler::Model::VipAddress::Spec.new(
        network: "net",
        node_name: "node-1",
        virtual_cidr: "10.0.0.1",
        interface: "eth0",
      )
      vip_address = Netwrangler::Model::VipAddress.new(metadata: metadata, spec: spec)

      result = Netwrangler::Controller::IpAllocator::AllocationResult.new(
        added_ips: [vip_address],
        updated_ips: [] of Netwrangler::Model::VipAddress,
        deleted_ips: [] of Netwrangler::Model::ObjectReference,
        service_conditions: {} of Netwrangler::Util::QualifiedName => Netwrangler::Model::Condition
      )

      result.added_ips.size.should eq(1)
      result.updated_ips.size.should eq(0)
      result.deleted_ips.size.should eq(0)
    end

    it "handles arrays with multiple items" do
      metadata = Netwrangler::Model::ObjectMeta.new(name: "test", namespace: "default")
      spec = Netwrangler::Model::VipAddress::Spec.new(
        network: "net",
        node_name: "node-1",
        virtual_cidr: "10.0.0.1",
        interface: "eth0",
      )
      vip_address1 = Netwrangler::Model::VipAddress.new(metadata: metadata, spec: spec)
      vip_address2 = Netwrangler::Model::VipAddress.new(metadata: metadata, spec: spec)

      result = Netwrangler::Controller::IpAllocator::AllocationResult.new(
        added_ips: [vip_address1, vip_address2],
        updated_ips: [] of Netwrangler::Model::VipAddress,
        deleted_ips: [] of Netwrangler::Model::ObjectReference,
        service_conditions: {} of Netwrangler::Util::QualifiedName => Netwrangler::Model::Condition
      )

      result.added_ips.size.should eq(2)
      result.empty?.should be_false
    end
  end

  describe Netwrangler::Controller::IpAllocator::VipAddressInfo do
    it "supports equality with all fields matching" do
      info1 = Netwrangler::Controller::IpAllocator::VipAddressInfo.new(
        name: Netwrangler::Util::QualifiedName.new(name: "test", namespace: "default"),
        network: "net",
        virtual_cidr: Netwrangler::Util::IPv4Network.parse("10.0.0.1/24"),
        service_name: Netwrangler::Util::QualifiedName.new(name: "svc", namespace: "default"),
        service_uid: "uid",
        interface: "eth0",

        gateway_ip: Netwrangler::Util::IPv4Address.parse("10.0.0.254"),
        node_name: "node-1"
      )

      info2 = Netwrangler::Controller::IpAllocator::VipAddressInfo.new(
        name: Netwrangler::Util::QualifiedName.new(name: "test", namespace: "default"),
        network: "net",
        virtual_cidr: Netwrangler::Util::IPv4Network.parse("10.0.0.1/24"),
        service_name: Netwrangler::Util::QualifiedName.new(name: "svc", namespace: "default"),
        service_uid: "uid",
        interface: "eth0",

        gateway_ip: Netwrangler::Util::IPv4Address.parse("10.0.0.254"),
        node_name: "node-1"
      )

      info1.should eq(info2)
    end

    it "returns inequality when node_name differs" do
      info1 = Netwrangler::Controller::IpAllocator::VipAddressInfo.new(
        name: Netwrangler::Util::QualifiedName.new(name: "test", namespace: "default"),
        network: "net",
        virtual_cidr: Netwrangler::Util::IPv4Network.parse("10.0.0.1/24"),
        service_name: Netwrangler::Util::QualifiedName.new(name: "svc", namespace: "default"),
        service_uid: "uid",
        interface: "eth0",

        node_name: "node-1"
      )

      info2 = Netwrangler::Controller::IpAllocator::VipAddressInfo.new(
        name: Netwrangler::Util::QualifiedName.new(name: "test", namespace: "default"),
        network: "net",
        virtual_cidr: Netwrangler::Util::IPv4Network.parse("10.0.0.1/24"),
        service_name: Netwrangler::Util::QualifiedName.new(name: "svc", namespace: "default"),
        service_uid: "uid",
        interface: "eth0",

        node_name: "node-2"
      )

      info1.should_not eq(info2)
    end

    it "returns inequality when vip_address differs" do
      info1 = Netwrangler::Controller::IpAllocator::VipAddressInfo.new(
        name: Netwrangler::Util::QualifiedName.new(name: "test", namespace: "default"),
        network: "net",
        virtual_cidr: Netwrangler::Util::IPv4Network.parse("10.0.0.1/24"),
        service_name: Netwrangler::Util::QualifiedName.new(name: "svc", namespace: "default"),
        service_uid: "uid",
        interface: "eth0",
      )

      info2 = Netwrangler::Controller::IpAllocator::VipAddressInfo.new(
        name: Netwrangler::Util::QualifiedName.new(name: "test", namespace: "default"),
        network: "net",
        virtual_cidr: Netwrangler::Util::IPv4Network.parse("10.0.0.2/24"),
        service_name: Netwrangler::Util::QualifiedName.new(name: "svc", namespace: "default"),
        service_uid: "uid",
        interface: "eth0",
      )

      info1.should_not eq(info2)
    end

    it "returns inequality when endpoint_ips differs" do
      info1 = Netwrangler::Controller::IpAllocator::VipAddressInfo.new(
        name: Netwrangler::Util::QualifiedName.new(name: "test", namespace: "default"),
        network: "net",
        virtual_cidr: Netwrangler::Util::IPv4Network.parse("10.0.0.1/24"),
        service_name: Netwrangler::Util::QualifiedName.new(name: "svc", namespace: "default"),
        service_uid: "uid",
        interface: "eth0",

        endpoint_ips: ["10.244.1.1"]
      )

      info2 = Netwrangler::Controller::IpAllocator::VipAddressInfo.new(
        name: Netwrangler::Util::QualifiedName.new(name: "test", namespace: "default"),
        network: "net",
        virtual_cidr: Netwrangler::Util::IPv4Network.parse("10.0.0.1/24"),
        service_name: Netwrangler::Util::QualifiedName.new(name: "svc", namespace: "default"),
        service_uid: "uid",
        interface: "eth0",

        endpoint_ips: ["10.244.2.1"]
      )

      info1.should_not eq(info2)
    end

    it "supports hash equality for use as Hash keys" do
      info1 = Netwrangler::Controller::IpAllocator::VipAddressInfo.new(
        name: Netwrangler::Util::QualifiedName.new(name: "test", namespace: "default"),
        network: "net",
        virtual_cidr: Netwrangler::Util::IPv4Network.parse("10.0.0.1/24"),
        service_name: Netwrangler::Util::QualifiedName.new(name: "svc", namespace: "default"),
        service_uid: "uid",
        interface: "eth0",
      )

      info2 = Netwrangler::Controller::IpAllocator::VipAddressInfo.new(
        name: Netwrangler::Util::QualifiedName.new(name: "test", namespace: "default"),
        network: "net",
        virtual_cidr: Netwrangler::Util::IPv4Network.parse("10.0.0.1/24"),
        service_name: Netwrangler::Util::QualifiedName.new(name: "svc", namespace: "default"),
        service_uid: "uid",
        interface: "eth0",
      )

      hash = {info1 => "value"}
      hash[info2]?.should eq("value")
    end
  end

  describe "#allocate" do
    it "returns empty result when no services" do
      allocator = Netwrangler::Controller::IpAllocator.new(
        services: [] of Netwrangler::Model::Service,
        endpoint_slices: [] of Netwrangler::Model::EndpointSlice,
        vip_networks: [] of Netwrangler::Model::VipNetwork,
        vip_addresses: [] of Netwrangler::Model::VipAddress,
        vip_configs: [ControllerFixtures.vip_config],
      )

      result = allocator.allocate
      result.empty?.should be_true
    end

    it "adds new virtual IPs for new service" do
      scenario = ControllerFixtures.multi_node_service_scenario(
        node_count: 2,
        ips_per_service: 2,
        endpoints_per_node: [2, 2]
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
      result.updated_ips.should be_empty
      result.deleted_ips.should be_empty
    end

    it "returns empty result when allocations unchanged" do
      scenario = ControllerFixtures.multi_node_service_scenario(
        node_count: 2,
        ips_per_service: 2,
        endpoints_per_node: [2, 2]
      )

      # First allocation
      allocator1 = Netwrangler::Controller::IpAllocator.new(
        services: scenario[:services],
        endpoint_slices: scenario[:endpoint_slices],
        vip_networks: scenario[:vip_networks],
        vip_addresses: [] of Netwrangler::Model::VipAddress,
        vip_configs: [ControllerFixtures.vip_config],
      )
      result1 = allocator1.allocate

      # Use added IPs directly (they are already Model::VipAddress)
      existing_ips = result1.added_ips

      # Second allocation with existing IPs
      allocator2 = Netwrangler::Controller::IpAllocator.new(
        services: scenario[:services],
        endpoint_slices: scenario[:endpoint_slices],
        vip_networks: scenario[:vip_networks],
        vip_addresses: existing_ips,
        vip_configs: [ControllerFixtures.vip_config],
      )
      result2 = allocator2.allocate

      result2.empty?.should be_true
    end

    it "deletes virtual IPs for deleted service" do
      # Create existing allocation with managed-by label
      existing_ip = ControllerFixtures.vip_address(
        name: "test-network-10-0-1-11",
        virtual_cidr: "10.0.1.11",
        labels: {"netwrangler.dev/managed-by" => "netwrangler"}
      )

      # Allocate with no services (simulating deletion)
      allocator = Netwrangler::Controller::IpAllocator.new(
        services: [] of Netwrangler::Model::Service,
        endpoint_slices: [] of Netwrangler::Model::EndpointSlice,
        vip_networks: [] of Netwrangler::Model::VipNetwork,
        vip_addresses: [existing_ip],
        vip_configs: [ControllerFixtures.vip_config],
      )

      result = allocator.allocate
      result.added_ips.should be_empty
      result.updated_ips.should be_empty
      result.deleted_ips.size.should eq(1)
    end

    it "does not delete virtual IPs without managed-by label" do
      # Create existing allocation without managed-by label (not created by this controller)
      existing_ip = ControllerFixtures.vip_address(
        name: "test-network-10-0-1-11",
        virtual_cidr: "10.0.1.11"
      )

      allocator = Netwrangler::Controller::IpAllocator.new(
        services: [] of Netwrangler::Model::Service,
        endpoint_slices: [] of Netwrangler::Model::EndpointSlice,
        vip_networks: [] of Netwrangler::Model::VipNetwork,
        vip_addresses: [existing_ip],
        vip_configs: [ControllerFixtures.vip_config],
      )

      result = allocator.allocate
      result.deleted_ips.should be_empty
    end

    it "does not delete virtual IPs managed by a different controller" do
      # Create existing allocation with a different managed-by value
      existing_ip = ControllerFixtures.vip_address(
        name: "test-network-10-0-1-11",
        virtual_cidr: "10.0.1.11",
        labels: {"netwrangler.dev/managed-by" => "other-controller"}
      )

      allocator = Netwrangler::Controller::IpAllocator.new(
        services: [] of Netwrangler::Model::Service,
        endpoint_slices: [] of Netwrangler::Model::EndpointSlice,
        vip_networks: [] of Netwrangler::Model::VipNetwork,
        vip_addresses: [existing_ip],
        vip_configs: [ControllerFixtures.vip_config],
      )

      result = allocator.allocate
      result.deleted_ips.should be_empty
    end

    it "deletes virtual IPs matching custom manager name" do
      existing_ip = ControllerFixtures.vip_address(
        name: "test-network-10-0-1-11",
        virtual_cidr: "10.0.1.11",
        labels: {"netwrangler.dev/managed-by" => "custom-manager"}
      )

      allocator = Netwrangler::Controller::IpAllocator.new(
        services: [] of Netwrangler::Model::Service,
        endpoint_slices: [] of Netwrangler::Model::EndpointSlice,
        vip_networks: [] of Netwrangler::Model::VipNetwork,
        vip_addresses: [existing_ip],
        vip_configs: [ControllerFixtures.vip_config],
        manager_name: "custom-manager",
      )

      result = allocator.allocate
      result.deleted_ips.size.should eq(1)
    end

    it "processes multiple services in single allocation" do
      # Create two services
      service1 = ControllerFixtures.service(
        name: "service-1",
        external_ips: ["10.0.1.10"]
      )
      service2 = ControllerFixtures.service(
        name: "service-2",
        external_ips: ["10.0.1.20"]
      )

      endpoint_slice1 = ControllerFixtures.endpoint_slice(
        name: "service-1-abc",
        service_name: "service-1",
        nodes: ["node-1"]
      )
      endpoint_slice2 = ControllerFixtures.endpoint_slice(
        name: "service-2-def",
        service_name: "service-2",
        nodes: ["node-2"]
      )

      network = ControllerFixtures.vip_network

      allocator = Netwrangler::Controller::IpAllocator.new(
        services: [service1, service2],
        endpoint_slices: [endpoint_slice1, endpoint_slice2],
        vip_networks: [network],
        vip_addresses: [] of Netwrangler::Model::VipAddress,
        vip_configs: [ControllerFixtures.vip_config],
      )

      result = allocator.allocate
      result.added_ips.size.should eq(2)
    end

    it "skips services with no virtual IPs" do
      service = ControllerFixtures.service(
        external_ips: [] of String
      )
      endpoint_slice = ControllerFixtures.endpoint_slice
      network = ControllerFixtures.vip_network

      allocator = Netwrangler::Controller::IpAllocator.new(
        services: [service],
        endpoint_slices: [endpoint_slice],
        vip_networks: [network],
        vip_addresses: [] of Netwrangler::Model::VipAddress,
        vip_configs: [ControllerFixtures.vip_config],
      )

      result = allocator.allocate
      result.empty?.should be_true
    end

    it "skips services when IP does not match any VipNetwork CIDR" do
      service = ControllerFixtures.service(
        external_ips: ["192.168.99.10"]
      )
      endpoint_slice = ControllerFixtures.endpoint_slice
      network = ControllerFixtures.vip_network # 10.0.1.0/24

      allocator = Netwrangler::Controller::IpAllocator.new(
        services: [service],
        endpoint_slices: [endpoint_slice],
        vip_networks: [network],
        vip_addresses: [] of Netwrangler::Model::VipAddress,
        vip_configs: [ControllerFixtures.vip_config],
      )

      result = allocator.allocate
      result.empty?.should be_true
    end

    it "skips services when no VipNetworks are defined" do
      service = ControllerFixtures.service
      endpoint_slice = ControllerFixtures.endpoint_slice

      allocator = Netwrangler::Controller::IpAllocator.new(
        services: [service],
        endpoint_slices: [endpoint_slice],
        vip_networks: [] of Netwrangler::Model::VipNetwork,
        vip_addresses: [] of Netwrangler::Model::VipAddress,
        vip_configs: [ControllerFixtures.vip_config],
      )

      result = allocator.allocate
      result.empty?.should be_true
    end

    it "skips services with no ready endpoints" do
      service = ControllerFixtures.service
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

    it "includes endpoint IPs in created VipAddress resources" do
      service = ControllerFixtures.service(
        external_ips: ["10.0.1.10"]
      )
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
      result.added_ips.size.should eq(1)
      result.added_ips.first.spec.endpoint_ips.should eq(["10.244.1.1", "10.244.1.2"])
    end

    it "gives all VipAddresses on same node the same endpoint IPs" do
      service = ControllerFixtures.service(
        external_ips: ["10.0.1.10", "10.0.1.11"]
      )
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
      result.added_ips.size.should eq(2)
      result.added_ips.each do |ip|
        ip.spec.endpoint_ips.should eq(["10.244.1.1", "10.244.1.2"])
      end
    end

    it "includes node-name label in created VipAddress resources" do
      service = ControllerFixtures.service(
        external_ips: ["10.0.1.10"]
      )
      endpoint_slice = ControllerFixtures.endpoint_slice(
        nodes: ["node-1"]
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
      result.added_ips.size.should eq(1)

      vip_address = result.added_ips.first
      vip_address.metadata.labels.try(&.["netwrangler.dev/node-name"]?).should eq("node-1")
    end

    it "includes ports from service in created VipAddress resources" do
      service = ControllerFixtures.service(
        external_ips: ["10.0.1.10"],
        ports: [
          Netwrangler::Model::ServicePort.new(port: 80, protocol: "TCP"),
          Netwrangler::Model::ServicePort.new(port: 443, protocol: "TCP"),
        ]
      )
      endpoint_slice = ControllerFixtures.endpoint_slice(
        nodes: ["node-1"]
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
      result.added_ips.size.should eq(1)

      vip_address = result.added_ips.first
      vip_address.ports.size.should eq(2)
      vip_address.ports[0].port.should eq(80)
      vip_address.ports[0].protocol.should eq("TCP")
      vip_address.ports[1].port.should eq(443)
      vip_address.ports[1].protocol.should eq("TCP")
    end

    it "defaults protocol to TCP when service port has no protocol" do
      service = ControllerFixtures.service(
        external_ips: ["10.0.1.10"],
        ports: [Netwrangler::Model::ServicePort.new(port: 80)]
      )
      endpoint_slice = ControllerFixtures.endpoint_slice(
        nodes: ["node-1"]
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
      result.added_ips.first.ports.first.protocol.should eq("TCP")
    end
  end

  describe "allocation" do
    describe "resource naming" do
      it "names VipAddress as {serviceName}-{index}" do
        allocator = Netwrangler::Controller::IpAllocator.new(
          services: [ControllerFixtures.service(external_ips: ["10.0.1.10"])],
          endpoint_slices: [ControllerFixtures.endpoint_slice(nodes: ["node-1"])],
          vip_networks: [ControllerFixtures.vip_network],
          vip_addresses: [] of Netwrangler::Model::VipAddress,
          vip_configs: [ControllerFixtures.vip_config],
        )

        result = allocator.allocate
        result.added_ips.size.should eq(1)
        result.added_ips.first.metadata.name.should eq("test-service-1")
      end

      it "assigns sequential indices to multiple VipAddresses" do
        allocator = Netwrangler::Controller::IpAllocator.new(
          services: [ControllerFixtures.service(external_ips: ["10.0.1.10", "10.0.1.11", "10.0.1.12"])],
          endpoint_slices: [ControllerFixtures.endpoint_slice(nodes: ["node-1"])],
          vip_networks: [ControllerFixtures.vip_network],
          vip_addresses: [] of Netwrangler::Model::VipAddress,
          vip_configs: [ControllerFixtures.vip_config],
        )

        result = allocator.allocate
        names = result.added_ips.compact_map(&.metadata.name).sort!
        names.should eq(["test-service-1", "test-service-2", "test-service-3"])
      end

      it "preserves existing names and fills gaps" do
        existing = ControllerFixtures.vip_address(
          name: "test-service-2",
          virtual_cidr: "10.0.1.10/24",
          node_name: "node-1",
          firewall_mark: 0x010000,
          route_table: 100,
          routing_priority: 100,
          labels: {
            "netwrangler.dev/managed-by" => "netwrangler",
            "netwrangler.dev/namespace"  => "default",
            "netwrangler.dev/network"    => "test-network",
            "netwrangler.dev/service"    => "test-service",
            "netwrangler.dev/node-name"  => "node-1",
          },
        )

        allocator = Netwrangler::Controller::IpAllocator.new(
          services: [ControllerFixtures.service(external_ips: ["10.0.1.10", "10.0.1.11"])],
          endpoint_slices: [ControllerFixtures.endpoint_slice(nodes: ["node-1"])],
          vip_networks: [ControllerFixtures.vip_network],
          vip_addresses: [existing],
          vip_configs: [ControllerFixtures.vip_config],
        )

        result = allocator.allocate
        all_ips = result.added_ips + result.updated_ips
        all_ips.size.should be >= 1

        # The new IP should get index 1 (lowest free, since 2 is taken)
        new_ip = all_ips.find! { |ip| ip.virtual_cidr == "10.0.1.11/24" }
        new_ip.metadata.name.should eq("test-service-1")
      end
    end

    describe "route resource allocation" do
      it "allocates firewall mark, route table, and priority from VipConfig base values" do
        config = ControllerFixtures.vip_config(
          firewall_mark: 0x010000,
          route_table: 200,
          routing_priority: 300,
        )

        allocator = Netwrangler::Controller::IpAllocator.new(
          services: [ControllerFixtures.service(external_ips: ["10.0.1.10"])],
          endpoint_slices: [ControllerFixtures.endpoint_slice(nodes: ["node-1"])],
          vip_networks: [ControllerFixtures.vip_network],
          vip_addresses: [] of Netwrangler::Model::VipAddress,
          vip_configs: [config],
        )

        result = allocator.allocate
        ip = result.added_ips.first
        ip.firewall_mark.should eq(0x010000)
        ip.route_table.should eq(200)
        ip.routing_priority.should eq(300)
      end

      it "allocates unique values for multiple VipAddresses" do
        config = ControllerFixtures.vip_config(
          firewall_mark: 0x010000,
          route_table: 200,
          routing_priority: 300,
        )

        allocator = Netwrangler::Controller::IpAllocator.new(
          services: [ControllerFixtures.service(external_ips: ["10.0.1.10", "10.0.1.11"])],
          endpoint_slices: [ControllerFixtures.endpoint_slice(nodes: ["node-1"])],
          vip_networks: [ControllerFixtures.vip_network],
          vip_addresses: [] of Netwrangler::Model::VipAddress,
          vip_configs: [config],
        )

        result = allocator.allocate
        marks = result.added_ips.compact_map(&.firewall_mark).sort!
        tables = result.added_ips.compact_map(&.route_table).sort!
        priorities = result.added_ips.compact_map(&.routing_priority).sort!

        marks.should eq([0x010000, 0x010001])
        tables.should eq([200, 201])
        priorities.should eq([300, 301])
      end

      it "allocates unique values across multiple services" do
        config = ControllerFixtures.vip_config(
          firewall_mark: 0x010000,
          route_table: 200,
          routing_priority: 300,
        )

        service1 = ControllerFixtures.service(
          name: "svc-a",
          uid: "svc-a-uid",
          external_ips: ["10.0.1.10"],
        )
        service2 = ControllerFixtures.service(
          name: "svc-b",
          uid: "svc-b-uid",
          external_ips: ["10.0.1.11"],
        )

        allocator = Netwrangler::Controller::IpAllocator.new(
          services: [service1, service2],
          endpoint_slices: [
            ControllerFixtures.endpoint_slice(service_name: "svc-a", nodes: ["node-1"]),
            ControllerFixtures.endpoint_slice(name: "eps-2", service_name: "svc-b", nodes: ["node-1"]),
          ],
          vip_networks: [ControllerFixtures.vip_network],
          vip_addresses: [] of Netwrangler::Model::VipAddress,
          vip_configs: [config],
        )

        result = allocator.allocate
        marks = result.added_ips.compact_map(&.firewall_mark).sort!
        tables = result.added_ips.compact_map(&.route_table).sort!
        priorities = result.added_ips.compact_map(&.routing_priority).sort!

        marks.uniq.size.should eq(2)
        tables.uniq.size.should eq(2)
        priorities.uniq.size.should eq(2)
      end

      it "repairs existing duplicate firewall marks across services" do
        config = ControllerFixtures.vip_config(
          firewall_mark: 0x010000,
          route_table: 200,
          routing_priority: 300,
        )

        service1 = ControllerFixtures.service(
          name: "svc-a",
          uid: "svc-a-uid",
          external_ips: ["10.0.1.10"],
        )
        service2 = ControllerFixtures.service(
          name: "svc-b",
          uid: "svc-b-uid",
          external_ips: ["10.0.1.11"],
        )

        # Both existing VipAddresses have the same firewall mark (duplicate)
        existing_vip1 = ControllerFixtures.vip_address(
          name: "svc-a-1", namespace: "default",
          network: "test-network", virtual_cidr: "10.0.1.10/24",
          node_name: "node-1", interface: "eth0",
          firewall_mark: 0x010000, route_table: 200, routing_priority: 300,
        )
        existing_vip2 = ControllerFixtures.vip_address(
          name: "svc-b-1", namespace: "default",
          network: "test-network", virtual_cidr: "10.0.1.11/24",
          node_name: "node-1", interface: "eth0",
          firewall_mark: 0x010000, route_table: 200, routing_priority: 300,
        )

        allocator = Netwrangler::Controller::IpAllocator.new(
          services: [service1, service2],
          endpoint_slices: [
            ControllerFixtures.endpoint_slice(service_name: "svc-a", nodes: ["node-1"]),
            ControllerFixtures.endpoint_slice(name: "eps-2", service_name: "svc-b", nodes: ["node-1"]),
          ],
          vip_networks: [ControllerFixtures.vip_network],
          vip_addresses: [existing_vip1, existing_vip2],
          vip_configs: [config],
        )

        result = allocator.allocate

        all_ips = result.added_ips + result.updated_ips
        marks = all_ips.compact_map(&.firewall_mark)
        tables = all_ips.compact_map(&.route_table)
        priorities = all_ips.compact_map(&.routing_priority)

        marks.uniq.size.should eq(marks.size)
        tables.uniq.size.should eq(tables.size)
        priorities.uniq.size.should eq(priorities.size)
      end

      it "does not assign VIPs without VipConfig" do
        allocator = Netwrangler::Controller::IpAllocator.new(
          services: [ControllerFixtures.service(external_ips: ["10.0.1.10"])],
          endpoint_slices: [ControllerFixtures.endpoint_slice(nodes: ["node-1"])],
          vip_networks: [ControllerFixtures.vip_network],
          vip_addresses: [] of Netwrangler::Model::VipAddress,
        )

        result = allocator.allocate
        result.added_ips.should be_empty
      end
    end

    describe "service identity in resource name" do
      it "uses service name and namespace from the Service" do
        allocator = Netwrangler::Controller::IpAllocator.new(
          services: [ControllerFixtures.service(name: "my-svc", namespace: "my-ns", uid: "uid-1")],
          endpoint_slices: [ControllerFixtures.endpoint_slice(namespace: "my-ns", service_name: "my-svc", nodes: ["node-1"])],
          vip_networks: [ControllerFixtures.vip_network],
          vip_addresses: [] of Netwrangler::Model::VipAddress,
          vip_configs: [ControllerFixtures.vip_config],
        )

        result = allocator.allocate
        ip = result.added_ips.first
        ip.metadata.name.should eq("my-svc-1")
        ip.metadata.namespace.should eq("my-ns")
      end
    end

    describe "egress label" do
      it "sets egress_enabled when service has egress label" do
        service = ControllerFixtures.service
        service.metadata.labels!["netwrangler.dev/egress"] = "enabled"

        allocator = Netwrangler::Controller::IpAllocator.new(
          services: [service],
          endpoint_slices: [ControllerFixtures.endpoint_slice(nodes: ["node-1"])],
          vip_networks: [ControllerFixtures.vip_network],
          vip_addresses: [] of Netwrangler::Model::VipAddress,
          vip_configs: [ControllerFixtures.vip_config],
        )

        result = allocator.allocate
        result.added_ips.first.egress_enabled.should be_true
      end

      it "does not set egress_enabled without egress label" do
        allocator = Netwrangler::Controller::IpAllocator.new(
          services: [ControllerFixtures.service],
          endpoint_slices: [ControllerFixtures.endpoint_slice(nodes: ["node-1"])],
          vip_networks: [ControllerFixtures.vip_network],
          vip_addresses: [] of Netwrangler::Model::VipAddress,
          vip_configs: [ControllerFixtures.vip_config],
        )

        result = allocator.allocate
        result.added_ips.first.egress_enabled.should be_false
      end
    end

    describe "service validation" do
      it "accepts services without externalTrafficPolicy=Local" do
        allocator = Netwrangler::Controller::IpAllocator.new(
          services: [ControllerFixtures.service(external_traffic_policy: "Cluster")],
          endpoint_slices: [ControllerFixtures.endpoint_slice(nodes: ["node-1"])],
          vip_networks: [ControllerFixtures.vip_network],
          vip_addresses: [] of Netwrangler::Model::VipAddress,
          vip_configs: [ControllerFixtures.vip_config],
        )

        result = allocator.allocate
        result.added_ips.size.should eq(1)
      end

      it "rejects services when IP does not match any VipNetwork" do
        allocator = Netwrangler::Controller::IpAllocator.new(
          services: [ControllerFixtures.service(external_ips: ["192.168.99.10"])],
          endpoint_slices: [ControllerFixtures.endpoint_slice(nodes: ["node-1"])],
          vip_networks: [ControllerFixtures.vip_network],
          vip_addresses: [] of Netwrangler::Model::VipAddress,
          vip_configs: [ControllerFixtures.vip_config],
        )

        result = allocator.allocate
        result.added_ips.should be_empty
      end
    end

    describe "port extraction" do
      it "extracts ports from the service spec" do
        ports = [
          Netwrangler::Model::ServicePort.new(port: 80, protocol: "TCP"),
          Netwrangler::Model::ServicePort.new(port: 443, protocol: "TCP"),
        ]

        allocator = Netwrangler::Controller::IpAllocator.new(
          services: [ControllerFixtures.service(ports: ports)],
          endpoint_slices: [ControllerFixtures.endpoint_slice(nodes: ["node-1"])],
          vip_networks: [ControllerFixtures.vip_network],
          vip_addresses: [] of Netwrangler::Model::VipAddress,
          vip_configs: [ControllerFixtures.vip_config],
        )

        result = allocator.allocate
        ip = result.added_ips.first
        ip.ports.size.should eq(2)
        ip.ports.map(&.port).sort!.should eq([80, 443])
      end
    end

    describe "error conditions" do
      it "produces error condition for invalid virtual IP" do
        service = ControllerFixtures.service(
          external_ips: ["999.0.0.1"]
        )

        allocator = Netwrangler::Controller::IpAllocator.new(
          services: [service],
          endpoint_slices: [ControllerFixtures.endpoint_slice(nodes: ["node-1"])],
          vip_networks: [ControllerFixtures.vip_network],
          vip_addresses: [] of Netwrangler::Model::VipAddress,
          vip_configs: [ControllerFixtures.vip_config],
        )

        result = allocator.allocate
        result.added_ips.should be_empty
        result.updated_ips.should be_empty
        result.deleted_ips.should be_empty

        service_name = Netwrangler::Util::QualifiedName.new(name: "test-service", namespace: "default")
        condition = result.service_conditions[service_name]
        condition.type.should eq("IpAllocated")
        condition.status.should eq("False")
        condition.message!.should contain("Invalid IPv4 address")
      end

      it "produces error condition when IP does not match any VipNetwork" do
        service = ControllerFixtures.service(
          external_ips: ["192.168.99.10"]
        )

        allocator = Netwrangler::Controller::IpAllocator.new(
          services: [service],
          endpoint_slices: [ControllerFixtures.endpoint_slice(nodes: ["node-1"])],
          vip_networks: [ControllerFixtures.vip_network],
          vip_addresses: [] of Netwrangler::Model::VipAddress,
          vip_configs: [ControllerFixtures.vip_config],
        )

        result = allocator.allocate
        result.added_ips.should be_empty

        service_name = Netwrangler::Util::QualifiedName.new(name: "test-service", namespace: "default")
        condition = result.service_conditions[service_name]
        condition.type.should eq("IpAllocated")
        condition.status.should eq("False")
        condition.message!.should contain("does not match any VipNetwork")
      end

      it "produces error condition when no ready endpoints exist" do
        service = ControllerFixtures.service
        network = ControllerFixtures.vip_network

        allocator = Netwrangler::Controller::IpAllocator.new(
          services: [service],
          endpoint_slices: [] of Netwrangler::Model::EndpointSlice,
          vip_networks: [network],
          vip_addresses: [] of Netwrangler::Model::VipAddress,
          vip_configs: [ControllerFixtures.vip_config],
        )

        result = allocator.allocate
        result.added_ips.should be_empty

        service_name = Netwrangler::Util::QualifiedName.new(name: "test-service", namespace: "default")
        condition = result.service_conditions[service_name]
        condition.type.should eq("IpAllocated")
        condition.status.should eq("False")
        condition.message!.should contain("No ready endpoints found")
      end

      it "produces ok condition for valid service" do
        allocator = Netwrangler::Controller::IpAllocator.new(
          services: [ControllerFixtures.service(external_ips: ["10.0.1.10"])],
          endpoint_slices: [ControllerFixtures.endpoint_slice(nodes: ["node-1"])],
          vip_networks: [ControllerFixtures.vip_network],
          vip_addresses: [] of Netwrangler::Model::VipAddress,
          vip_configs: [ControllerFixtures.vip_config],
        )

        result = allocator.allocate

        service_name = Netwrangler::Util::QualifiedName.new(name: "test-service", namespace: "default")
        condition = result.service_conditions[service_name]
        condition.type.should eq("IpAllocated")
        condition.status.should eq("True")
        condition.reason.should eq("Ok")
      end
    end

    describe "stale VipAddress deletion" do
      it "deletes managed VipAddress with no corresponding service" do
        stale_vip = ControllerFixtures.vip_address(
          name: "old-service-1",
          namespace: "default",
          virtual_cidr: "10.0.1.99",
          node_name: "node-1",
          labels: {
            "netwrangler.dev/managed-by" => "netwrangler",
            "netwrangler.dev/namespace"  => "default",
            "netwrangler.dev/service"    => "old-service",
            "netwrangler.dev/node-name"  => "node-1",
          },
        )

        allocator = Netwrangler::Controller::IpAllocator.new(
          services: [] of Netwrangler::Model::Service,
          endpoint_slices: [] of Netwrangler::Model::EndpointSlice,
          vip_networks: [] of Netwrangler::Model::VipNetwork,
          vip_addresses: [stale_vip],
          vip_configs: [ControllerFixtures.vip_config],
        )

        result = allocator.allocate
        result.added_ips.should be_empty
        result.updated_ips.should be_empty
        result.deleted_ips.size.should eq(1)
        result.deleted_ips.first.name.should eq("old-service-1")
        result.deleted_ips.first.namespace.should eq("default")
      end

      it "deletes managed VipAddress when service exists but IP no longer in service spec" do
        service = ControllerFixtures.service(
          external_ips: ["10.0.1.10"]
        )
        endpoint_slice = ControllerFixtures.endpoint_slice(nodes: ["node-1"])
        network = ControllerFixtures.vip_network

        # Existing VipAddress for an IP that is no longer in the service spec
        stale_vip = ControllerFixtures.vip_address(
          name: "test-service-2",
          namespace: "default",
          virtual_cidr: "10.0.1.20",
          node_name: "node-1",
          labels: {
            "netwrangler.dev/managed-by" => "netwrangler",
            "netwrangler.dev/namespace"  => "default",
            "netwrangler.dev/network"    => "test-network",
            "netwrangler.dev/service"    => "test-service",
            "netwrangler.dev/node-name"  => "node-1",
          },
        )

        allocator = Netwrangler::Controller::IpAllocator.new(
          services: [service],
          endpoint_slices: [endpoint_slice],
          vip_networks: [network],
          vip_addresses: [stale_vip],
          vip_configs: [ControllerFixtures.vip_config],
        )

        result = allocator.allocate
        result.deleted_ips.size.should eq(1)
        result.deleted_ips.first.name.should eq("test-service-2")
      end

      it "does not delete unmanaged VipAddress even when no corresponding service exists" do
        unmanaged_vip = ControllerFixtures.vip_address(
          name: "external-vip-1",
          namespace: "default",
          virtual_cidr: "10.0.1.99",
          node_name: "node-1",
        )

        allocator = Netwrangler::Controller::IpAllocator.new(
          services: [] of Netwrangler::Model::Service,
          endpoint_slices: [] of Netwrangler::Model::EndpointSlice,
          vip_networks: [] of Netwrangler::Model::VipNetwork,
          vip_addresses: [unmanaged_vip],
          vip_configs: [ControllerFixtures.vip_config],
        )

        result = allocator.allocate
        result.deleted_ips.should be_empty
      end
    end
  end

  describe "per-node fwmark capacity" do
    it "limits VIPs per node to fwmark capacity" do
      # Mask 0x030000 has 2 set bits → capacity = 3
      config = ControllerFixtures.vip_config(firewall_mark_mask: 0x030000_u32)

      allocator = Netwrangler::Controller::IpAllocator.new(
        services: [ControllerFixtures.service(external_ips: (1..7).map { |index| "10.0.1.#{10 + index}" })],
        endpoint_slices: [
          ControllerFixtures.endpoint_slice(name: "ep-1", nodes: ["node-1"]),
          ControllerFixtures.endpoint_slice(name: "ep-2", nodes: ["node-2"]),
        ],
        vip_networks: [ControllerFixtures.vip_network],
        vip_addresses: [] of Netwrangler::Model::VipAddress,
        vip_configs: [config],
      )

      result = allocator.allocate
      # 2 nodes × 3 cap = 6 max, 7 requested → 6 assigned, 1 unassigned
      result.added_ips.size.should eq(6)

      node_counts = result.added_ips.group_by(&.node_name).transform_values(&.size)
      node_counts.each_value do |count|
        count.should be <= 3
      end
    end

    it "does not cap when mask allows more than max_address_count" do
      # Default mask 0xFF0000 has capacity 255, max_address_count 254 → cap is 254
      allocator = Netwrangler::Controller::IpAllocator.new(
        services: [ControllerFixtures.service(external_ips: ["10.0.1.11", "10.0.1.12", "10.0.1.13"])],
        endpoint_slices: [ControllerFixtures.endpoint_slice(nodes: ["node-1"])],
        vip_networks: [ControllerFixtures.vip_network],
        vip_addresses: [] of Netwrangler::Model::VipAddress,
        vip_configs: [ControllerFixtures.vip_config],
      )

      result = allocator.allocate
      result.added_ips.size.should eq(3)
    end

    it "does not claim existing IPs beyond capacity" do
      # Mask 0x010000 has 1 set bit → capacity = 1 per node
      config = ControllerFixtures.vip_config(firewall_mark_mask: 0x010000_u32)

      existing_vip1 = ControllerFixtures.vip_address(
        name: "test-service-1", virtual_cidr: "10.0.1.11/24", node_name: "node-1",
        firewall_mark: 0x010000, route_table: 100, routing_priority: 100,
        labels: {
          "netwrangler.dev/managed-by" => "netwrangler",
          "netwrangler.dev/namespace"  => "default",
          "netwrangler.dev/network"    => "test-network",
          "netwrangler.dev/service"    => "test-service",
          "netwrangler.dev/node-name"  => "node-1",
        },
      )
      existing_vip2 = ControllerFixtures.vip_address(
        name: "test-service-2", virtual_cidr: "10.0.1.12/24", node_name: "node-1",
        firewall_mark: 0x010001, route_table: 101, routing_priority: 101,
        labels: {
          "netwrangler.dev/managed-by" => "netwrangler",
          "netwrangler.dev/namespace"  => "default",
          "netwrangler.dev/network"    => "test-network",
          "netwrangler.dev/service"    => "test-service",
          "netwrangler.dev/node-name"  => "node-1",
        },
      )

      allocator = Netwrangler::Controller::IpAllocator.new(
        services: [ControllerFixtures.service(external_ips: ["10.0.1.11", "10.0.1.12"])],
        endpoint_slices: [
          ControllerFixtures.endpoint_slice(name: "ep-1", nodes: ["node-1"]),
          ControllerFixtures.endpoint_slice(name: "ep-2", nodes: ["node-2"]),
        ],
        vip_networks: [ControllerFixtures.vip_network],
        vip_addresses: [existing_vip1, existing_vip2],
        vip_configs: [config],
      )

      result = allocator.allocate
      # node-1 had 2 VIPs but cap is 1, so only 1 claimed, other goes to node-2
      node_counts = (result.added_ips + result.updated_ips).group_by(&.node_name).transform_values(&.size)
      node_counts.values.each do |count|
        count.should be <= 1
      end
    end

    it "rebalance does not move VIPs to a node at capacity" do
      # Mask 0x030000 → capacity 3
      config = ControllerFixtures.vip_config(firewall_mark_mask: 0x030000_u32)

      # 2 nodes: node-1 has 1 endpoint, node-2 has 3 endpoints
      # 4 VIPs, cap 3 → node-2 should get at most 3
      allocator = Netwrangler::Controller::IpAllocator.new(
        services: [ControllerFixtures.service(external_ips: ["10.0.1.11", "10.0.1.12", "10.0.1.13", "10.0.1.14"])],
        endpoint_slices: [
          ControllerFixtures.endpoint_slice(name: "ep-1", nodes: ["node-1"]),
          ControllerFixtures.endpoint_slice(name: "ep-2", nodes: ["node-2", "node-2", "node-2"]),
        ],
        vip_networks: [ControllerFixtures.vip_network],
        vip_addresses: [] of Netwrangler::Model::VipAddress,
        vip_configs: [config],
      )

      result = allocator.allocate
      result.added_ips.size.should eq(4)

      node_counts = result.added_ips.group_by(&.node_name).transform_values(&.size)
      node_counts.each_value do |count|
        count.should be <= 3
      end
    end
  end

  describe ".fwmark_capacity" do
    it "returns 255 for 8-bit mask 0xFF0000" do
      Netwrangler::Controller::IpAllocator.fwmark_capacity(0xFF0000_u32).should eq(255)
    end

    it "returns 65535 for 16-bit mask 0xFFFF0000" do
      Netwrangler::Controller::IpAllocator.fwmark_capacity(0xFFFF0000_u32).should eq(65535)
    end

    it "returns 3 for 2-bit mask 0x030000" do
      Netwrangler::Controller::IpAllocator.fwmark_capacity(0x030000_u32).should eq(3)
    end

    it "returns 1 for single-bit mask" do
      Netwrangler::Controller::IpAllocator.fwmark_capacity(0x010000_u32).should eq(1)
    end

    it "returns 0 for zero mask" do
      Netwrangler::Controller::IpAllocator.fwmark_capacity(0_u32).should eq(0)
    end

    it "returns Int32::MAX for full 32-bit mask" do
      Netwrangler::Controller::IpAllocator.fwmark_capacity(0xFFFFFFFF_u32).should eq(Int32::MAX)
    end

    it "returns Int32::MAX for 31-bit mask" do
      Netwrangler::Controller::IpAllocator.fwmark_capacity(0x7FFFFFFF_u32).should eq(Int32::MAX)
    end
  end
end
