require "../spec_helper"

module BindingContextSpecHelper
  def self.valid_vip_address_filter_result_json(
    name = "my-vip",
    namespace = "default",
    network = "test-network",
    virtual_cidr = "10.0.1.10/24",
    interface = "eth0",
    gateway_ip = "10.0.1.1",
    firewall_mark : Int32? = nil,
    route_table : Int32? = nil,
    routing_priority : Int32? = nil,
    egress_enabled : String? = nil,
    endpoint_ips = ["10.244.1.1", "10.244.1.2"],
    ports = [{port: 80, protocol: "TCP"}],
  )
    hash = {
      name:             name,
      namespace:        namespace,
      network:          network,
      virtual_cidr:     virtual_cidr,
      interface:        interface,
      gateway_ip:       gateway_ip,
      firewall_mark:    firewall_mark,
      route_table:      route_table,
      routing_priority: routing_priority,
      egress_enabled:   egress_enabled,
      endpoint_ips:     endpoint_ips,
      ports:            ports,
    }
    hash.to_json
  end

  def self.valid_vip_config_filter_result_json(
    name = "default",
    firewall_mark = 0x010000,
    firewall_mark_mask = 0xFF0000,
    route_table = 100,
    routing_priority = 100,
    max_address_count = 254,
    cluster_cidrs = [] of String,
  )
    hash = {
      name:               name,
      firewall_mark:      firewall_mark,
      firewall_mark_mask: firewall_mark_mask,
      route_table:        route_table,
      routing_priority:   routing_priority,
      max_address_count:  max_address_count,
      cluster_cidrs:      cluster_cidrs,
    }
    hash.to_json
  end

  def self.valid_vip_config_snapshot_json(
    name = "default",
    firewall_mark = 0x010000,
    firewall_mark_mask = 0xFF0000,
    route_table = 100,
    routing_priority = 100,
    max_address_count = 254,
    cluster_cidrs = [] of String,
  )
    {
      filterResult: {
        name:               name,
        firewall_mark:      firewall_mark,
        firewall_mark_mask: firewall_mark_mask,
        route_table:        route_table,
        routing_priority:   routing_priority,
        max_address_count:  max_address_count,
        cluster_cidrs:      cluster_cidrs,
      },
    }.to_json
  end

  def self.valid_vip_address_snapshot_json(
    name = "my-vip",
    namespace = "default",
    network = "test-network",
    virtual_cidr = "10.0.1.10/24",
    interface = "eth0",
    gateway_ip = "10.0.1.1",
    firewall_mark : Int32? = nil,
    route_table : Int32? = nil,
    routing_priority : Int32? = nil,
    endpoint_ips = ["10.244.1.1"],
    ports = [{port: 80, protocol: "TCP"}],
  )
    {
      filterResult: {
        name:             name,
        namespace:        namespace,
        network:          network,
        virtual_cidr:     virtual_cidr,
        interface:        interface,
        gateway_ip:       gateway_ip,
        firewall_mark:    firewall_mark,
        route_table:      route_table,
        routing_priority: routing_priority,
        endpoint_ips:     endpoint_ips,
        ports:            ports,
      },
    }.to_json
  end

  def self.valid_vip_route_filter_result_json(
    name = "my-route",
    namespace = "default",
    destination_cidr = "192.168.0.0/24",
    gateway_node = "node-1",
    pod_ip = "10.244.1.1",
    route_table = 200,
    routing_priority = 20000,
  )
    hash = Hash(String, String | Int32).new
    hash["name"] = name
    hash["namespace"] = namespace
    hash["destination_cidr"] = destination_cidr
    hash["gateway_node"] = gateway_node
    hash["pod_ip"] = pod_ip
    hash["route_table"] = route_table
    hash["routing_priority"] = routing_priority
    hash.to_json
  end

  def self.valid_vip_route_snapshot_json(
    name = "my-route",
    namespace = "default",
    destination_cidr = "192.168.0.0/24",
    gateway_node = "node-1",
    pod_ip = "10.244.1.1",
    route_table = 200,
    routing_priority = 20000,
  )
    filter = Hash(String, String | Int32).new
    filter["name"] = name
    filter["namespace"] = namespace
    filter["destination_cidr"] = destination_cidr
    filter["gateway_node"] = gateway_node
    filter["pod_ip"] = pod_ip
    filter["route_table"] = route_table
    filter["routing_priority"] = routing_priority
    {filterResult: filter}.to_json
  end

  def self.valid_binding_context_json(binding_name = "vip_addresses")
    {
      binding:   binding_name,
      snapshots: {
        "vip_addresses" => [
          {
            "filterResult" => {
              "name"         => "test-vip",
              "namespace"    => "default",
              "network"      => "test-network",
              "virtual_cidr" => "10.0.1.10/24",
              "interface"    => "eth0",
              "gateway_ip"   => "10.0.1.1",
              "endpoint_ips" => ["10.244.1.1"],
              "ports"        => [{"port" => 80, "protocol" => "TCP"}],
            },
          },
        ],
      },
    }.to_json
  end

  def self.multi_snapshot_binding_context_json
    {
      binding:   "vip_addresses",
      snapshots: {
        "vip_addresses" => [
          {
            "filterResult" => {
              "name"         => "vip-1",
              "namespace"    => "ns1",
              "network"      => "test-network",
              "virtual_cidr" => "10.0.1.10/24",
              "interface"    => "eth0",
              "gateway_ip"   => "10.0.1.1",
              "endpoint_ips" => ["10.244.1.1"],
              "ports"        => [{"port" => 80, "protocol" => "TCP"}],
            },
          },
          {
            "filterResult" => {
              "name"         => "vip-2",
              "namespace"    => "ns2",
              "network"      => "test-network",
              "virtual_cidr" => "10.0.2.10/24",
              "interface"    => "eth1",
              "gateway_ip"   => "10.0.2.1",
              "endpoint_ips" => ["10.244.2.1", "10.244.2.2"],
              "ports"        => [{"port" => 443, "protocol" => "TCP"}],
            },
          },
        ],
      },
    }.to_json
  end
