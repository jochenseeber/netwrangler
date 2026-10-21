# frozen_string_literal: true

require_relative "../spec_helper"

TEST_GW_AGENT_NAMESPACE = "vip-gw-agent-test"
TEST_GW_AGENT_NAME = "agent-gateway"
TEST_GW_AGENT_DESTINATION = "198.51.100.0/24"
TEST_GW_AGENT_TABLE = 10_600
TEST_GW_AGENT_PRIORITY = 10_600
TEST_GW_AGENT_POD_LABELS = { "app" => "gateway", "netwrangler.dev/gateway" => "enabled" }.freeze
TEST_GW_AGENT_MASK = 0xFF0000
TEST_GW_AGENT_FWMARK = "0/0xff0000"
TEST_GW_AGENT_CHANGED_PRIORITY = 10_610
TEST_GW_RULE_EVENTS = "/tmp/netwrangler-rule-events"
TEST_GW_BLACKHOLE_DESTINATION = "198.18.4.0/24"
TEST_GW_REMOVAL_NAME = "agent-gateway-removal"
TEST_GW_REMOVAL_DESTINATION = "192.0.2.0/24"
TEST_GW_REMOVAL_TABLE = 10_601
TEST_GW_REFUSED_NAME = "agent-gateway-refused"
TEST_GW_REFUSED_TABLE = 10_602
TEST_GW_AGENT_PROTOCOL = "110"
TEST_GW_FOREIGN_SOURCE = "10.99.0.0/16"
TEST_GW_FOREIGN_DESTINATION = "198.18.0.0/24"
TEST_GW_FOREIGN_TABLE = 10_603
TEST_GW_WIDE_NAME = "agent-gateway-wide"
TEST_GW_WIDE_DESTINATION = "198.19.0.0/24"
TEST_GW_WIDE_TABLE = 10_604
TEST_GW_NARROW_NAME = "agent-gateway-narrow"
TEST_GW_NARROW_DESTINATION = "198.19.0.128/25"
TEST_GW_NARROW_TABLE = 10_605
TEST_GW_EXTRA_NAMES = [TEST_GW_REMOVAL_NAME, TEST_GW_REFUSED_NAME, TEST_GW_WIDE_NAME, TEST_GW_NARROW_NAME].freeze

