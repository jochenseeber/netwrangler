require "../spec_helper"

module GatewayPolicySpecHelper
  def self.snapshot(name : String, destination : String, route_table = 200, routing_priority = 150) : Netwrangler::Util::VipGatewaySnapshot
    Netwrangler::Util::VipGatewaySnapshot.from_json(
      {filterResult: {name: name, destination_cidr: destination, route_table: route_table, routing_priority: routing_priority}}.to_json)
  end

  def self.net(cidr : String) : Netwrangler::Util::IPv4Network
    Netwrangler::Util::IPv4Network.parse(cidr)
  end

  def self.addr(ip : String) : Netwrangler::Util::IPv4Address
    Netwrangler::Util::IPv4Address.parse(ip)
  end

  def self.gateway(name : String, destination : String) : Netwrangler::Agent::GatewayRuleEntry
    Netwrangler::Agent::GatewayRuleEntry.new(name: name, destination_cidr: net(destination), route_table: 200, routing_priority: 150)
  end

  def self.select(snapshots : Array(Netwrangler::Util::VipGatewaySnapshot), *,
                  cluster_cidrs = [] of String,
                  node_networks = [] of Netwrangler::Util::IPv4Network,
                  vip_route_tables = Set(Int32).new) : Netwrangler::Agent::GatewayPolicy::Selection
    Netwrangler::Agent::GatewayPolicy.select_gateways(snapshots, cluster_cidrs: cluster_cidrs,
      node_networks: node_networks, vip_route_tables: vip_route_tables)
  end

  def self.route(destination : String, *, route_table : Int32) : Netwrangler::Agent::VipRouteEntry
    Netwrangler::Agent::VipRouteEntry.new(destination_cidr: net(destination), gateway_node: "worker",
      pod_ip: addr("10.244.1.5"), route_table: route_table, routing_priority: 150)
  end
end

