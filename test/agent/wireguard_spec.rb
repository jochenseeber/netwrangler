# frozen_string_literal: true

require_relative "../spec_helper"

TEST_WG_NAMESPACE = "vip-wg-test"
# The standing mesh `rake kind:wireguard` builds between the kind nodes
TEST_WG_INTERFACE = "wg-demo"
TEST_WG_DESTINATION = "192.168.99.0/24"
TEST_WG_TABLE = 10_700
TEST_WG_PRIORITY = 10_700
TEST_WG_POD_CIDR = "10.99.0.0/24"
TEST_WG_POD_IP = "10.99.0.10"
TEST_WG_GATEWAY = "wireguard-gateway"

RSpec.describe "WireGuard Agent" do
  include IntegrationTest::KindHelper

  let(:namespace) { TEST_WG_NAMESPACE }
  let(:nodes) { node_names }

  before(:all) do
    extend IntegrationTest::KubectlHelper
    extend IntegrationTest::KindHelper

    @nodes = node_names
    raise "Need at least 2 nodes" if @nodes.size < 2

    delete_namespace(TEST_WG_NAMESPACE)
    result = create_namespace(TEST_WG_NAMESPACE)
    raise "Failed to create namespace: #{result.message}" unless result.success?

    # The agent applies only the VipRoutes of a VipGateway it accepted. The
    # selector matches no pod, so the controller adds no VipRoute of its own.
    manifest = IntegrationTest.vip_gateway_yaml(
      name: TEST_WG_GATEWAY, destination_cidr: TEST_WG_DESTINATION,
      route_table: TEST_WG_TABLE, routing_priority: TEST_WG_PRIORITY,
      pod_selector_labels: { "app" => TEST_WG_GATEWAY }
    )
    result = kubectl_apply(manifest)
    raise "Failed to create VipGateway: #{result.message}" unless result.success?

    ready = wait_for_daemonset_ready(
      "netwrangler-agent",
      namespace: IntegrationTest::CONTROLLER_NAMESPACE,
      timeout: 120
    )
    raise "Agent DaemonSet not ready" unless ready

    # The mesh exists before the tests run (`kind:wireguard`). The agent finds
    # the gateway pod's peer by the pod network in its allowed IPs, so the
    # peer of the WG pod node's key on every other node gets the WG pod CIDR
    # in addition to what it has. The lists are put back afterwards.
    @wg_pod_node = @nodes.first
    @wg_pod_key = node_shell!(@wg_pod_node, "wg show #{TEST_WG_INTERFACE} public-key").strip
    @saved_allowed_ips = {}

    @nodes.each do |node|
      next if node == @wg_pod_node

      allowed = get_wireguard_allowed_ips(node, TEST_WG_INTERFACE, public_key: @wg_pod_key)
      raise "#{node} has no #{TEST_WG_INTERFACE} peer for #{@wg_pod_node}, run `rake kind:wireguard`" if allowed.empty?

      @saved_allowed_ips[node] = allowed
      set_wireguard_allowed_ips(node, TEST_WG_INTERFACE, public_key: @wg_pod_key,
                                                         allowed_ips: allowed + [TEST_WG_POD_CIDR])
      kind_exec(node, "ip route replace #{TEST_WG_POD_CIDR} dev #{TEST_WG_INTERFACE}")
    end

    # On the WG pod node, assign the WG pod IP to a dummy interface
    kind_exec(@wg_pod_node, "ip link add wg-dummy type dummy")
    kind_exec(@wg_pod_node, "ip link set wg-dummy up")
    kind_exec(@wg_pod_node, "ip addr add #{TEST_WG_POD_IP}/24 dev wg-dummy")
  end

  after(:all) do
    extend IntegrationTest::KubectlHelper
    extend IntegrationTest::KindHelper

    delete_namespace(TEST_WG_NAMESPACE)
    kubectl("delete vipgateways.#{IntegrationTest::API_GROUP} #{TEST_WG_GATEWAY} --ignore-not-found")
    # Restore the mesh's allowed IPs; the link itself stays
    @saved_allowed_ips&.each do |node, allowed|
      set_wireguard_allowed_ips(node, TEST_WG_INTERFACE, public_key: @wg_pod_key, allowed_ips: allowed)
    end
    @nodes&.each do |node|
      kind_exec(node, "ip link del wg-dummy 2>/dev/null")
      kind_exec(node, "ip route del #{TEST_WG_POD_CIDR} dev #{TEST_WG_INTERFACE} 2>/dev/null")
      cleanup_destination_rules(node)
    end
  end

  after do
    kubectl("delete viproutes.#{IntegrationTest::API_GROUP} --all --namespace=#{namespace} --ignore-not-found")
    sleep 2
  end

  # Create a VipRoute without managed-by label so the controller doesn't delete it
  def create_wg_vip_route(name)
    yaml = {
      "apiVersion" => "#{IntegrationTest::API_GROUP}/#{IntegrationTest::API_VERSION}",
      "kind" => "VipRoute",
      "metadata" => {
        "name" => name,
        "namespace" => namespace,
      },
      "spec" => {
        "destinationCIDR" => TEST_WG_DESTINATION,
        "gatewayNode" => @wg_pod_node,
        "podIP" => TEST_WG_POD_IP,
        "routeTable" => TEST_WG_TABLE,
        "routingPriority" => TEST_WG_PRIORITY,
      },
    }.to_yaml
    result = kubectl_apply(yaml)
    expect(result).to be_success, "Failed to create VipRoute: #{result.message}"
  end

  it "adds destination to WireGuard allowed IPs on remote nodes" do
    create_wg_vip_route("wg-route-1")

    pod_peer_key = @wg_pod_key

    remote_nodes = nodes.reject { |n| n == @wg_pod_node }
    remote_nodes.each do |node|
      expect(
        wait_for_wireguard_allowed_ip(
          node, TEST_WG_INTERFACE,
          public_key: pod_peer_key,
          ip: TEST_WG_DESTINATION
        )
      ).to be(true), "Destination not added to WG peer on #{node}"
    end
  end

  it "removes destination from WireGuard allowed IPs when VipRoute is deleted" do
    create_wg_vip_route("wg-route-1")

    pod_peer_key = @wg_pod_key
    remote_node = nodes.reject { |n| n == @wg_pod_node }.first

    expect(
      wait_for_wireguard_allowed_ip(
        remote_node, TEST_WG_INTERFACE,
        public_key: pod_peer_key,
        ip: TEST_WG_DESTINATION
      )
    ).to be(true), "Destination not added"

    kubectl_delete("viproute.#{IntegrationTest::API_GROUP}", "wg-route-1", namespace: namespace)

    expect(
      wait_for_wireguard_allowed_ip_removal(
        remote_node, TEST_WG_INTERFACE,
        public_key: pod_peer_key,
        ip: TEST_WG_DESTINATION,
        timeout: 60
      )
    ).to be(true), "Destination was not removed from WG peer on #{remote_node}"
  end

  # The pod IP is an address of the gateway pod's node, as for a gateway pod
  # on the host network, so that node reaches the destination itself
  it "sets up no gateway rule or route on the node the gateway pod runs on" do
    # Without a VipRoute the gateway has a rule there too, which goes once
    # the agent sees that the pod is local
    create_wg_vip_route("wg-route-1")
    expect(wait_for_destination_rule_removal(@wg_pod_node, TEST_WG_DESTINATION, TEST_WG_TABLE))
      .to be(true), "The agent on #{@wg_pod_node} kept the gateway rule"

    restarts = agent_restart_count(@wg_pod_node)
    untouched = holds_for? do
      get_destination_rules(@wg_pod_node).none? { |rule| rule[:table] == TEST_WG_TABLE } &&
        get_routes(@wg_pod_node, TEST_WG_TABLE.to_s).empty?
    end

    rules = get_destination_rules(@wg_pod_node).select { |rule| rule[:table] == TEST_WG_TABLE }
    routes = get_routes(@wg_pod_node, TEST_WG_TABLE.to_s)
    expect(untouched).to be(true), "#{@wg_pod_node} has rules #{rules} and routes #{routes} for the gateway"
    expect(agent_restart_count(@wg_pod_node)).to eq(restarts), "The agent on #{@wg_pod_node} restarted"
  end

  def agent_restart_count(node)
    kubectl_output("get pod #{agent_pod_on_node(node)} --namespace=#{IntegrationTest::CONTROLLER_NAMESPACE} " \
                   "--output=jsonpath='{.status.containerStatuses[0].restartCount}'").delete("'").to_i
  end
end
