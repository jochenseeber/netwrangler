require "../spec_helper"

describe Netwrangler::Agent::AgentHook do
  describe "#run" do
    it "raises for non-existent binding context path" do
      hook = Netwrangler::Agent::AgentHook.new(node_name: "test-node")

      expect_raises(File::NotFoundError) do
        hook.run("/nonexistent/path.json")
      end
    end

    it "raises for invalid JSON content" do
      tempfile = File.tempfile("binding_context", ".json") do |file|
        file.print("not valid json")
      end

      begin
        hook = Netwrangler::Agent::AgentHook.new(node_name: "test-node")
        expect_raises(JSON::ParseException) do
          hook.run(tempfile.path)
        end
      ensure
        tempfile.delete
      end
    end

    it "handles empty binding context array" do
      tempfile = File.tempfile("binding_context", ".json") do |file|
        file.print("[]")
      end

      begin
        hook = Netwrangler::Agent::AgentHook.new(node_name: "test-node")
        hook.run(tempfile.path)
      ensure
        tempfile.delete
      end
    end
  end

  describe "VIP_ROUTE_FILTER" do
    it "contains expected jqFilter fields" do
      filter = Netwrangler::Agent::AgentHook::VIP_ROUTE_FILTER
      filter.should contain("name")
      filter.should contain("namespace")
      filter.should contain("destination_cidr")
      filter.should contain("gateway_node")
      filter.should contain("pod_ip")
      filter.should contain("route_table")
      filter.should contain("routing_priority")
      filter.should contain(".metadata.name")
      filter.should contain(".metadata.namespace")
      filter.should contain(".spec.destinationCIDR")
      filter.should contain(".spec.gatewayNode")
      filter.should contain(".spec.podIP")
      filter.should contain(".spec.routeTable")
      filter.should contain(".spec.routingPriority")
    end
  end

  describe ".parse_active_interfaces" do
    it "returns UP interfaces" do
      json = <<-JSON
        [
          {"ifname": "lo", "flags": ["LOOPBACK", "UP", "LOWER_UP"]},
          {"ifname": "eth0", "flags": ["BROADCAST", "MULTICAST", "UP", "LOWER_UP"]},
          {"ifname": "eth1", "flags": ["BROADCAST", "MULTICAST"]}
        ]
        JSON

      result = Netwrangler::Agent::AgentHook.parse_active_interfaces(json)
      result.should eq(Set{"lo", "eth0"})
    end

    it "returns empty set for empty array" do
      result = Netwrangler::Agent::AgentHook.parse_active_interfaces("[]")
      result.should be_empty
    end

    it "excludes interfaces without UP flag" do
      json = <<-JSON
        [
          {"ifname": "eth0", "flags": ["BROADCAST", "MULTICAST", "LOWER_UP"]}
        ]
        JSON

      result = Netwrangler::Agent::AgentHook.parse_active_interfaces(json)
      result.should be_empty
    end

    it "handles interfaces with only UP flag" do
      json = <<-JSON
        [
          {"ifname": "dummy0", "flags": ["UP"]}
        ]
        JSON

      result = Netwrangler::Agent::AgentHook.parse_active_interfaces(json)
      result.should eq(Set{"dummy0"})
    end
  end

  describe "VIP_GATEWAY_FILTER" do
    it "reads the VipGateway spec fields by their CRD names" do
      filter = Netwrangler::Agent::AgentHook::VIP_GATEWAY_FILTER
      filter.should contain(%("name": .metadata.name))
      filter.should contain(%("destination_cidr": .spec.destinationCIDR))
      filter.should contain(%("route_table": .spec.routeTable))
      filter.should contain(%("routing_priority": .spec.routingPriority))
    end
  end

  describe "#config_json" do
    config = JSON.parse(Netwrangler::Agent::AgentHook.new(node_name: "test-node").config_json)

    it "watches VipGateway in the agent group" do
      binding = config["kubernetes"].as_a.find! { |entry| entry["name"] == "vip_gateways" }
      binding["kind"].should eq("VipGateway")
      binding["group"].should eq("vip_address_agent")
      binding["executeHookOnEvent"].as_a.map(&.as_s).should eq(["Added", "Modified", "Deleted"])
      binding["jqFilter"].as_s.should eq(Netwrangler::Agent::AgentHook::VIP_GATEWAY_FILTER.strip)
    end

    it "gives every binding the snapshots of the other four" do
      bindings = config["kubernetes"].as_a
      names = bindings.map(&.["name"].as_s)
      names.size.should eq(5)

      bindings.each do |binding|
        included = binding["includeSnapshotsFrom"].as_a.map(&.as_s).to_set
        included.should eq(names.to_set - Set{binding["name"].as_s})
      end
    end

    it "includes VipGateway snapshots in the resync" do
      resync = config["schedule"].as_a.first
      resync["includeSnapshotsFrom"].as_a.map(&.as_s).should contain("vip_gateways")
    end
  end
