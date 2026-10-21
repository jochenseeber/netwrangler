require "../spec_helper"

describe Netwrangler::Agent::VipRouteEntry do
  describe "#initialize" do
    it "stores all fields" do
      entry = Netwrangler::Agent::VipRouteEntry.new(
        destination_cidr: Netwrangler::Util::IPv4Network.parse("192.168.0.0/24"),
        gateway_node: "node-1",
        pod_ip: Netwrangler::Util::IPv4Address.parse("10.244.1.1"),
        route_table: 200,
        routing_priority: 20000
      )

      entry.destination_cidr.should eq(Netwrangler::Util::IPv4Network.parse("192.168.0.0/24"))
      entry.pod_ip.should eq(Netwrangler::Util::IPv4Address.parse("10.244.1.1"))
      entry.route_table.should eq(200)
      entry.routing_priority.should eq(20000)
    end
  end

  describe "equality" do
    it "compares VipRouteEntry records by value" do
      entry1 = Netwrangler::Agent::VipRouteEntry.new(
        destination_cidr: Netwrangler::Util::IPv4Network.parse("192.168.0.0/24"),
        gateway_node: "node-1",
        pod_ip: Netwrangler::Util::IPv4Address.parse("10.244.1.1"),
        route_table: 200,
        routing_priority: 20000
      )

      entry2 = Netwrangler::Agent::VipRouteEntry.new(
        destination_cidr: Netwrangler::Util::IPv4Network.parse("192.168.0.0/24"),
        gateway_node: "node-1",
        pod_ip: Netwrangler::Util::IPv4Address.parse("10.244.1.1"),
        route_table: 200,
        routing_priority: 20000
      )

      entry1.should eq(entry2)
    end

    it "distinguishes different destination_cidr" do
      entry1 = Netwrangler::Agent::VipRouteEntry.new(
        destination_cidr: Netwrangler::Util::IPv4Network.parse("192.168.0.0/24"),
        gateway_node: "node-1",
        pod_ip: Netwrangler::Util::IPv4Address.parse("10.244.1.1"),
        route_table: 200,
        routing_priority: 20000
      )

      entry2 = Netwrangler::Agent::VipRouteEntry.new(
        destination_cidr: Netwrangler::Util::IPv4Network.parse("10.10.0.0/16"),
        gateway_node: "node-1",
        pod_ip: Netwrangler::Util::IPv4Address.parse("10.244.1.1"),
        route_table: 200,
        routing_priority: 20000
      )

      entry1.should_not eq(entry2)
    end

    it "distinguishes different pod_ip" do
      entry1 = Netwrangler::Agent::VipRouteEntry.new(
        destination_cidr: Netwrangler::Util::IPv4Network.parse("192.168.0.0/24"),
        gateway_node: "node-1",
        pod_ip: Netwrangler::Util::IPv4Address.parse("10.244.1.1"),
        route_table: 200,
        routing_priority: 20000
      )

      entry2 = Netwrangler::Agent::VipRouteEntry.new(
        destination_cidr: Netwrangler::Util::IPv4Network.parse("192.168.0.0/24"),
        gateway_node: "node-1",
        pod_ip: Netwrangler::Util::IPv4Address.parse("10.244.1.2"),
        route_table: 200,
        routing_priority: 20000
      )

      entry1.should_not eq(entry2)
    end

    it "distinguishes different route_table" do
      entry1 = Netwrangler::Agent::VipRouteEntry.new(
        destination_cidr: Netwrangler::Util::IPv4Network.parse("192.168.0.0/24"),
        gateway_node: "node-1",
        pod_ip: Netwrangler::Util::IPv4Address.parse("10.244.1.1"),
        route_table: 200,
        routing_priority: 20000
      )

      entry2 = Netwrangler::Agent::VipRouteEntry.new(
        destination_cidr: Netwrangler::Util::IPv4Network.parse("192.168.0.0/24"),
        gateway_node: "node-1",
        pod_ip: Netwrangler::Util::IPv4Address.parse("10.244.1.1"),
        route_table: 201,
        routing_priority: 20000
      )

      entry1.should_not eq(entry2)
    end

    it "distinguishes different routing_priority" do
      entry1 = Netwrangler::Agent::VipRouteEntry.new(
        destination_cidr: Netwrangler::Util::IPv4Network.parse("192.168.0.0/24"),
        gateway_node: "node-1",
        pod_ip: Netwrangler::Util::IPv4Address.parse("10.244.1.1"),
        route_table: 200,
        routing_priority: 20000
      )

      entry2 = Netwrangler::Agent::VipRouteEntry.new(
        destination_cidr: Netwrangler::Util::IPv4Network.parse("192.168.0.0/24"),
        gateway_node: "node-1",
        pod_ip: Netwrangler::Util::IPv4Address.parse("10.244.1.1"),
        route_table: 200,
        routing_priority: 20001
      )

      entry1.should_not eq(entry2)
    end
  end

  describe "hash" do
    it "produces consistent hash for equal records" do
      entry1 = Netwrangler::Agent::VipRouteEntry.new(
        destination_cidr: Netwrangler::Util::IPv4Network.parse("192.168.0.0/24"),
        gateway_node: "node-1",
        pod_ip: Netwrangler::Util::IPv4Address.parse("10.244.1.1"),
        route_table: 200,
        routing_priority: 20000
      )

      entry2 = Netwrangler::Agent::VipRouteEntry.new(
        destination_cidr: Netwrangler::Util::IPv4Network.parse("192.168.0.0/24"),
        gateway_node: "node-1",
        pod_ip: Netwrangler::Util::IPv4Address.parse("10.244.1.1"),
        route_table: 200,
        routing_priority: 20000
      )

      entry1.hash.should eq(entry2.hash)
    end

    it "can be used as hash key" do
      entry = Netwrangler::Agent::VipRouteEntry.new(
        destination_cidr: Netwrangler::Util::IPv4Network.parse("192.168.0.0/24"),
        gateway_node: "node-1",
        pod_ip: Netwrangler::Util::IPv4Address.parse("10.244.1.1"),
        route_table: 200,
        routing_priority: 20000
      )

      hash = {entry => "test"}
      hash[entry].should eq("test")
    end
  end