describe Netwrangler::Agent::GatewayPolicy do
  describe ".select_gateways" do
    it "applies a safe gateway with its canonical destination" do
      selection = GatewayPolicySpecHelper.select(
        [GatewayPolicySpecHelper.snapshot("vpn", "198.51.100.7/24", route_table: 10600, routing_priority: 10650)],
        cluster_cidrs: ["10.244.0.0/16"],
        node_networks: [GatewayPolicySpecHelper.net("127.0.0.1/8"), GatewayPolicySpecHelper.net("172.18.0.2/16")],
        vip_route_tables: Set{20002})

      selection.errors.should be_empty
      selection.applied.should eq([
        Netwrangler::Agent::GatewayRuleEntry.new(name: "vpn", destination_cidr: GatewayPolicySpecHelper.net("198.51.100.0/24"),
          route_table: 10600, routing_priority: 10650),
      ])
      selection.applied.first.destination_cidr.to_s.should eq("198.51.100.0/24")
    end

    it "refuses a gateway that overlaps a cluster network and applies the others" do
      selection = GatewayPolicySpecHelper.select(
        [GatewayPolicySpecHelper.snapshot("wide", "10.0.0.0/8"), GatewayPolicySpecHelper.snapshot("vpn", "198.51.100.0/24")],
        cluster_cidrs: ["10.244.0.0/16"])

      selection.applied.map(&.name).should eq(["vpn"])
      selection.errors.should eq(["Refusing VipGateway wide: destinationCIDR 10.0.0.0/8 overlaps cluster network 10.244.0.0/16"])
    end

    it "refuses a gateway equal to a node network" do
      selection = GatewayPolicySpecHelper.select(
        [GatewayPolicySpecHelper.snapshot("kind", "172.18.0.0/16")],
        node_networks: [GatewayPolicySpecHelper.net("127.0.0.1/8"), GatewayPolicySpecHelper.net("172.18.0.2/16")])

      selection.applied.should be_empty
      selection.errors.should eq(["Refusing VipGateway kind: destinationCIDR 172.18.0.0/16 overlaps network 172.18.0.0/16 of node address 172.18.0.2"])
    end

    it "refuses a gateway inside a node network that misses the node's own address" do
      selection = GatewayPolicySpecHelper.select(
        [GatewayPolicySpecHelper.snapshot("router", "172.18.5.0/24")],
        node_networks: [GatewayPolicySpecHelper.net("172.18.0.2/16")])

      selection.applied.should be_empty
      selection.errors.should eq(["Refusing VipGateway router: destinationCIDR 172.18.5.0/24 overlaps network 172.18.0.0/16 of node address 172.18.0.2"])
    end

    it "refuses 0.0.0.0/0 because it overlaps every node network" do
      selection = GatewayPolicySpecHelper.select(
        [GatewayPolicySpecHelper.snapshot("all", "0.0.0.0/0")],
        node_networks: [GatewayPolicySpecHelper.net("127.0.0.1/8")])

      selection.applied.should be_empty
      selection.errors.should eq(["Refusing VipGateway all: destinationCIDR 0.0.0.0/0 overlaps network 127.0.0.0/8 of node address 127.0.0.1"])
    end

    it "refuses a gateway whose destination does not parse" do
      selection = GatewayPolicySpecHelper.select([GatewayPolicySpecHelper.snapshot("bad", "not-a-cidr")])

      selection.applied.should be_empty
      selection.errors.should eq(["Refusing VipGateway bad: invalid destinationCIDR 'not-a-cidr'"])
    end

    it "refuses the reserved route tables" do
      snapshots = [0, 253, 254, 255].map do |table|
        GatewayPolicySpecHelper.snapshot("table-#{table}", "198.51.100.0/24", route_table: table)
      end
      selection = GatewayPolicySpecHelper.select(snapshots)

      selection.applied.should be_empty
      selection.errors.should eq([
        "Refusing VipGateway table-0: routeTable 0 is reserved",
        "Refusing VipGateway table-253: routeTable 253 is reserved",
        "Refusing VipGateway table-254: routeTable 254 is reserved",
        "Refusing VipGateway table-255: routeTable 255 is reserved",
      ])
    end

    it "refuses a route table that a VipAddress on this node uses" do
      selection = GatewayPolicySpecHelper.select(
        [GatewayPolicySpecHelper.snapshot("vip", "198.51.100.0/24", route_table: 20002)],
        vip_route_tables: Set{20002, 20003})

      selection.applied.should be_empty
      selection.errors.should eq(["Refusing VipGateway vip: routeTable 20002 is used by a VipAddress on this node"])
    end

    it "refuses a priority that does not come before the main table rule" do
      selection = GatewayPolicySpecHelper.select([
        GatewayPolicySpecHelper.snapshot("late", "198.51.100.0/24", routing_priority: 32766),
        GatewayPolicySpecHelper.snapshot("early", "192.0.2.0/24", routing_priority: 32765),
      ])

      selection.applied.map(&.name).should eq(["early"])
      selection.errors.should eq(["Refusing VipGateway late: routingPriority 32766 does not come before the main table rule at 32766"])
    end

    it "refuses every gateway that shares its destination and table with another" do
      selection = GatewayPolicySpecHelper.select([
        GatewayPolicySpecHelper.snapshot("a", "198.51.100.7/24", route_table: 200),
        GatewayPolicySpecHelper.snapshot("b", "198.51.100.0/24", route_table: 200),
        GatewayPolicySpecHelper.snapshot("c", "198.51.100.0/24", route_table: 201),
      ])

      selection.applied.map(&.name).should eq(["c"])
      selection.errors.should eq([
        "Refusing VipGateway a: destinationCIDR 198.51.100.0/24 and routeTable 200 are also used by VipGateway b",
        "Refusing VipGateway b: destinationCIDR 198.51.100.0/24 and routeTable 200 are also used by VipGateway a",
      ])
    end

    it "does not count a gateway refused for another reason as a duplicate" do
      selection = GatewayPolicySpecHelper.select([
        GatewayPolicySpecHelper.snapshot("late", "198.51.100.0/24", routing_priority: 32766),
        GatewayPolicySpecHelper.snapshot("vpn", "198.51.100.0/24"),
      ])

      selection.applied.map(&.name).should eq(["vpn"])
      selection.errors.size.should eq(1)
    end
  end

  describe ".overlapping_gateways" do
    it "pairs each source network with every gateway it overlaps" do
      vpn = GatewayPolicySpecHelper.gateway("vpn", "10.0.0.0/8")
      lab = GatewayPolicySpecHelper.gateway("lab", "192.0.2.0/24")
      sources = [GatewayPolicySpecHelper.net("10.20.0.0/16"), GatewayPolicySpecHelper.net("203.0.113.0/24")]

      Netwrangler::Agent::GatewayPolicy.overlapping_gateways(sources, [vpn, lab])
        .should eq([{GatewayPolicySpecHelper.net("10.20.0.0/16"), vpn}])
    end
  end

  describe ".applied_routes" do
    it "keeps only the VipRoutes of applied gateways" do
      vpn = GatewayPolicySpecHelper.gateway("vpn", "198.51.100.0/24")
      applied = GatewayPolicySpecHelper.route("198.51.100.0/24", route_table: 200)
      refused = GatewayPolicySpecHelper.route("172.18.0.0/16", route_table: 201)
      other_table = GatewayPolicySpecHelper.route("198.51.100.0/24", route_table: 201)

      Netwrangler::Agent::GatewayPolicy.applied_routes([applied, refused, other_table], [vpn]).should eq([applied])
    end
  end

  describe ".local_gateways" do
    local = Netwrangler::Agent::RoutesUpdater::ResolvedPodRoute.new(gateway: "10.99.0.10", dev: "lo", prefsrc: "10.99.0.10", local: true)
    remote = Netwrangler::Agent::RoutesUpdater::ResolvedPodRoute.new(gateway: "172.18.0.3", dev: "eth0", prefsrc: "172.18.0.2")

    it "returns a gateway whose pod has an address of this node" do
      vpn = GatewayPolicySpecHelper.gateway("vpn", "198.51.100.0/24")
      route = GatewayPolicySpecHelper.route("198.51.100.0/24", route_table: 200)

      Netwrangler::Agent::GatewayPolicy.local_gateways([vpn], [{route, local}]).should eq([vpn])
    end

    it "leaves out a gateway whose pod is elsewhere or unresolved" do
      vpn = GatewayPolicySpecHelper.gateway("vpn", "198.51.100.0/24")
      route = GatewayPolicySpecHelper.route("198.51.100.0/24", route_table: 200)

      Netwrangler::Agent::GatewayPolicy.local_gateways([vpn], [{route, remote}]).should be_empty
      Netwrangler::Agent::GatewayPolicy.local_gateways([vpn], [{route, nil}]).should be_empty
    end

    it "matches a pod to its gateway by destination and table" do
      vpn = GatewayPolicySpecHelper.gateway("vpn", "198.51.100.0/24")
      other_table = GatewayPolicySpecHelper.route("198.51.100.0/24", route_table: 201)

      Netwrangler::Agent::GatewayPolicy.local_gateways([vpn], [{other_table, local}]).should be_empty
    end
  end

  describe ".parse_node_networks" do
    it "returns the IPv4 addresses of every link with their prefix" do
      json = <<-JSON
        [
          {"ifname": "lo", "addr_info": [{"family": "inet", "local": "127.0.0.1", "prefixlen": 8},
                                          {"family": "inet6", "local": "::1", "prefixlen": 128}]},
          {"ifname": "eth0", "addr_info": [{"family": "inet", "local": "172.18.0.2", "prefixlen": 16}]},
          {"ifname": "dummy0"},
          {"ifname": "dummy1", "addr_info": [{"family": "inet", "local": "192.0.2.9"}]}
        ]
        JSON

      Netwrangler::Agent::GatewayPolicy.parse_node_networks(json).map(&.to_s)
        .should eq(["127.0.0.1/8", "172.18.0.2/16", "192.0.2.9/32"])
    end

    it "raises with the address when a node address does not parse, so no gateway goes unchecked" do
      json = %([{"ifname": "eth0", "addr_info": [{"family": "inet", "local": "172.18.0.300", "prefixlen": 16}]}])

      expect_raises(ArgumentError, /node address '172\.18\.0\.300' from ip addr show is invalid/) do
        Netwrangler::Agent::GatewayPolicy.parse_node_networks(json)
      end
    end
  end

  describe "invalid clusterCIDRs" do
    it "raises with the entry, so no gateway goes unchecked" do
      expect_raises(ArgumentError, /VipConfig clusterCIDRs entry '10\.244\.0\.0' is invalid/) do
        GatewayPolicySpecHelper.select([GatewayPolicySpecHelper.snapshot("vpn", "198.51.100.0/24")],
          cluster_cidrs: ["10.244.0.0"])
      end
    end
  end
end