end

describe Netwrangler::Util::VipAddressFilterResult do
  describe "JSON deserialization" do
    it "deserializes valid JSON" do
      json = BindingContextSpecHelper.valid_vip_address_filter_result_json
      result = Netwrangler::Util::VipAddressFilterResult.from_json(json)

      result.name.should eq("my-vip")
      result.namespace.should eq("default")
      result.network.should eq("test-network")
      result.virtual_cidr.should eq("10.0.1.10/24")
      result.interface.should eq("eth0")
      result.gateway_ip.should eq("10.0.1.1")
      result.endpoint_ips.should eq(["10.244.1.1", "10.244.1.2"])
      result.ports.size.should eq(1)
      result.ports.first.port.should eq(80)
      result.ports.first.protocol.should eq("TCP")
    end

    it "handles nil optional fields" do
      json = {
        name:         "my-vip",
        namespace:    "default",
        network:      "test-network",
        virtual_cidr: "10.0.1.10/24",
        interface:    "eth0",
        gateway_ip:   nil,
        endpoint_ips: [] of String,
      }.to_json
      result = Netwrangler::Util::VipAddressFilterResult.from_json(json)

      result.gateway_ip.should be_nil
      result.endpoint_ips.should be_empty
    end
  end

  describe "validation" do
    it "raises ArgumentError for invalid virtual IP" do
      json = BindingContextSpecHelper.valid_vip_address_filter_result_json(virtual_cidr: "not-an-ip")

      expect_raises(ArgumentError, /invalid virtual IP/) do
        Netwrangler::Util::VipAddressFilterResult.from_json(json)
      end
    end

    it "raises ArgumentError for invalid gateway IP" do
      json = BindingContextSpecHelper.valid_vip_address_filter_result_json(gateway_ip: "not-an-ip")

      expect_raises(ArgumentError, /invalid gateway IP/) do
        Netwrangler::Util::VipAddressFilterResult.from_json(json)
      end
    end

    it "raises ArgumentError for invalid endpoint IP" do
      json = BindingContextSpecHelper.valid_vip_address_filter_result_json(endpoint_ips: ["10.244.1.1", "invalid", "10.244.1.2"])

      expect_raises(ArgumentError, /invalid endpoint IP/) do
        Netwrangler::Util::VipAddressFilterResult.from_json(json)
      end
    end

    it "allows nil gateway IP" do
      json = {
        name:         "my-vip",
        namespace:    "default",
        network:      "test-network",
        virtual_cidr: "10.0.1.10/24",
        interface:    "eth0",
        gateway_ip:   nil,
        endpoint_ips: [] of String,
      }.to_json

      result = Netwrangler::Util::VipAddressFilterResult.from_json(json)
      result.gateway_ip.should be_nil
    end

    it "includes namespace and name in error messages" do
      json = BindingContextSpecHelper.valid_vip_address_filter_result_json(
        name: "my-ip",
        namespace: "my-namespace",
        endpoint_ips: ["invalid"]
      )

      begin
        Netwrangler::Util::VipAddressFilterResult.from_json(json)
        fail "Expected ArgumentError to be raised"
      rescue ex : ArgumentError
        message = ex.message
        fail "Expected error message" unless message
        message.should contain("my-namespace/my-ip")
      end
    end
  end