end

describe Netwrangler::Agent::RouteTableInfo do
  describe "#initialize" do
    it "stores all fields" do
      info = Netwrangler::Agent::RouteTableInfo.new(
        route_table: 10001,
        virtual_ip: Netwrangler::Util::IPv4Address.parse("10.0.1.10"),
        gateway_ip: Netwrangler::Util::IPv4Address.parse("10.0.1.1"),
        network_cidr: Netwrangler::Util::IPv4Network.parse("10.0.1.0/24"),
        source_cidrs: [Netwrangler::Util::IPv4Network.parse("172.16.0.0/12")],
        firewall_mark: 0x010000,
        firewall_mark_mask: 0xFF0000,
        routing_priority: 10001
      )

      info.route_table.should eq(10001)
      info.virtual_ip.to_s.should eq("10.0.1.10")
      info.gateway_ip.to_s.should eq("10.0.1.1")
      info.network_cidr.to_s.should eq("10.0.1.0/24")
      info.source_cidrs.size.should eq(1)
      info.source_cidrs[0].to_s.should eq("172.16.0.0/12")
      info.firewall_mark.should eq(0x010000)
      info.firewall_mark_mask.should eq(0xFF0000)
      info.routing_priority.should eq(10001)
    end
  end

  describe "equality" do
    it "compares RouteTableInfo records by value" do
      info1 = Netwrangler::Agent::RouteTableInfo.new(
        route_table: 10001,
        virtual_ip: Netwrangler::Util::IPv4Address.parse("10.0.1.10"),
        gateway_ip: Netwrangler::Util::IPv4Address.parse("10.0.1.1"),
        network_cidr: Netwrangler::Util::IPv4Network.parse("10.0.1.0/24"),
        source_cidrs: [Netwrangler::Util::IPv4Network.parse("172.16.0.0/12")],
        firewall_mark: 0x010000,
        firewall_mark_mask: 0xFF0000,
        routing_priority: 10001
      )

      info2 = Netwrangler::Agent::RouteTableInfo.new(
        route_table: 10001,
        virtual_ip: Netwrangler::Util::IPv4Address.parse("10.0.1.10"),
        gateway_ip: Netwrangler::Util::IPv4Address.parse("10.0.1.1"),
        network_cidr: Netwrangler::Util::IPv4Network.parse("10.0.1.0/24"),
        source_cidrs: [Netwrangler::Util::IPv4Network.parse("172.16.0.0/12")],
        firewall_mark: 0x010000,
        firewall_mark_mask: 0xFF0000,
        routing_priority: 10001
      )

      info1.should eq(info2)
    end

    it "distinguishes different route_table" do
      info1 = Netwrangler::Agent::RouteTableInfo.new(
        route_table: 10001,
        virtual_ip: Netwrangler::Util::IPv4Address.parse("10.0.1.10"),
        gateway_ip: Netwrangler::Util::IPv4Address.parse("10.0.1.1"),
        network_cidr: Netwrangler::Util::IPv4Network.parse("10.0.1.0/24"),
        source_cidrs: [Netwrangler::Util::IPv4Network.parse("172.16.0.0/12")],
        firewall_mark: 0x010000,
        firewall_mark_mask: 0xFF0000,
        routing_priority: 10001
      )

      info2 = Netwrangler::Agent::RouteTableInfo.new(
        route_table: 10002,
        virtual_ip: Netwrangler::Util::IPv4Address.parse("10.0.1.10"),
        gateway_ip: Netwrangler::Util::IPv4Address.parse("10.0.1.1"),
        network_cidr: Netwrangler::Util::IPv4Network.parse("10.0.1.0/24"),
        source_cidrs: [Netwrangler::Util::IPv4Network.parse("172.16.0.0/12")],
        firewall_mark: 0x010000,
        firewall_mark_mask: 0xFF0000,
        routing_priority: 10001
      )

      info1.should_not eq(info2)
    end

    it "distinguishes different vip_address" do
      info1 = Netwrangler::Agent::RouteTableInfo.new(
        route_table: 10001,
        virtual_ip: Netwrangler::Util::IPv4Address.parse("10.0.1.10"),
        gateway_ip: Netwrangler::Util::IPv4Address.parse("10.0.1.1"),
        network_cidr: Netwrangler::Util::IPv4Network.parse("10.0.1.0/24"),
        source_cidrs: [Netwrangler::Util::IPv4Network.parse("172.16.0.0/12")],
        firewall_mark: 0x010000,
        firewall_mark_mask: 0xFF0000,
        routing_priority: 10001
      )

      info2 = Netwrangler::Agent::RouteTableInfo.new(
        route_table: 10001,
        virtual_ip: Netwrangler::Util::IPv4Address.parse("10.0.1.11"),
        gateway_ip: Netwrangler::Util::IPv4Address.parse("10.0.1.1"),
        network_cidr: Netwrangler::Util::IPv4Network.parse("10.0.1.0/24"),
        source_cidrs: [Netwrangler::Util::IPv4Network.parse("172.16.0.0/12")],
        firewall_mark: 0x010000,
        firewall_mark_mask: 0xFF0000,
        routing_priority: 10001
      )

      info1.should_not eq(info2)
    end

    it "distinguishes different gateway_ip" do
      info1 = Netwrangler::Agent::RouteTableInfo.new(
        route_table: 10001,
        virtual_ip: Netwrangler::Util::IPv4Address.parse("10.0.1.10"),
        gateway_ip: Netwrangler::Util::IPv4Address.parse("10.0.1.1"),
        network_cidr: Netwrangler::Util::IPv4Network.parse("10.0.1.0/24"),
        source_cidrs: [Netwrangler::Util::IPv4Network.parse("172.16.0.0/12")],
        firewall_mark: 0x010000,
        firewall_mark_mask: 0xFF0000,
        routing_priority: 10001
      )

      info2 = Netwrangler::Agent::RouteTableInfo.new(
        route_table: 10001,
        virtual_ip: Netwrangler::Util::IPv4Address.parse("10.0.1.10"),
        gateway_ip: Netwrangler::Util::IPv4Address.parse("10.0.1.2"),
        network_cidr: Netwrangler::Util::IPv4Network.parse("10.0.1.0/24"),
        source_cidrs: [Netwrangler::Util::IPv4Network.parse("172.16.0.0/12")],
        firewall_mark: 0x010000,
        firewall_mark_mask: 0xFF0000,
        routing_priority: 10001
      )

      info1.should_not eq(info2)
    end

    it "distinguishes different network_cidr" do
      info1 = Netwrangler::Agent::RouteTableInfo.new(
        route_table: 10001,
        virtual_ip: Netwrangler::Util::IPv4Address.parse("10.0.1.10"),
        gateway_ip: Netwrangler::Util::IPv4Address.parse("10.0.1.1"),
        network_cidr: Netwrangler::Util::IPv4Network.parse("10.0.1.0/24"),
        source_cidrs: [Netwrangler::Util::IPv4Network.parse("172.16.0.0/12")],
        firewall_mark: 0x010000,
        firewall_mark_mask: 0xFF0000,
        routing_priority: 10001
      )

      info2 = Netwrangler::Agent::RouteTableInfo.new(
        route_table: 10001,
        virtual_ip: Netwrangler::Util::IPv4Address.parse("10.0.1.10"),
        gateway_ip: Netwrangler::Util::IPv4Address.parse("10.0.1.1"),
        network_cidr: Netwrangler::Util::IPv4Network.parse("10.0.2.0/24"),
        source_cidrs: [Netwrangler::Util::IPv4Network.parse("172.16.0.0/12")],
        firewall_mark: 0x010000,
        firewall_mark_mask: 0xFF0000,
        routing_priority: 10001
      )

      info1.should_not eq(info2)
    end

    it "distinguishes different source_cidrs" do
      info1 = Netwrangler::Agent::RouteTableInfo.new(
        route_table: 10001,
        virtual_ip: Netwrangler::Util::IPv4Address.parse("10.0.1.10"),
        gateway_ip: Netwrangler::Util::IPv4Address.parse("10.0.1.1"),
        network_cidr: Netwrangler::Util::IPv4Network.parse("10.0.1.0/24"),
        source_cidrs: [Netwrangler::Util::IPv4Network.parse("172.16.0.0/12")],
        firewall_mark: 0x010000,
        firewall_mark_mask: 0xFF0000,
        routing_priority: 10001
      )

      info2 = Netwrangler::Agent::RouteTableInfo.new(
        route_table: 10001,
        virtual_ip: Netwrangler::Util::IPv4Address.parse("10.0.1.10"),
        gateway_ip: Netwrangler::Util::IPv4Address.parse("10.0.1.1"),
        network_cidr: Netwrangler::Util::IPv4Network.parse("10.0.1.0/24"),
        source_cidrs: [Netwrangler::Util::IPv4Network.parse("192.168.0.0/16")],
        firewall_mark: 0x010000,
        firewall_mark_mask: 0xFF0000,
        routing_priority: 10001
      )

      info1.should_not eq(info2)
    end

    it "distinguishes different firewall_mark" do
      info1 = Netwrangler::Agent::RouteTableInfo.new(
        route_table: 10001,
        virtual_ip: Netwrangler::Util::IPv4Address.parse("10.0.1.10"),
        gateway_ip: Netwrangler::Util::IPv4Address.parse("10.0.1.1"),
        network_cidr: Netwrangler::Util::IPv4Network.parse("10.0.1.0/24"),
        source_cidrs: [Netwrangler::Util::IPv4Network.parse("172.16.0.0/12")],
        firewall_mark: 0x010000,
        firewall_mark_mask: 0xFF0000,
        routing_priority: 10001
      )

      info2 = Netwrangler::Agent::RouteTableInfo.new(
        route_table: 10001,
        virtual_ip: Netwrangler::Util::IPv4Address.parse("10.0.1.10"),
        gateway_ip: Netwrangler::Util::IPv4Address.parse("10.0.1.1"),
        network_cidr: Netwrangler::Util::IPv4Network.parse("10.0.1.0/24"),
        source_cidrs: [Netwrangler::Util::IPv4Network.parse("172.16.0.0/12")],
        firewall_mark: 0x020000,
        firewall_mark_mask: 0xFF0000,
        routing_priority: 10001
      )

      info1.should_not eq(info2)
    end
  end

  describe "hash" do
    it "produces consistent hash for equal records" do
      info1 = Netwrangler::Agent::RouteTableInfo.new(
        route_table: 10001,
        virtual_ip: Netwrangler::Util::IPv4Address.parse("10.0.1.10"),
        gateway_ip: Netwrangler::Util::IPv4Address.parse("10.0.1.1"),
        network_cidr: Netwrangler::Util::IPv4Network.parse("10.0.1.0/24"),
        source_cidrs: [Netwrangler::Util::IPv4Network.parse("172.16.0.0/12")],
        firewall_mark: 0x010000,
        firewall_mark_mask: 0xFF0000,
        routing_priority: 10001
      )

      info2 = Netwrangler::Agent::RouteTableInfo.new(
        route_table: 10001,
        virtual_ip: Netwrangler::Util::IPv4Address.parse("10.0.1.10"),
        gateway_ip: Netwrangler::Util::IPv4Address.parse("10.0.1.1"),
        network_cidr: Netwrangler::Util::IPv4Network.parse("10.0.1.0/24"),
        source_cidrs: [Netwrangler::Util::IPv4Network.parse("172.16.0.0/12")],
        firewall_mark: 0x010000,
        firewall_mark_mask: 0xFF0000,
        routing_priority: 10001
      )

      info1.hash.should eq(info2.hash)
    end

    it "can be used as hash key" do
      info = Netwrangler::Agent::RouteTableInfo.new(
        route_table: 10001,
        virtual_ip: Netwrangler::Util::IPv4Address.parse("10.0.1.10"),
        gateway_ip: Netwrangler::Util::IPv4Address.parse("10.0.1.1"),
        network_cidr: Netwrangler::Util::IPv4Network.parse("10.0.1.0/24"),
        source_cidrs: [Netwrangler::Util::IPv4Network.parse("172.16.0.0/12")],
        firewall_mark: 0x010000,
        firewall_mark_mask: 0xFF0000,
        routing_priority: 10001
      )

      hash = {info => "test"}
      hash[info].should eq("test")
    end
  end