RSpec.describe "VipRoute Agent" do
  include IntegrationTest::KindHelper

  let(:namespace) { TEST_GW_AGENT_NAMESPACE }
  let(:nodes) { get_node_names }

  before(:all) do
    extend IntegrationTest::KubectlHelper
    extend IntegrationTest::KindHelper

    delete_namespace(TEST_GW_AGENT_NAMESPACE)
    kubectl("delete vipgateways.#{IntegrationTest::API_GROUP} #{TEST_GW_AGENT_NAME} --ignore-not-found")
    kubectl("delete vipgateways.#{IntegrationTest::API_GROUP} #{TEST_GW_EXTRA_NAMES.join(" ")} --ignore-not-found")

    @nodes = get_node_names
    raise "No nodes found" if @nodes.empty?

    result = create_namespace(TEST_GW_AGENT_NAMESPACE)
    raise "Failed to create namespace: #{result.message}" unless result.success?

    # Wait for agent DaemonSet
    ready = wait_for_daemonset_ready(
      "netwrangler-agent",
      namespace: IntegrationTest::CONTROLLER_NAMESPACE,
      timeout: 120
    )
    raise "Agent DaemonSet not ready" unless ready

    # The VipConfig mask gives the gateway rule its fwmark selector
    config_yaml = IntegrationTest.vip_config_yaml(
      name: "default", firewall_mark: 0x010000, firewall_mark_mask: TEST_GW_AGENT_MASK,
      route_table: 10_200, routing_priority: 10_200
    )
    result = kubectl_apply(config_yaml)
    raise "Failed to create VipConfig: #{result.message}" unless result.success?

    gateway_yaml = IntegrationTest.vip_gateway_yaml(
      name: TEST_GW_AGENT_NAME,
      destination_cidr: TEST_GW_AGENT_DESTINATION,
      route_table: TEST_GW_AGENT_TABLE,
      routing_priority: TEST_GW_AGENT_PRIORITY,
      pod_selector_labels: { "app" => "gateway" }
    )
    result = kubectl_apply(gateway_yaml)
    raise "Failed to create VipGateway: #{result.message}" unless result.success?
  end

  after(:all) do
    extend IntegrationTest::KubectlHelper
    extend IntegrationTest::KindHelper

    delete_namespace(TEST_GW_AGENT_NAMESPACE)
    kubectl_delete("vipgateway.#{IntegrationTest::API_GROUP}", TEST_GW_AGENT_NAME)
    kubectl("delete vipgateways.#{IntegrationTest::API_GROUP} #{TEST_GW_EXTRA_NAMES.join(" ")} --ignore-not-found")
    kubectl("delete vipconfigs.#{IntegrationTest::API_GROUP} default --ignore-not-found")

    # Clean up policy rules on all nodes
    @nodes&.each { |node| cleanup_destination_rules(node) }
  end

  after do
    kubectl("delete pods --all --namespace=#{namespace} --ignore-not-found")
    kubectl("delete viproutes.#{IntegrationTest::API_GROUP} --all --namespace=#{namespace} --ignore-not-found")
    sleep 2
  end

  def create_gateway_pod(name, node_name: nil, ready: true)
    yaml = IntegrationTest.pod_yaml(
      name: name,
      namespace: namespace,
      node_name: node_name,
      labels: TEST_GW_AGENT_POD_LABELS,
      ready: ready
    )
    result = kubectl_apply(yaml)
    expect(result).to be_success, "Failed to create pod: #{result.message}"

    if ready
      expect(wait_for_pod_ready(name, namespace: namespace)).to be(true),
                                                                "Pod #{name} did not become ready"
    else
      expect(wait_for_pod_running(name, namespace: namespace)).to be(true),
                                                                  "Pod #{name} did not start running"
    end
  end

  it "installs the scoped rule, the fallback and the set entry without a gateway pod" do
    nodes.each do |node|
      expect(wait_for_destination_rule(node, TEST_GW_AGENT_DESTINATION, TEST_GW_AGENT_TABLE,
                                       fwmark: TEST_GW_AGENT_FWMARK, priority: TEST_GW_AGENT_PRIORITY,
                                       protocol: TEST_GW_AGENT_PROTOCOL))
        .to be(true), "Scoped gateway rule tagged with the agent's protocol not found on #{node}"
      expect(wait_for_route(node, TEST_GW_AGENT_TABLE.to_s, TEST_GW_AGENT_DESTINATION, type: "unreachable"))
        .to be(true), "Unreachable fallback not found on #{node}"
      fallback = get_routes(node, TEST_GW_AGENT_TABLE.to_s).find { |r| r[:type] == "unreachable" }
      expect(fallback&.dig(:protocol)).to eq(TEST_GW_AGENT_PROTOCOL), "Fallback on #{node} is not tagged"
      expect(wait_for_gateway_destination_entry(node, TEST_GW_AGENT_DESTINATION))
        .to be(true), "gateway-destinations entry not found on #{node}"
    end
  end

  it "adds the pod route next to the fallback on all nodes" do
    create_gateway_pod("gw-pod-1", node_name: nodes.first)
    expect(wait_for_vip_routes(namespace: namespace, count: 1)).not_to be_nil, "Expected at least 1 VipRoute"

    nodes.each do |node|
      expect(wait_for_route(node, TEST_GW_AGENT_TABLE.to_s, TEST_GW_AGENT_DESTINATION, type: "unicast"))
        .to be(true), "Pod route not found on #{node}"
      expect(wait_for_route(node, TEST_GW_AGENT_TABLE.to_s, TEST_GW_AGENT_DESTINATION, type: "unreachable", timeout: 1))
        .to be(true), "Fallback missing next to the pod route on #{node}"
      expect(wait_for_destination_rule(node, TEST_GW_AGENT_DESTINATION, TEST_GW_AGENT_TABLE,
                                       fwmark: TEST_GW_AGENT_FWMARK, priority: TEST_GW_AGENT_PRIORITY, timeout: 1))
        .to be(true), "Scoped gateway rule changed when the pod route was added on #{node}"
    end
  end

  it "keeps the rule and the fallback when the VipRoute is deleted" do
    create_gateway_pod("gw-pod-1", node_name: nodes.first)
    expect(wait_for_vip_routes(namespace: namespace, count: 1)).not_to be_nil
    nodes.each do |node|
      expect(wait_for_route(node, TEST_GW_AGENT_TABLE.to_s, TEST_GW_AGENT_DESTINATION, type: "unicast"))
        .to be(true), "Pod route did not appear on #{node}"
    end

    delete_pod("gw-pod-1", namespace: namespace)
    expect(wait_for_vip_routes_cleanup(namespace: namespace, timeout: 60)).to be(true)

    nodes.each do |node|
      expect(wait_for_route_removal(node, TEST_GW_AGENT_TABLE.to_s, TEST_GW_AGENT_DESTINATION, type: "unicast", timeout: 60))
        .to be(true), "Pod route was not removed from #{node}"
    end

    # The rule and the fallback stay through a full resync on every node
    kept = holds_for? do
      nodes.all? do |node|
        get_routes(node, TEST_GW_AGENT_TABLE.to_s).any? { |r| r[:type] == "unreachable" } &&
          get_destination_rules(node).any? do |r|
            r[:destination] == TEST_GW_AGENT_DESTINATION && r[:table] == TEST_GW_AGENT_TABLE
          end
      end
    end
    expect(kept).to be(true), "Gateway rule or fallback disappeared after the VipRoute was deleted"
  end

  def apply_agent_gateway(routing_priority)
    result = kubectl_apply(IntegrationTest.vip_gateway_yaml(
      name: TEST_GW_AGENT_NAME,
      destination_cidr: TEST_GW_AGENT_DESTINATION,
      route_table: TEST_GW_AGENT_TABLE,
      routing_priority: routing_priority,
      pod_selector_labels: { "app" => "gateway" }
    ))
    expect(result).to be_success, "Failed to apply VipGateway: #{result.message}"
  end

  it "adds the new rule before it removes the old one when the priority changes" do
    node = nodes.first
    expect(wait_for_destination_rule(node, TEST_GW_AGENT_DESTINATION, TEST_GW_AGENT_TABLE, priority: TEST_GW_AGENT_PRIORITY))
      .to be(true), "Gateway rule not found on #{node}"

    # Record the kernel's rule events while the agent replaces the rule
    # The monitor stops on its own; the node has no pkill
    kind_exec(node, "rm -f #{TEST_GW_RULE_EVENTS}; (timeout 90 ip monitor rule > #{TEST_GW_RULE_EVENTS} 2>&1 &)")
    sleep 1
    apply_agent_gateway(TEST_GW_AGENT_CHANGED_PRIORITY)

    expect(wait_for_destination_rule(node, TEST_GW_AGENT_DESTINATION, TEST_GW_AGENT_TABLE,
                                     priority: TEST_GW_AGENT_CHANGED_PRIORITY, timeout: 60))
      .to be(true), "Rule with the new priority did not appear on #{node}"
    gone = 20.times.any? do
      next true if get_destination_rules(node).none? { |r| r[:priority] == TEST_GW_AGENT_PRIORITY }

      sleep 3
      false
    end
    expect(gone).to be(true), "Rule with the old priority stayed on #{node}"

    events = kind_exec(node, "cat #{TEST_GW_RULE_EVENTS}").message.lines
    added = events.index { |l| l.start_with?("#{TEST_GW_AGENT_CHANGED_PRIORITY}:") && l.include?("to #{TEST_GW_AGENT_DESTINATION}") }
    deleted = events.index { |l| l.start_with?("Deleted #{TEST_GW_AGENT_PRIORITY}:") && l.include?("to #{TEST_GW_AGENT_DESTINATION}") }
    expect(added).not_to be_nil, "No add event for the new rule: #{events.join}"
    expect(deleted).not_to be_nil, "No delete event for the old rule: #{events.join}"
    expect(added).to be < deleted, "The old rule went before the new one was added: #{events.join}"
  ensure
    kind_exec(node, "rm -f #{TEST_GW_RULE_EVENTS}") if node
    apply_agent_gateway(TEST_GW_AGENT_PRIORITY)
    nodes.each do |each_node|
      wait_for_destination_rule(each_node, TEST_GW_AGENT_DESTINATION, TEST_GW_AGENT_TABLE,
                                priority: TEST_GW_AGENT_PRIORITY, timeout: 60)
    end
  end

  it "removes the rule, the routes and the set entry when the VipGateway is deleted" do
    result = kubectl_apply(IntegrationTest.vip_gateway_yaml(
      name: TEST_GW_REMOVAL_NAME, destination_cidr: TEST_GW_REMOVAL_DESTINATION,
      route_table: TEST_GW_REMOVAL_TABLE, routing_priority: TEST_GW_REMOVAL_TABLE
    ))
    expect(result).to be_success, "Failed to create VipGateway: #{result.message}"
    nodes.each do |node|
      expect(wait_for_destination_rule(node, TEST_GW_REMOVAL_DESTINATION, TEST_GW_REMOVAL_TABLE))
        .to be(true), "Rule did not appear on #{node}"
      expect(wait_for_route(node, TEST_GW_REMOVAL_TABLE.to_s, TEST_GW_REMOVAL_DESTINATION, type: "unreachable"))
        .to be(true), "Fallback did not appear on #{node}"
      expect(wait_for_gateway_destination_entry(node, TEST_GW_REMOVAL_DESTINATION))
        .to be(true), "Set entry did not appear on #{node}"
    end

    kubectl_delete("vipgateway.#{IntegrationTest::API_GROUP}", TEST_GW_REMOVAL_NAME)

    nodes.each do |node|
      expect(wait_for_destination_rule_removal(node, TEST_GW_REMOVAL_DESTINATION, TEST_GW_REMOVAL_TABLE, timeout: 60))
        .to be(true), "Rule was not removed from #{node}"
      expect(wait_for_route_removal(node, TEST_GW_REMOVAL_TABLE.to_s, TEST_GW_REMOVAL_DESTINATION, timeout: 60))
        .to be(true), "Fallback was not removed from #{node}"
      expect(wait_for_gateway_destination_entry_removal(node, TEST_GW_REMOVAL_DESTINATION, timeout: 60))
        .to be(true), "Set entry was not removed from #{node}"
    end
  end

  it "leaves a foreign destination rule and its table alone through a full resync" do
    nodes.each do |node|
      result = kind_exec(node, "ip rule add from #{TEST_GW_FOREIGN_SOURCE} to #{TEST_GW_FOREIGN_DESTINATION} " \
                               "table #{TEST_GW_FOREIGN_TABLE} priority #{TEST_GW_FOREIGN_TABLE}")
      expect(result).to be_success, "Failed to add the foreign rule on #{node}: #{result.message}"
      result = kind_exec(node, "ip route add unreachable #{TEST_GW_FOREIGN_DESTINATION} table #{TEST_GW_FOREIGN_TABLE}")
      expect(result).to be_success, "Failed to add the foreign route on #{node}: #{result.message}"
    end

    # The agent reconciles at least every 30 seconds; an agent that took the
    # rule for its own would delete it and sweep its table in that time
    kept = holds_for? do
      nodes.all? do |node|
        ip_rules(node).any? do |rule|
          [rule["dst"], rule["dstlen"]].join("/") == TEST_GW_FOREIGN_DESTINATION && rule["table"] == TEST_GW_FOREIGN_TABLE.to_s
        end &&
          get_routes(node, TEST_GW_FOREIGN_TABLE.to_s).any?
      end
    end
    expect(kept).to be(true), "The foreign rule or its table's route was removed"

    # The agent's own rule was reconciled in the same time
    nodes.each do |node|
      expect(wait_for_destination_rule(node, TEST_GW_AGENT_DESTINATION, TEST_GW_AGENT_TABLE, timeout: 1))
        .to be(true), "Gateway rule missing on #{node}"
    end
  ensure
    @nodes.each do |node|
      kind_exec(node, "ip rule del from #{TEST_GW_FOREIGN_SOURCE} to #{TEST_GW_FOREIGN_DESTINATION} " \
                      "table #{TEST_GW_FOREIGN_TABLE} 2>/dev/null")
      kind_exec(node, "ip route flush table #{TEST_GW_FOREIGN_TABLE} 2>/dev/null")
    end
  end

  it "leaves a foreign blackhole route in a gateway table alone" do
    nodes.each do |node|
      expect(wait_for_route(node, TEST_GW_AGENT_TABLE.to_s, TEST_GW_AGENT_DESTINATION, type: "unreachable"))
        .to be(true), "Gateway fallback not found on #{node}"
      result = kind_exec(node, "ip route add blackhole #{TEST_GW_BLACKHOLE_DESTINATION} table #{TEST_GW_AGENT_TABLE}")
      expect(result).to be_success, "Failed to add the blackhole route on #{node}: #{result.message}"
    end

    kept = holds_for? do
      nodes.all? do |node|
        get_routes(node, TEST_GW_AGENT_TABLE.to_s).any? do |r|
          r[:type] == "blackhole" && r[:dst] == TEST_GW_BLACKHOLE_DESTINATION
        end
      end
    end
    expect(kept).to be(true), "The blackhole route was removed"

    # The agent did not even try: it never deletes a route type it does not add
    nodes.each do |node|
      expect(get_agent_logs(node, since: "60s")).not_to include("route #{TEST_GW_BLACKHOLE_DESTINATION} from table"),
                                                        "The agent tried to remove the blackhole route on #{node}"
    end
  ensure
    @nodes.each do |node|
      kind_exec(node, "ip route del blackhole #{TEST_GW_BLACKHOLE_DESTINATION} table #{TEST_GW_AGENT_TABLE} 2>/dev/null")
    end
  end

  it "keeps an overlapping destination in the set until both gateways are gone" do
    [[TEST_GW_WIDE_NAME, TEST_GW_WIDE_DESTINATION, TEST_GW_WIDE_TABLE],
     [TEST_GW_NARROW_NAME, TEST_GW_NARROW_DESTINATION, TEST_GW_NARROW_TABLE]].each do |name, destination, table|
      result = kubectl_apply(IntegrationTest.vip_gateway_yaml(
        name: name, destination_cidr: destination, route_table: table, routing_priority: table
      ))
      expect(result).to be_success, "Failed to create VipGateway #{name}: #{result.message}"
    end

    # The set merges the narrow destination into the wide one; each keeps its rule
    nodes.each do |node|
      expect(wait_for_destination_rule(node, TEST_GW_WIDE_DESTINATION, TEST_GW_WIDE_TABLE))
        .to be(true), "Wide gateway rule did not appear on #{node}"
      expect(wait_for_destination_rule(node, TEST_GW_NARROW_DESTINATION, TEST_GW_NARROW_TABLE))
        .to be(true), "Narrow gateway rule did not appear on #{node}"
      expect(wait_for_gateway_destination_entry(node, TEST_GW_WIDE_DESTINATION))
        .to be(true), "Wide destination not in the set on #{node}"
    end

    kubectl_delete("vipgateway.#{IntegrationTest::API_GROUP}", TEST_GW_WIDE_NAME)

    # Refilling the set brings back the narrow destination on its own
    nodes.each do |node|
      expect(wait_for_gateway_destination_entry(node, TEST_GW_NARROW_DESTINATION, timeout: 60))
        .to be(true), "Narrow destination not in the set after the wide gateway went on #{node}"
      expect(get_gateway_destination_entries(node)).not_to include(TEST_GW_WIDE_DESTINATION)
      expect(wait_for_destination_rule_removal(node, TEST_GW_WIDE_DESTINATION, TEST_GW_WIDE_TABLE, timeout: 60))
        .to be(true), "Wide gateway rule was not removed from #{node}"
      expect(wait_for_destination_rule(node, TEST_GW_NARROW_DESTINATION, TEST_GW_NARROW_TABLE, timeout: 1))
        .to be(true), "Narrow gateway rule went with the wide one on #{node}"
    end

    kubectl_delete("vipgateway.#{IntegrationTest::API_GROUP}", TEST_GW_NARROW_NAME)

    nodes.each do |node|
      expect(wait_for_gateway_destination_entry_removal(node, TEST_GW_NARROW_DESTINATION, timeout: 60))
        .to be(true), "Narrow destination stayed in the set on #{node}"
      expect(get_gateway_destination_entries(node)).to include(TEST_GW_AGENT_DESTINATION),
                                                       "The remaining gateway lost its set entry on #{node}"
    end
  ensure
    kubectl("delete vipgateways.#{IntegrationTest::API_GROUP} #{TEST_GW_WIDE_NAME} #{TEST_GW_NARROW_NAME} --ignore-not-found")
  end

  it "refuses a gateway on the node network" do
    node = nodes.first
    node_network = discover_network_cidr(node, "eth0")
    result = kubectl_apply(IntegrationTest.vip_gateway_yaml(
      name: TEST_GW_REFUSED_NAME, destination_cidr: node_network,
      route_table: TEST_GW_REFUSED_TABLE, routing_priority: TEST_GW_REFUSED_TABLE
    ))
    expect(result).to be_success, "Failed to create VipGateway: #{result.message}"

    # Every kind node is on the same network, so every agent refuses the gateway
    refusal = "ERROR - netwrangler.agent.agent_hook: Refusing VipGateway #{TEST_GW_REFUSED_NAME}"
    nodes.each do |each_node|
      refused = 20.times.any? do
        next true if get_agent_logs(each_node, since: "90s").include?(refusal)

        sleep 3
        false
      end
      expect(refused).to be(true), "Agent on #{each_node} did not log the refusal as an error"

      rules = get_destination_rules(each_node).select { |r| r[:table] == TEST_GW_REFUSED_TABLE }
      expect(rules).to be_empty, "Refused gateway got a rule on #{each_node}"
      expect(get_gateway_destination_entries(each_node)).not_to include(node_network)
      expect(get_gateway_destination_entries(each_node)).to include(TEST_GW_AGENT_DESTINATION),
                                                            "The applied gateway lost its set entry on #{each_node}"
    end

    # The pod matches both gateways, so it gets a VipRoute for each
    create_gateway_pod("gw-pod-1", node_name: node)
    expect(wait_for_vip_routes(namespace: namespace, count: 2)).not_to be_nil, "Expected a VipRoute per gateway"
    nodes.each do |each_node|
      expect(wait_for_route(each_node, TEST_GW_AGENT_TABLE.to_s, TEST_GW_AGENT_DESTINATION, type: "unicast"))
        .to be(true), "Pod route of the applied gateway not found on #{each_node}"
    end

    # Through a full resync the applied gateway keeps its pod route and the
    # refused one gets none
    held = holds_for? do
      nodes.all? do |each_node|
        get_routes(each_node, TEST_GW_REFUSED_TABLE.to_s).empty? &&
          get_routes(each_node, TEST_GW_AGENT_TABLE.to_s).any? { |r| r[:type] == "unicast" }
      end
    end
    expect(held).to be(true), "Refused gateway got routes, or the applied one lost its pod route"
  ensure
    kubectl("delete vipgateways.#{IntegrationTest::API_GROUP} #{TEST_GW_REFUSED_NAME} --ignore-not-found")
  end
end