end

describe Netwrangler::Util::VipAddressSnapshot do
  describe "JSON deserialization" do
    it "deserializes valid JSON" do
      json = BindingContextSpecHelper.valid_vip_address_snapshot_json
      snapshot = Netwrangler::Util::VipAddressSnapshot.from_json(json)

      snapshot.filter_result.should be_a(Netwrangler::Util::VipAddressFilterResult)
    end
  end

  describe "delegation" do
    it "delegates name to filter_result" do
      snapshot = Netwrangler::Util::VipAddressSnapshot.from_json(BindingContextSpecHelper.valid_vip_address_snapshot_json(name: "test-ip"))
      snapshot.name.should eq("test-ip")
    end

    it "delegates virtual_cidr to filter_result" do
      snapshot = Netwrangler::Util::VipAddressSnapshot.from_json(BindingContextSpecHelper.valid_vip_address_snapshot_json(virtual_cidr: "10.1.1.1/24"))
      snapshot.virtual_cidr.should eq("10.1.1.1/24")
    end

    it "delegates interface to filter_result" do
      snapshot = Netwrangler::Util::VipAddressSnapshot.from_json(BindingContextSpecHelper.valid_vip_address_snapshot_json(interface: "bond0"))
      snapshot.interface.should eq("bond0")
    end

    it "delegates gateway_ip to filter_result" do
      snapshot = Netwrangler::Util::VipAddressSnapshot.from_json(BindingContextSpecHelper.valid_vip_address_snapshot_json(gateway_ip: "172.16.0.1"))
      snapshot.gateway_ip.should eq("172.16.0.1")
    end

    it "delegates network to filter_result" do
      snapshot = Netwrangler::Util::VipAddressSnapshot.from_json(BindingContextSpecHelper.valid_vip_address_snapshot_json(network: "my-network"))
      snapshot.network.should eq("my-network")
    end

    it "delegates endpoint_ips to filter_result" do
      endpoint_ips = ["10.244.1.1", "10.244.1.2", "10.244.1.3"]
      snapshot = Netwrangler::Util::VipAddressSnapshot.from_json(BindingContextSpecHelper.valid_vip_address_snapshot_json(endpoint_ips: endpoint_ips))
      snapshot.endpoint_ips.should eq(endpoint_ips)
    end

    it "delegates ports to filter_result" do
      ports = [{port: 80, protocol: "TCP"}, {port: 443, protocol: "TCP"}]
      snapshot = Netwrangler::Util::VipAddressSnapshot.from_json(BindingContextSpecHelper.valid_vip_address_snapshot_json(ports: ports))
      snapshot.ports.size.should eq(2)
      snapshot.ports.first.port.should eq(80)
      snapshot.ports.last.port.should eq(443)
    end

    it "delegates route_table to filter_result" do
      snapshot = Netwrangler::Util::VipAddressSnapshot.from_json(BindingContextSpecHelper.valid_vip_address_snapshot_json(route_table: 200))
      snapshot.route_table.should eq(200)
    end

    it "delegates route_table nil to filter_result" do
      snapshot = Netwrangler::Util::VipAddressSnapshot.from_json(BindingContextSpecHelper.valid_vip_address_snapshot_json)
      snapshot.route_table.should be_nil
    end

    it "delegates routing_priority to filter_result" do
      snapshot = Netwrangler::Util::VipAddressSnapshot.from_json(BindingContextSpecHelper.valid_vip_address_snapshot_json(routing_priority: 300))
      snapshot.routing_priority.should eq(300)
    end

    it "delegates routing_priority nil to filter_result" do
      snapshot = Netwrangler::Util::VipAddressSnapshot.from_json(BindingContextSpecHelper.valid_vip_address_snapshot_json)
      snapshot.routing_priority.should be_nil
    end

    it "delegates firewall_mark to filter_result" do
      snapshot = Netwrangler::Util::VipAddressSnapshot.from_json(BindingContextSpecHelper.valid_vip_address_snapshot_json(firewall_mark: 0x010000))
      snapshot.firewall_mark.should eq(0x010000)
    end

    it "delegates firewall_mark nil to filter_result" do
      snapshot = Netwrangler::Util::VipAddressSnapshot.from_json(BindingContextSpecHelper.valid_vip_address_snapshot_json)
      snapshot.firewall_mark.should be_nil
    end
  end