end

describe Netwrangler::Agent::RoutesUpdater do
  describe ".stale_tables" do
    it "returns only the tables no interface wants" do
      Netwrangler::Agent::RoutesUpdater.stale_tables([20002, 20003, 20009], desired_tables: Set{20002, 20003})
        .should eq([20009])
    end

    it "returns every table when nothing is wanted" do
      Netwrangler::Agent::RoutesUpdater.stale_tables([20002, 20003], desired_tables: Set(Int32).new)
        .should eq([20002, 20003])
    end
  end
end

module RoutesUpdaterSpecHelper
  def self.gateway(destination = "198.51.100.0/24", route_table = 10600, routing_priority = 10650) : Netwrangler::Agent::GatewayRuleEntry
    Netwrangler::Agent::GatewayRuleEntry.new(name: "vpn",
      destination_cidr: Netwrangler::Util::IPv4Network.parse(destination),
      route_table: route_table, routing_priority: routing_priority)
  end
end

describe Netwrangler::Agent::RoutesUpdater do
  # `ip --json rule show` (iproute2 6.19) for:
  #   5208:  not from all fwmark 0xca6c lookup 51820
  #   10200: from all fwmark 0x10000/0xff0000 lookup 10200 proto 110
  #   10300: from all fwmark 0x20000/0xff0000 lookup 10300
  #   10650: from all to 198.51.100.0/24 fwmark 0/0xff0000 lookup 10600 proto 110
  #   10700: from all to 192.168.99.0/24 lookup 10700 proto 110
  #   10800: from 10.0.0.0/8 to 203.0.113.0/24 lookup 10800
  #   10900: not from all to 192.0.2.0/24 lookup 10900 proto static
  rule_output = <<-JSON
    [{"priority":0,"src":"all","table":"local"},{"priority":5208,"not":null,"src":"all","fwmark":"0xca6c","table":"51820"},{"priority":10200,"src":"all","fwmark":"0x10000","fwmask":"0xff0000","table":"10200","protocol":"110"},{"priority":10300,"src":"all","fwmark":"0x20000","fwmask":"0xff0000","table":"10300"},{"priority":10650,"src":"all","dst":"198.51.100.0","dstlen":24,"fwmark":"0","fwmask":"0xff0000","table":"10600","protocol":"110"},{"priority":10700,"src":"all","dst":"192.168.99.0","dstlen":24,"table":"10700","protocol":"110"},{"priority":10800,"src":"10.0.0.0","srclen":8,"dst":"203.0.113.0","dstlen":24,"table":"10800"},{"priority":10900,"not":null,"src":"all","dst":"192.0.2.0","dstlen":24,"table":"10900","protocol":"static"},{"priority":32766,"src":"all","table":"main"},{"priority":32767,"src":"all","table":"default"}]
    JSON

  listed_rule = ->(json : String) { JSON.parse(json) }

  describe ".parse_fwmark_rules" do
    it "returns the agent's VIP fwmark rules and ignores gateway and foreign rules" do
      Netwrangler::Agent::RoutesUpdater.parse_fwmark_rules(rule_output).should eq({10200 => 0x10000})
    end
  end

  describe ".policy_rule_add_args" do
    it "tags the VIP fwmark rule with the agent's protocol" do
      Netwrangler::Agent::RoutesUpdater.policy_rule_add_args(10200, firewall_mark: 0x10000, firewall_mark_mask: 0xff0000_u32, routing_priority: 10200)
        .should eq(["rule", "add", "fwmark", "0x10000/0xff0000", "table", "10200", "priority", "10200", "protocol", "110"])
    end
  end

  describe ".vip_rule_delete_args" do
    it "selects a VIP fwmark rule by priority, fwmark, table and protocol" do
      Netwrangler::Agent::RoutesUpdater.vip_rule_delete_args(listed_rule.call(%({"priority":10200,"src":"all","fwmark":"0x10000","fwmask":"0xff0000","table":"10200","protocol":"110"})))
        .should eq(["rule", "del", "priority", "10200", "fwmark", "0x10000/0xff0000", "table", "10200", "protocol", "110"])
    end

    it "selects a rule with a full mask by its mark alone, as ip lists it" do
      Netwrangler::Agent::RoutesUpdater.vip_rule_delete_args(listed_rule.call(%({"priority":10002,"src":"all","fwmark":"0x20000","table":"10002","protocol":"110"})))
        .should eq(["rule", "del", "priority", "10002", "fwmark", "0x20000", "table", "10002", "protocol", "110"])
    end

    it "leaves a gateway rule in the same table alone" do
      Netwrangler::Agent::RoutesUpdater.vip_rule_delete_args(listed_rule.call(%({"priority":10650,"src":"all","dst":"198.51.100.0","dstlen":24,"fwmark":"0","fwmask":"0xff0000","table":"10200","protocol":"110"})))
        .should be_nil
    end

    it "leaves an untagged or inverted fwmark rule alone" do
      Netwrangler::Agent::RoutesUpdater.vip_rule_delete_args(listed_rule.call(%({"priority":10200,"src":"all","fwmark":"0x10000","fwmask":"0xff0000","table":"10200"}))).should be_nil
      Netwrangler::Agent::RoutesUpdater.vip_rule_delete_args(listed_rule.call(%({"priority":5208,"not":null,"src":"all","fwmark":"0xca6c","table":"51820","protocol":"110"}))).should be_nil
    end
  end

  describe ".rule_protocol" do
    it "reads the protocol of a rule" do
      Netwrangler::Agent::RoutesUpdater.rule_protocol(listed_rule.call(%({"priority":10200,"table":"10200","protocol":"110"}))).should eq("110")
    end

    it "is nil for a rule without a protocol" do
      Netwrangler::Agent::RoutesUpdater.rule_protocol(listed_rule.call(%({"priority":10200,"table":"10200"}))).should be_nil
    end
  end

  describe ".parse_rules" do
    it "reads an empty listing" do
      Netwrangler::Agent::RoutesUpdater.parse_rules("[]").should be_empty
      Netwrangler::Agent::RoutesUpdater.parse_rules("").should be_empty
    end
  end

  describe ".parse_destination_rules" do
    it "returns destination rules with and without a fwmark selector and their protocol" do
      Netwrangler::Agent::RoutesUpdater.parse_destination_rules(rule_output).should eq([
        Netwrangler::Agent::RoutesUpdater::DestinationRule.new(priority: 10650, destination: "198.51.100.0/24", fwmark: "0/0xff0000", route_table: 10600, protocol: "110"),
        Netwrangler::Agent::RoutesUpdater::DestinationRule.new(priority: 10700, destination: "192.168.99.0/24", fwmark: nil, route_table: 10700, protocol: "110"),
        Netwrangler::Agent::RoutesUpdater::DestinationRule.new(priority: 10800, destination: "203.0.113.0/24", fwmark: nil, route_table: 10800, protocol: nil),
        Netwrangler::Agent::RoutesUpdater::DestinationRule.new(priority: 10900, destination: "192.0.2.0/24", fwmark: nil, route_table: 10900, protocol: "static"),
      ])
    end
  end

  describe ".managed_destination_rules" do
    it "returns only the destination rules tagged with the agent's protocol" do
      Netwrangler::Agent::RoutesUpdater.managed_destination_rules(rule_output).map(&.priority).should eq([10650, 10700])
    end
  end

  describe ".gateway_fwmark" do
    it "is nil without a mask" do
      Netwrangler::Agent::RoutesUpdater.gateway_fwmark(nil).should be_nil
    end

    it "matches unmarked packets under the mask" do
      Netwrangler::Agent::RoutesUpdater.gateway_fwmark(0xff0000_u32).should eq("0/0xff0000")
    end

    it "prints a full mask without the mask part, as ip rule does" do
      Netwrangler::Agent::RoutesUpdater.gateway_fwmark(UInt32::MAX).should eq("0")
    end

    it "is nil for a zero mask, which ip rule does not print" do
      Netwrangler::Agent::RoutesUpdater.gateway_fwmark(0_u32).should be_nil
    end
  end

  describe ".gateway_rule_matches?" do
    rule = Netwrangler::Agent::RoutesUpdater::DestinationRule.new(priority: 10650, destination: "198.51.100.0/24", fwmark: "0/0xff0000", route_table: 10600, protocol: "110")

    it "is true when destination, table, priority, fwmark and protocol match" do
      Netwrangler::Agent::RoutesUpdater.gateway_rule_matches?(rule, RoutesUpdaterSpecHelper.gateway, fwmark: "0/0xff0000").should be_true
    end

    it "is false when the priority changed" do
      gateway = RoutesUpdaterSpecHelper.gateway(routing_priority: 10651)
      Netwrangler::Agent::RoutesUpdater.gateway_rule_matches?(rule, gateway, fwmark: "0/0xff0000").should be_false
    end

    it "is false when the route table changed" do
      gateway = RoutesUpdaterSpecHelper.gateway(route_table: 10601)
      Netwrangler::Agent::RoutesUpdater.gateway_rule_matches?(rule, gateway, fwmark: "0/0xff0000").should be_false
    end

    it "is false when the fwmark selector differs" do
      Netwrangler::Agent::RoutesUpdater.gateway_rule_matches?(rule, RoutesUpdaterSpecHelper.gateway, fwmark: nil).should be_false
    end

    it "is false for a rule without the agent's protocol, so an untagged rule is replaced" do
      untagged = rule.copy_with(protocol: nil)
      Netwrangler::Agent::RoutesUpdater.gateway_rule_matches?(untagged, RoutesUpdaterSpecHelper.gateway, fwmark: "0/0xff0000").should be_false
    end
  end

  describe ".gateway_rule_change" do
    current = Netwrangler::Agent::RoutesUpdater::DestinationRule.new(priority: 10650, destination: "198.51.100.0/24", fwmark: "0/0xff0000", route_table: 10600, protocol: "110")

    it "changes nothing when the one rule matches" do
      Netwrangler::Agent::RoutesUpdater.gateway_rule_change([current], RoutesUpdaterSpecHelper.gateway, fwmark: "0/0xff0000")
        .should eq({add: false, remove: [] of Netwrangler::Agent::RoutesUpdater::DestinationRule})
    end

    it "adds the rule when there is none" do
      Netwrangler::Agent::RoutesUpdater.gateway_rule_change([] of Netwrangler::Agent::RoutesUpdater::DestinationRule,
        RoutesUpdaterSpecHelper.gateway, fwmark: "0/0xff0000")
        .should eq({add: true, remove: [] of Netwrangler::Agent::RoutesUpdater::DestinationRule})
    end

    it "adds the new rule and removes the old one when the priority changed" do
      gateway = RoutesUpdaterSpecHelper.gateway(routing_priority: 10651)
      Netwrangler::Agent::RoutesUpdater.gateway_rule_change([current], gateway, fwmark: "0/0xff0000")
        .should eq({add: true, remove: [current]})
    end

    it "adds the new rule and removes the old one when the mask changed" do
      Netwrangler::Agent::RoutesUpdater.gateway_rule_change([current], RoutesUpdaterSpecHelper.gateway, fwmark: "0/0xf00000")
        .should eq({add: true, remove: [current]})
    end

    it "replaces an untagged rule from an earlier agent version" do
      untagged = current.copy_with(protocol: nil)
      Netwrangler::Agent::RoutesUpdater.gateway_rule_change([untagged], RoutesUpdaterSpecHelper.gateway, fwmark: "0/0xff0000")
        .should eq({add: true, remove: [untagged]})
    end

    it "keeps one matching rule and removes a duplicate" do
      Netwrangler::Agent::RoutesUpdater.gateway_rule_change([current, current], RoutesUpdaterSpecHelper.gateway, fwmark: "0/0xff0000")
        .should eq({add: false, remove: [current]})
    end
  end

  describe ".gateway_rule_delete_args" do
    it "selects a tagged rule by priority, destination, fwmark, table and protocol" do
      rule = Netwrangler::Agent::RoutesUpdater::DestinationRule.new(priority: 10650, destination: "198.51.100.0/24", fwmark: "0/0xff0000", route_table: 10600, protocol: "110")
      Netwrangler::Agent::RoutesUpdater.gateway_rule_delete_args(rule)
        .should eq(["rule", "del", "priority", "10650", "to", "198.51.100.0/24", "fwmark", "0/0xff0000", "table", "10600", "protocol", "110"])
    end

    it "leaves out the fwmark and protocol a rule does not have" do
      rule = Netwrangler::Agent::RoutesUpdater::DestinationRule.new(priority: 10650, destination: "198.51.100.0/24", fwmark: nil, route_table: 10600)
      Netwrangler::Agent::RoutesUpdater.gateway_rule_delete_args(rule)
        .should eq(["rule", "del", "priority", "10650", "to", "198.51.100.0/24", "table", "10600"])
    end
  end

  describe ".parse_pod_route" do
    it "takes the next hop of a pod reached through a gateway" do
      json = %([{"dst":"10.244.0.3","gateway":"172.19.0.3","dev":"eth0","prefsrc":"172.19.0.4","flags":[],"uid":0,"cache":[]}])

      Netwrangler::Agent::RoutesUpdater.parse_pod_route(json, pod_ip: "10.244.0.3").should eq(
        Netwrangler::Agent::RoutesUpdater::ResolvedPodRoute.new(gateway: "172.19.0.3", dev: "eth0", prefsrc: "172.19.0.4"))
    end

    it "takes the pod itself as next hop when it is directly connected" do
      json = %([{"dst":"10.244.1.5","dev":"veth1","prefsrc":"10.244.1.1","flags":[],"uid":0,"cache":[]}])

      Netwrangler::Agent::RoutesUpdater.parse_pod_route(json, pod_ip: "10.244.1.5").try(&.gateway).should eq("10.244.1.5")
    end

    it "marks a pod whose address is the node's own as local" do
      json = %([{"type":"local","dst":"172.19.0.4","dev":"lo","table":"local","prefsrc":"172.19.0.4","flags":[],"uid":0,"cache":["local"]}])

      Netwrangler::Agent::RoutesUpdater.parse_pod_route(json, pod_ip: "172.19.0.4").try(&.local).should be_true
    end

    it "is nil without a device or preferred source" do
      Netwrangler::Agent::RoutesUpdater.parse_pod_route("[]", pod_ip: "10.244.1.5").should be_nil
      Netwrangler::Agent::RoutesUpdater.parse_pod_route(%([{"dst":"10.244.1.5","flags":[]}]), pod_ip: "10.244.1.5").should be_nil
    end
  end

  describe ".parse_routes" do
    it "marks unreachable routes, keeps the protocol and skips entries without a destination" do
      json = <<-JSON
        [
          {"dst": "198.51.100.0/24", "gateway": "10.244.1.5", "dev": "eth0", "prefsrc": "172.18.0.2", "protocol": "110", "flags": []},
          {"type": "unreachable", "dst": "198.51.100.0/24", "metric": 4294967295, "flags": []},
          {"type": "broadcast", "flags": []}
        ]
        JSON

      Netwrangler::Agent::RoutesUpdater.parse_routes(json).should eq([
        Netwrangler::Agent::RoutesUpdater::ExistingRoute.new(destination: "198.51.100.0/24", unreachable: false, protocol: "110"),
        Netwrangler::Agent::RoutesUpdater::ExistingRoute.new(destination: "198.51.100.0/24", unreachable: true, protocol: nil),
      ])
    end

    it "leaves out blackhole and prohibit routes, which the agent never adds" do
      json = <<-JSON
        [
          {"type": "blackhole", "dst": "203.0.113.0/24", "flags": []},
          {"type": "prohibit", "dst": "192.0.2.0/24", "flags": []},
          {"type": "unicast", "dst": "198.51.100.0/24", "dev": "eth0", "flags": []}
        ]
        JSON

      Netwrangler::Agent::RoutesUpdater.parse_routes(json).should eq([
        Netwrangler::Agent::RoutesUpdater::ExistingRoute.new(destination: "198.51.100.0/24", unreachable: false),
      ])
    end

    it "tells the agent's routes from untagged ones" do
      json = %([{"type": "unreachable", "dst": "198.51.100.0/24", "protocol": "110", "flags": []}, {"type": "unreachable", "dst": "192.0.2.0/24", "flags": []}])
      Netwrangler::Agent::RoutesUpdater.parse_routes(json).map(&.managed?).should eq([true, false])
    end
  end

  describe "bare host addresses" do
    it "normalises a /32 rule destination, which ip lists without its length" do
      json = %([{"priority":10651,"src":"all","dst":"198.51.100.5","fwmark":"0","fwmask":"0xff0000","table":"10600"}])
      Netwrangler::Agent::RoutesUpdater.parse_destination_rules(json).first.destination.should eq("198.51.100.5/32")
    end

    it "normalises a /32 route destination and the default route" do
      json = %([{"dst": "198.51.100.5", "flags": []}, {"dst": "default", "flags": []}])
      Netwrangler::Agent::RoutesUpdater.parse_routes(json).map(&.destination).should eq(["198.51.100.5/32", "0.0.0.0/0"])
    end
  end

  describe ".gateway_rule_add_args" do
    it "adds an explicit mask" do
      Netwrangler::Agent::RoutesUpdater.gateway_rule_add_args(RoutesUpdaterSpecHelper.gateway, firewall_mark_mask: 0xff0000_u32)
        .should eq(["rule", "add", "to", "198.51.100.0/24", "fwmark", "0/0xff0000", "table", "10600", "priority", "10650", "protocol", "110"])
    end

    it "never emits a bare fwmark 0 for the full mask" do
      Netwrangler::Agent::RoutesUpdater.gateway_rule_add_args(RoutesUpdaterSpecHelper.gateway, firewall_mark_mask: UInt32::MAX)
        .should eq(["rule", "add", "to", "198.51.100.0/24", "fwmark", "0/0xffffffff", "table", "10600", "priority", "10650", "protocol", "110"])
    end

    it "omits the fwmark without a mask" do
      Netwrangler::Agent::RoutesUpdater.gateway_rule_add_args(RoutesUpdaterSpecHelper.gateway, firewall_mark_mask: nil)
        .should eq(["rule", "add", "to", "198.51.100.0/24", "table", "10600", "priority", "10650", "protocol", "110"])
    end

    it "omits the fwmark for a zero mask" do
      Netwrangler::Agent::RoutesUpdater.gateway_rule_add_args(RoutesUpdaterSpecHelper.gateway, firewall_mark_mask: 0_u32)
        .should eq(["rule", "add", "to", "198.51.100.0/24", "table", "10600", "priority", "10650", "protocol", "110"])
    end
  end

  describe ".stale_routes" do
    pod_route = Netwrangler::Agent::RoutesUpdater::ExistingRoute.new(destination: "198.51.100.0/24", unreachable: false)
    fallback = Netwrangler::Agent::RoutesUpdater::ExistingRoute.new(destination: "198.51.100.0/24", unreachable: true)

    it "keeps routes that are still desired" do
      Netwrangler::Agent::RoutesUpdater.stale_routes([pod_route, fallback],
        unicast: Set{"198.51.100.0/24"}, unreachable: Set{"198.51.100.0/24"}).should be_empty
    end

    it "drops the pod route but keeps the fallback once the VipRoute is gone" do
      Netwrangler::Agent::RoutesUpdater.stale_routes([pod_route, fallback],
        unicast: Set(String).new, unreachable: Set{"198.51.100.0/24"}).should eq([pod_route])
    end

    it "drops the fallback once the gateway is gone" do
      Netwrangler::Agent::RoutesUpdater.stale_routes([pod_route, fallback],
        unicast: Set{"198.51.100.0/24"}, unreachable: Set(String).new).should eq([fallback])
    end
  end

  describe ".gateway_sweep_tables" do
    it "covers every VipRoute table, so a refused gateway's pod route is swept" do
      rule = Netwrangler::Agent::RoutesUpdater::DestinationRule.new(priority: 10700, destination: "192.168.99.0/24", fwmark: nil, route_table: 10700)

      Netwrangler::Agent::RoutesUpdater.gateway_sweep_tables([10600, 10602],
        gateways: [RoutesUpdaterSpecHelper.gateway(route_table: 10601)], rules: [rule], vip_route_tables: Set(Int32).new)
        .should eq(Set{10600, 10602, 10601, 10700})
    end

    it "never sweeps a reserved table or a VipAddress table" do
      rule = Netwrangler::Agent::RoutesUpdater::DestinationRule.new(priority: 10700, destination: "192.168.99.0/24", fwmark: nil, route_table: 253)

      Netwrangler::Agent::RoutesUpdater.gateway_sweep_tables([254, 20002, 10600],
        gateways: [] of Netwrangler::Agent::GatewayRuleEntry, rules: [rule], vip_route_tables: Set{20002})
        .should eq(Set{10600})
    end
  end

  describe ".route_delete_args" do
    it "deletes a pod route as unicast so the fallback survives" do
      route = Netwrangler::Agent::RoutesUpdater::ExistingRoute.new(destination: "198.51.100.0/24", unreachable: false)
      Netwrangler::Agent::RoutesUpdater.route_delete_args(route, route_table: 10600)
        .should eq(["route", "del", "unicast", "198.51.100.0/24", "table", "10600"])
    end

    it "deletes the fallback by type and metric" do
      route = Netwrangler::Agent::RoutesUpdater::ExistingRoute.new(destination: "198.51.100.0/24", unreachable: true)
      Netwrangler::Agent::RoutesUpdater.route_delete_args(route, route_table: 10600)
        .should eq(["route", "del", "unreachable", "198.51.100.0/24", "table", "10600", "metric", "4294967295"])
    end
  end
end