end

module AgentHookSpecHelper
  def self.route_table(table : Int32, virtual_ip : String, network : String) : Netwrangler::Agent::RouteTableInfo
    Netwrangler::Agent::RouteTableInfo.new(
      route_table: table,
      virtual_ip: Netwrangler::Util::IPv4Address.parse(virtual_ip),
      gateway_ip: Netwrangler::Util::IPv4Address.parse(virtual_ip),
      network_cidr: Netwrangler::Util::IPv4Network.parse(network),
      source_cidrs: [] of Netwrangler::Util::IPv4Network,
      firewall_mark: table - 20000,
      firewall_mark_mask: 0x7f_u32,
      routing_priority: table
    )
  end
end

describe Netwrangler::Agent::AgentHook do
  describe ".desired_route_tables" do
    it "collects the route tables of every interface" do
      hub = Netwrangler::Agent::InterfaceState.new
      hub.route_tables << AgentHookSpecHelper.route_table(20002, "10.63.2.254", "10.63.0.0/16")
      public_state = Netwrangler::Agent::InterfaceState.new
      public_state.route_tables << AgentHookSpecHelper.route_table(20003, "49.13.109.136", "49.13.109.128/28")

      tables = Netwrangler::Agent::AgentHook.desired_route_tables({"hub" => hub, "public" => public_state})
      tables.map(&.route_table).should eq([20002, 20003])
    end
  end
end

describe Netwrangler::Agent::AgentHook do
  describe ".address_targets" do
    it "empties interfaces that still hold VIP addresses but no longer have a VipAddress" do
      vip = Netwrangler::Agent::AddressUpdater::DesiredAddress.new(
        ip: Netwrangler::Util::IPv4Address.parse("172.18.255.200"), prefix: 16)
      eth0 = Netwrangler::Agent::InterfaceState.new
      eth0.desired_addresses << vip

      targets = Netwrangler::Agent::AgentHook.address_targets({"eth0" => eth0},
        managed_interfaces: Set{"eth0", "vipdummy0"})

      targets.should eq({"eth0" => [vip], "vipdummy0" => [] of Netwrangler::Agent::AddressUpdater::DesiredAddress})
    end
  end
end

describe Netwrangler::Agent::AgentHook do
  describe ".with_attempts" do
    it "runs a reconciliation that succeeds once" do
      attempts = [] of Int32

      Netwrangler::Agent::AgentHook.with_attempts(2) { |attempt| attempts << attempt }

      attempts.should eq([1])
    end

    it "reconciles again after a failure, and stops there when the second pass succeeds" do
      attempts = [] of Int32

      Netwrangler::Agent::AgentHook.with_attempts(2) do |attempt|
        attempts << attempt
        raise "table vanished" if attempt == 1
      end

      attempts.should eq([1, 2])
    end

    it "raises the failure of the last attempt" do
      attempts = [] of Int32

      expect_raises(Exception, "still broken 2") do
        Netwrangler::Agent::AgentHook.with_attempts(2) do |attempt|
          attempts << attempt
          raise "still broken #{attempt}"
        end
      end
      attempts.should eq([1, 2])
    end
  end
end