end

describe Netwrangler::Util::VipAddressConfigFilterResult do
  describe "JSON deserialization" do
    it "deserializes valid JSON" do
      json = BindingContextSpecHelper.valid_vip_config_filter_result_json
      result = Netwrangler::Util::VipAddressConfigFilterResult.from_json(json)

      result.name.should eq("default")
      result.firewall_mark.should eq(0x010000)
      result.firewall_mark_mask.should eq(0xFF0000_u32)
      result.route_table.should eq(100)
      result.routing_priority.should eq(100)
      result.max_address_count.should eq(254)
    end

    it "deserializes with custom values" do
      json = BindingContextSpecHelper.valid_vip_config_filter_result_json(
        name: "custom",
        firewall_mark: 0x020000,
        firewall_mark_mask: 0xFF0000,
        route_table: 200,
        routing_priority: 200,
        max_address_count: 128
      )
      result = Netwrangler::Util::VipAddressConfigFilterResult.from_json(json)

      result.name.should eq("custom")
      result.firewall_mark.should eq(0x020000)
      result.route_table.should eq(200)
      result.routing_priority.should eq(200)
      result.max_address_count.should eq(128)
    end

    it "deserializes cluster_cidrs" do
      json = BindingContextSpecHelper.valid_vip_config_filter_result_json(
        cluster_cidrs: ["10.244.0.0/16", "10.96.0.0/12"]
      )
      result = Netwrangler::Util::VipAddressConfigFilterResult.from_json(json)

      result.cluster_cidrs.should eq(["10.244.0.0/16", "10.96.0.0/12"])
    end

    it "defaults cluster_cidrs to empty" do
      json = {
        name:               "default",
        firewall_mark:      0x010000,
        firewall_mark_mask: 0xFF0000,
        route_table:        100,
        routing_priority:   100,
        max_address_count:  254,
      }.to_json

      result = Netwrangler::Util::VipAddressConfigFilterResult.from_json(json)
      result.cluster_cidrs.should be_empty
    end
  end
end

describe Netwrangler::Util::VipAddressConfigSnapshot do
  describe "JSON deserialization" do
    it "deserializes valid JSON" do
      json = BindingContextSpecHelper.valid_vip_config_snapshot_json
      snapshot = Netwrangler::Util::VipAddressConfigSnapshot.from_json(json)

      snapshot.filter_result.should be_a(Netwrangler::Util::VipAddressConfigFilterResult)
    end
  end

  describe "delegation" do
    it "delegates name to filter_result" do
      snapshot = Netwrangler::Util::VipAddressConfigSnapshot.from_json(BindingContextSpecHelper.valid_vip_config_snapshot_json(name: "test-config"))
      snapshot.name.should eq("test-config")
    end

    it "delegates firewall_mark to filter_result" do
      snapshot = Netwrangler::Util::VipAddressConfigSnapshot.from_json(BindingContextSpecHelper.valid_vip_config_snapshot_json(firewall_mark: 0x020000))
      snapshot.firewall_mark.should eq(0x020000)
    end

    it "delegates firewall_mark_mask to filter_result" do
      snapshot = Netwrangler::Util::VipAddressConfigSnapshot.from_json(BindingContextSpecHelper.valid_vip_config_snapshot_json(firewall_mark_mask: 0xFF0000))
      snapshot.firewall_mark_mask.should eq(0xFF0000_u32)
    end

    it "delegates route_table to filter_result" do
      snapshot = Netwrangler::Util::VipAddressConfigSnapshot.from_json(BindingContextSpecHelper.valid_vip_config_snapshot_json(route_table: 200))
      snapshot.route_table.should eq(200)
    end

    it "delegates routing_priority to filter_result" do
      snapshot = Netwrangler::Util::VipAddressConfigSnapshot.from_json(BindingContextSpecHelper.valid_vip_config_snapshot_json(routing_priority: 300))
      snapshot.routing_priority.should eq(300)
    end

    it "delegates max_address_count to filter_result" do
      snapshot = Netwrangler::Util::VipAddressConfigSnapshot.from_json(BindingContextSpecHelper.valid_vip_config_snapshot_json(max_address_count: 128))
      snapshot.max_address_count.should eq(128)
    end

    it "delegates cluster_cidrs to filter_result" do
      snapshot = Netwrangler::Util::VipAddressConfigSnapshot.from_json(
        BindingContextSpecHelper.valid_vip_config_snapshot_json(
          cluster_cidrs: ["10.244.0.0/16"]
        )
      )
      snapshot.cluster_cidrs.should eq(["10.244.0.0/16"])
    end
  end
