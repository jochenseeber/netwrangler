# frozen_string_literal: true

require_relative "../spec_helper"

TEST_GW_NAMESPACE = "vip-gateway-test"
TEST_GW_NAME = "test-gateway"
TEST_GW_DESTINATION = "203.0.113.0/24"
TEST_GW_TABLE = 10_500
TEST_GW_PRIORITY = 10_500
TEST_GW_POD_LABELS = { "app" => "gateway", "netwrangler.dev/gateway" => "enabled" }.freeze

RSpec.describe "VipGateway Controller" do
  let(:namespace) { TEST_GW_NAMESPACE }
  let(:nodes) { get_node_names }

  before(:all) do
    extend IntegrationTest::KubectlHelper
    extend IntegrationTest::KindHelper

    delete_namespace(TEST_GW_NAMESPACE)
    kubectl("delete vipgateways.#{IntegrationTest::API_GROUP} #{TEST_GW_NAME} --ignore-not-found")

    result = create_namespace(TEST_GW_NAMESPACE)
    raise "Failed to create namespace: #{result.message}" unless result.success?

    # Wait for agent DaemonSet to be ready
    ready = wait_for_daemonset_ready(
      "netwrangler-agent",
      namespace: IntegrationTest::CONTROLLER_NAMESPACE,
      timeout: 120
    )
    raise "Agent DaemonSet not ready" unless ready

    gateway_yaml = IntegrationTest.vip_gateway_yaml(
      name: TEST_GW_NAME,
      destination_cidr: TEST_GW_DESTINATION,
      route_table: TEST_GW_TABLE,
      routing_priority: TEST_GW_PRIORITY,
      pod_selector_labels: { "app" => "gateway" }
    )
    result = kubectl_apply(gateway_yaml)
    raise "Failed to create VipGateway: #{result.message}" unless result.success?
  end

  after(:all) do
    extend IntegrationTest::KubectlHelper

    delete_namespace(TEST_GW_NAMESPACE)
    kubectl_delete("vipgateway.#{IntegrationTest::API_GROUP}", TEST_GW_NAME)
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
      labels: TEST_GW_POD_LABELS,
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

  it "creates VipRoutes for ready gateway Pods" do
    create_gateway_pod("gw-pod-1")

    routes = wait_for_vip_routes(namespace: namespace, count: 1)
    expect(routes).not_to be_nil, "Expected at least 1 VipRoute"

    route = routes.first
    expect(route.dig("spec", "destinationCIDR")).to eq(TEST_GW_DESTINATION)
    expect(route.dig("spec", "podIP")).not_to be_nil
    expect(route.dig("spec", "routeTable")).to eq(TEST_GW_TABLE)
    expect(route.dig("spec", "routingPriority")).to eq(TEST_GW_PRIORITY)
  end

  it "creates one VipRoute per Pod" do
    create_gateway_pod("gw-pod-1", node_name: nodes[0])
    create_gateway_pod("gw-pod-2", node_name: nodes.length > 1 ? nodes[1] : nodes[0])

    routes = wait_for_vip_routes(namespace: namespace, count: 2)
    expect(routes).not_to be_nil, "Expected at least 2 VipRoutes"
    expect(routes.length).to eq(2)

    pod_ips = routes.map { |r| r.dig("spec", "podIP") }
    expect(pod_ips.uniq.length).to eq(2), "Expected unique pod IPs"
  end

  it "sets podIP from the gateway Pod" do
    create_gateway_pod("gw-pod-1", node_name: nodes.first)

    routes = wait_for_vip_routes(namespace: namespace, count: 1)
    expect(routes).not_to be_nil

    route = routes.first
    pod_ip = route.dig("spec", "podIP")
    expect(pod_ip).not_to be_nil
    expect(pod_ip).to match(%r{\A\d+\.\d+\.\d+\.\d+\z})
  end

  it "cleans up VipRoutes when Pod is deleted" do
    create_gateway_pod("gw-pod-1")

    routes = wait_for_vip_routes(namespace: namespace, count: 1)
    expect(routes).not_to be_nil

    delete_pod("gw-pod-1", namespace: namespace)
    expect(wait_for_vip_routes_cleanup(namespace: namespace, timeout: 60)).to be(true),
                                                                              "VipRoutes were not cleaned up after pod deletion"
  end

  it "sets correct labels on VipRoutes" do
    create_gateway_pod("gw-pod-1")

    routes = wait_for_vip_routes(namespace: namespace, count: 1)
    expect(routes).not_to be_nil

    labels = routes.first.dig("metadata", "labels")
    expect(labels["netwrangler.dev/managed-by"]).to eq("netwrangler")
    expect(labels["netwrangler.dev/gateway"]).to eq(TEST_GW_NAME)
  end

  it "uses podName-gatewayName for VipRoute naming" do
    create_gateway_pod("gw-pod-1")

    routes = wait_for_vip_routes(namespace: namespace, count: 1)
    expect(routes).not_to be_nil

    route_name = routes.first.dig("metadata", "name")
    expect(route_name).to eq("gw-pod-1-#{TEST_GW_NAME}")
  end
end