end

describe Netwrangler::Util::BindingContext do
  describe "JSON deserialization" do
    it "deserializes valid JSON" do
      json = BindingContextSpecHelper.valid_binding_context_json
      context = Netwrangler::Util::BindingContext.from_json(json)

      context.binding.should eq("vip_addresses")
      context.snapshots.should be_a(Netwrangler::Util::Snapshots)
    end

    it "deserializes vip_addresses snapshots correctly" do
      json = BindingContextSpecHelper.valid_binding_context_json
      context = Netwrangler::Util::BindingContext.from_json(json)

      context.snapshots.vip_addresses.size.should eq(1)
      context.snapshots.vip_addresses.first.name.should eq("test-vip")
    end

    it "handles multiple snapshots" do
      json = BindingContextSpecHelper.multi_snapshot_binding_context_json
      context = Netwrangler::Util::BindingContext.from_json(json)

      context.snapshots.vip_addresses.size.should eq(2)
    end

    it "handles empty snapshots" do
      json = {
        binding:   "test",
        snapshots: {
          "vip_addresses" => [] of Hash(String, String),
        },
      }.to_json

      context = Netwrangler::Util::BindingContext.from_json(json)
      context.snapshots.vip_addresses.should be_empty
    end

    it "deserializes vip_routes snapshots" do
      json = {
        binding:   "vip_routes",
        snapshots: {
          "vip_routes" => [
            {
              "filterResult" => {
                "name"             => "route-1",
                "namespace"        => "default",
                "destination_cidr" => "192.168.0.0/24",
                "gateway_node"     => "node-1",
                "pod_ip"           => "10.244.1.1",
                "route_table"      => 200,
                "routing_priority" => 20000,
              },
            },
            {
              "filterResult" => {
                "name"             => "route-2",
                "namespace"        => "kube-system",
                "destination_cidr" => "10.10.0.0/16",
                "gateway_node"     => "node-2",
                "pod_ip"           => "10.244.2.1",
                "route_table"      => 201,
                "routing_priority" => 20001,
              },
            },
          ],
        },
      }.to_json

      context = Netwrangler::Util::BindingContext.from_json(json)
      context.snapshots.vip_routes.size.should eq(2)
      context.snapshots.vip_routes[0].name.should eq("route-1")
      context.snapshots.vip_routes[0].namespace.should eq("default")
      context.snapshots.vip_routes[0].destination_cidr.should eq("192.168.0.0/24")
      context.snapshots.vip_routes[0].pod_ip.should eq("10.244.1.1")
      context.snapshots.vip_routes[1].name.should eq("route-2")
      context.snapshots.vip_routes[1].namespace.should eq("kube-system")
      context.snapshots.vip_routes[1].pod_ip.should eq("10.244.2.1")
      context.snapshots.vip_routes[1].routing_priority.should eq(20001)
    end
  end
end

describe Netwrangler::Util::VipRouteFilterResult do
  describe "JSON deserialization" do
    it "deserializes valid JSON with all fields" do
      json = BindingContextSpecHelper.valid_vip_route_filter_result_json
      result = Netwrangler::Util::VipRouteFilterResult.from_json(json)

      result.name.should eq("my-route")
      result.namespace.should eq("default")
      result.destination_cidr.should eq("192.168.0.0/24")
      result.pod_ip.should eq("10.244.1.1")
      result.route_table.should eq(200)
      result.routing_priority.should eq(20000)
    end
  end
end

describe Netwrangler::Util::VipRouteSnapshot do
  describe "delegation" do
    it "delegates name to filter_result" do
      snapshot = Netwrangler::Util::VipRouteSnapshot.from_json(BindingContextSpecHelper.valid_vip_route_snapshot_json(name: "test-route"))
      snapshot.name.should eq("test-route")
    end

    it "delegates namespace to filter_result" do
      snapshot = Netwrangler::Util::VipRouteSnapshot.from_json(BindingContextSpecHelper.valid_vip_route_snapshot_json(namespace: "kube-system"))
      snapshot.namespace.should eq("kube-system")
    end

    it "delegates destination_cidr to filter_result" do
      snapshot = Netwrangler::Util::VipRouteSnapshot.from_json(BindingContextSpecHelper.valid_vip_route_snapshot_json(destination_cidr: "10.0.0.0/8"))
      snapshot.destination_cidr.should eq("10.0.0.0/8")
    end

    it "delegates pod_ip to filter_result" do
      snapshot = Netwrangler::Util::VipRouteSnapshot.from_json(BindingContextSpecHelper.valid_vip_route_snapshot_json(pod_ip: "10.244.2.1"))
      snapshot.pod_ip.should eq("10.244.2.1")
    end

    it "delegates route_table to filter_result" do
      snapshot = Netwrangler::Util::VipRouteSnapshot.from_json(BindingContextSpecHelper.valid_vip_route_snapshot_json(route_table: 300))
      snapshot.route_table.should eq(300)
    end

    it "delegates routing_priority to filter_result" do
      snapshot = Netwrangler::Util::VipRouteSnapshot.from_json(BindingContextSpecHelper.valid_vip_route_snapshot_json(routing_priority: 30000))
      snapshot.routing_priority.should eq(30000)
    end
  end
end

describe Netwrangler::Util::VipNetworkFilterResult do
  describe "JSON deserialization" do
    it "deserializes all fields" do
      json = {
        name:         "test-net",
        interface:    "eth0",
        gateway_ip:   "10.0.1.1",
        network_cidr: "10.0.1.0/24",
        source_cidrs: ["10.0.0.0/8"],
      }.to_json

      result = Netwrangler::Util::VipNetworkFilterResult.from_json(json)
      result.name.should eq("test-net")
      result.interface.should eq("eth0")
      result.network_cidr.should eq("10.0.1.0/24")
      result.source_cidrs.should eq(["10.0.0.0/8"])
    end
  end
end

describe Netwrangler::Util::VipGatewaySnapshot do
  it "parses the VipGateway filter result" do
    json = %({"filterResult": {"name": "vpn", "destination_cidr": "10.0.0.0/8", "route_table": 200, "routing_priority": 150}})
    snapshot = Netwrangler::Util::VipGatewaySnapshot.from_json(json)

    snapshot.name.should eq("vpn")
    snapshot.destination_cidr.should eq("10.0.0.0/8")
    snapshot.route_table.should eq(200)
    snapshot.routing_priority.should eq(150)
  end

  it "keeps an invalid destination as a string instead of raising" do
    json = %({"filterResult": {"name": "bad", "destination_cidr": "not-a-cidr", "route_table": 200, "routing_priority": 150}})
    Netwrangler::Util::VipGatewaySnapshot.from_json(json).destination_cidr.should eq("not-a-cidr")
  end
end

describe Netwrangler::Util::Snapshots do
  it "reads vip_gateways" do
    json = %({"vip_gateways": [{"filterResult": {"name": "vpn", "destination_cidr": "10.0.0.0/8", "route_table": 200, "routing_priority": 150}}]})
    Netwrangler::Util::Snapshots.from_json(json).vip_gateways.map(&.name).should eq(["vpn"])
  end

  it "defaults vip_gateways to empty" do
    Netwrangler::Util::Snapshots.from_json("{}").vip_gateways.should be_empty
  end
end
