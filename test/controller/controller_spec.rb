# frozen_string_literal: true

require_relative "../spec_helper"

# Use a single namespace and network for all tests
TEST_NAMESPACE = "vip-controller-test"
TEST_NETWORK_NAME = "vip-controller-test"

RSpec.describe "VipAddress Controller" do
  let(:namespace) { TEST_NAMESPACE }
  let(:network_name) { TEST_NETWORK_NAME }
  let(:nodes) { get_node_names }

  # VipAddress now stores virtualCIDR with prefix (e.g., "10.0.1.10/24")
  # Helper to add default network prefix for comparisons
  def with_prefix(ip, prefix: 24)
    "#{ip}/#{prefix}"
  end

  before(:all) do
    # Clean up leftovers from previous runs, then create test namespace
    extend IntegrationTest::KubectlHelper

    delete_namespace(TEST_NAMESPACE)
    kubectl("delete vipnetworks.#{IntegrationTest::API_GROUP} #{TEST_NETWORK_NAME} --ignore-not-found")

    result = create_namespace(TEST_NAMESPACE)
    raise "Failed to create namespace: #{result.message}" unless result.success?

    # Create VipNetwork once for all tests
    network_yaml = IntegrationTest.network_yaml(
      name: TEST_NETWORK_NAME
    )
    result = kubectl_apply(network_yaml)
    raise "Failed to create network: #{result.message}" unless result.success?

    # Create VipConfig once for all tests (marks, route table, routing preference are global)
    config_yaml = IntegrationTest.vip_config_yaml(
      name: "default",
      firewall_mark: 0x010000,
      firewall_mark_mask: 0xFF0000,
      route_table: 10_000,
      routing_priority: 10_000
    )
    result = kubectl_apply(config_yaml)
    raise "Failed to create VipConfig: #{result.message}" unless result.success?
  end

  after(:all) do
    extend IntegrationTest::KubectlHelper

    # Clean up namespace (this will delete all resources in it)
    delete_namespace(TEST_NAMESPACE)

    # Clean up cluster-scoped resources
    kubectl_delete("vipnetwork.#{IntegrationTest::API_GROUP}", TEST_NETWORK_NAME)
    kubectl("delete vipconfigs.#{IntegrationTest::API_GROUP} default --ignore-not-found")
  end

  after do
    # Clean up pods and services after each test
    kubectl("delete pods --all --namespace=#{namespace} --ignore-not-found")
    kubectl("delete services --all --namespace=#{namespace} --ignore-not-found")
    kubectl("delete vipaddresses.#{IntegrationTest::API_GROUP} --all --namespace=#{namespace} --ignore-not-found")

    # Wait for resources to be cleaned up
    sleep 2
  end

  # Helper to create a pod and wait for it to be ready
  def create_pod(name, node_name: nil, ready: true)
    yaml = IntegrationTest.pod_yaml(
      name: name,
      namespace: namespace,
      node_name: node_name,
      ready: ready
    )
    result = kubectl_apply(yaml)
    expect(result).to be_success, "Failed to create pod #{name}: #{result.message}"

    if ready
      expect(wait_for_pod_ready(name, namespace: namespace, timeout: 60))
        .to be(true), "Pod #{name} did not become ready"
    else
      expect(wait_for_pod_running(name, namespace: namespace, timeout: 60))
        .to be(true), "Pod #{name} did not start running"
    end
  end

  # Helper to create a service with virtual IPs
  def create_service(name, vip_addresses:, external_traffic_policy: "Local")
    yaml = IntegrationTest.service_yaml(
      name: name,
      namespace: namespace,
      vip_addresses: vip_addresses,
      external_traffic_policy: external_traffic_policy
    )
    result = kubectl_apply(yaml)
    expect(result).to be_success, "Failed to create service #{name}: #{result.message}"
  end

  describe "basic functionality" do
    context "with 1 node, 1 IP, 1 endpoint" do
      it "creates VipAddress resource for the endpoint" do
        node = nodes.first
        vip_address = "10.0.1.10"

        create_pod("pod-1", node_name: node)
        create_service("test-svc", vip_addresses: [vip_address])

        # Wait for VipAddress resource to be created
        items = wait_for_vip_addresses(namespace: namespace, count: 1, timeout: 30)
        expect(items).not_to be_nil, "VipAddress resources were not created"
        expect(items.length).to eq(1)

        # Verify the VipAddress details
        ext_ip = items.first
        expect(ext_ip.dig("spec", "virtualCIDR")).to eq(with_prefix(vip_address))
        expect(ext_ip.dig("spec", "nodeName")).to eq(node)
        expect(ext_ip.dig("spec", "network")).to eq(network_name)
      end
    end

    context "with 1 node, 2 IPs, 1 endpoint" do
      it "creates VipAddress resources for both IPs on the same node" do
        node = nodes.first
        vip_addresses = ["10.0.1.10", "10.0.1.11"]

        create_pod("pod-1", node_name: node)
        create_service("test-svc", vip_addresses: vip_addresses)

        # Wait for both VipAddress resources
        items = wait_for_vip_addresses(namespace: namespace, count: 2, timeout: 30)
        expect(items).not_to be_nil, "VipAddress resources were not created"
        expect(items.length).to eq(2)

        # Both IPs should be on the same node
        ips = items.map { |i| i.dig("spec", "virtualCIDR") }.sort
        nodes_used = items.map { |i| i.dig("spec", "nodeName") }.uniq

        expect(ips).to eq(vip_addresses.map { |ip| with_prefix(ip) }.sort)
        expect(nodes_used).to eq([node])
      end
    end

    context "with 2 nodes, 1 IP, 2 endpoints" do
      it "creates one VipAddress resource assigned to one of the nodes" do
        node1, node2 = nodes.take(2)
        vip_address = "10.0.1.10"

        create_pod("pod-1", node_name: node1)
        create_pod("pod-2", node_name: node2)
        create_service("test-svc", vip_addresses: [vip_address])

        # Wait for VipAddress resource
        items = wait_for_vip_addresses(namespace: namespace, count: 1, timeout: 30)
        expect(items).not_to be_nil, "VipAddress resources were not created"
        expect(items.length).to eq(1)

        # IP should be on one of the nodes with endpoints
        ext_ip = items.first
        expect(ext_ip.dig("spec", "virtualCIDR")).to eq(with_prefix(vip_address))
        expect([node1, node2]).to include(ext_ip.dig("spec", "nodeName"))
      end
    end

    context "with 2 nodes, 2 IPs, 2 endpoints" do
      it "distributes VipAddress resources across nodes" do
        node1, node2 = nodes.take(2)
        vip_addresses = ["10.0.1.10", "10.0.1.11"]

        create_pod("pod-1", node_name: node1)
        create_pod("pod-2", node_name: node2)
        create_service("test-svc", vip_addresses: vip_addresses)

        # Wait for both VipAddress resources
        items = wait_for_vip_addresses(namespace: namespace, count: 2, timeout: 30)
        expect(items).not_to be_nil, "VipAddress resources were not created"
        expect(items.length).to eq(2)

        # IPs should be distributed across nodes
        ips = items.map { |i| i.dig("spec", "virtualCIDR") }.sort
        nodes_used = items.map { |i| i.dig("spec", "nodeName") }.sort

        expect(ips).to eq(vip_addresses.map { |ip| with_prefix(ip) }.sort)
        expect(nodes_used).to eq([node1, node2].sort)
      end
    end

    context "with 3 nodes, 3 IPs, 3 endpoints" do
      it "distributes VipAddress resources across all nodes" do
        skip "Cluster has fewer than 3 nodes" if nodes.length < 3

        node1, node2, node3 = nodes.take(3)
        vip_addresses = ["10.0.1.10", "10.0.1.11", "10.0.1.12"]

        create_pod("pod-1", node_name: node1)
        create_pod("pod-2", node_name: node2)
        create_pod("pod-3", node_name: node3)
        create_service("test-svc", vip_addresses: vip_addresses)

        # Wait for all VipAddress resources
        items = wait_for_vip_addresses(namespace: namespace, count: 3, timeout: 30)
        expect(items).not_to be_nil, "VipAddress resources were not created"
        expect(items.length).to eq(3)

        # IPs should be distributed across all 3 nodes
        ips = items.map { |i| i.dig("spec", "virtualCIDR") }.sort
        nodes_used = items.map { |i| i.dig("spec", "nodeName") }.sort

        expect(ips).to eq(vip_addresses.map { |ip| with_prefix(ip) }.sort)
        expect(nodes_used).to eq([node1, node2, node3].sort)
      end
    end
  end

  describe "more IPs than endpoints" do
    context "with 1 node, 3 IPs, 1 endpoint" do
      it "assigns all IPs to the single node with endpoint" do
        node = nodes.first
        vip_addresses = ["10.0.1.10", "10.0.1.11", "10.0.1.12"]

        create_pod("pod-1", node_name: node)
        create_service("test-svc", vip_addresses: vip_addresses)

        # Wait for all VipAddress resources
        items = wait_for_vip_addresses(namespace: namespace, count: 3, timeout: 30)
        expect(items).not_to be_nil, "VipAddress resources were not created"
        expect(items.length).to eq(3)

        # All IPs should be on the same node
        ips = items.map { |i| i.dig("spec", "virtualCIDR") }.sort
        nodes_used = items.map { |i| i.dig("spec", "nodeName") }.uniq

        expect(ips).to eq(vip_addresses.map { |ip| with_prefix(ip) }.sort)
        expect(nodes_used).to eq([node])
      end
    end

    context "with 2 nodes, 4 IPs, 2 endpoints" do
      it "distributes IPs evenly across nodes with endpoints" do
        node1, node2 = nodes.take(2)
        vip_addresses = ["10.0.1.10", "10.0.1.11", "10.0.1.12", "10.0.1.13"]

        create_pod("pod-1", node_name: node1)
        create_pod("pod-2", node_name: node2)
        create_service("test-svc", vip_addresses: vip_addresses)

        # Wait for all VipAddress resources
        items = wait_for_vip_addresses(namespace: namespace, count: 4, timeout: 30)
        expect(items).not_to be_nil, "VipAddress resources were not created"
        expect(items.length).to eq(4)

        # IPs should be distributed across nodes
        ips = items.map { |i| i.dig("spec", "virtualCIDR") }.sort
        expect(ips).to eq(vip_addresses.map { |ip| with_prefix(ip) }.sort)

        # Each node should have 2 IPs
        node1_ips = items.select { |i| i.dig("spec", "nodeName") == node1 }
        node2_ips = items.select { |i| i.dig("spec", "nodeName") == node2 }

        expect(node1_ips.length).to eq(2)
        expect(node2_ips.length).to eq(2)
      end
    end
  end

  describe "more endpoints than IPs" do
    context "with 3 nodes, 1 IP, 3 endpoints" do
      it "assigns the single IP to one of the nodes" do
        skip "Cluster has fewer than 3 nodes" if nodes.length < 3

        node1, node2, node3 = nodes.take(3)
        vip_address = "10.0.1.10"

        create_pod("pod-1", node_name: node1)
        create_pod("pod-2", node_name: node2)
        create_pod("pod-3", node_name: node3)
        create_service("test-svc", vip_addresses: [vip_address])

        # Wait for VipAddress resource
        items = wait_for_vip_addresses(namespace: namespace, count: 1, timeout: 30)
        expect(items).not_to be_nil, "VipAddress resources were not created"
        expect(items.length).to eq(1)

        # IP should be on one of the nodes
        ext_ip = items.first
        expect(ext_ip.dig("spec", "virtualCIDR")).to eq(with_prefix(vip_address))
        expect([node1, node2, node3]).to include(ext_ip.dig("spec", "nodeName"))
      end
    end

    context "with 3 nodes, 2 IPs, 3 endpoints" do
      it "assigns IPs to 2 of the 3 nodes" do
        skip "Cluster has fewer than 3 nodes" if nodes.length < 3

        node1, node2, node3 = nodes.take(3)
        vip_addresses = ["10.0.1.10", "10.0.1.11"]

        create_pod("pod-1", node_name: node1)
        create_pod("pod-2", node_name: node2)
        create_pod("pod-3", node_name: node3)
        create_service("test-svc", vip_addresses: vip_addresses)

        # Wait for VipAddress resources
        items = wait_for_vip_addresses(namespace: namespace, count: 2, timeout: 30)
        expect(items).not_to be_nil, "VipAddress resources were not created"
        expect(items.length).to eq(2)

        # IPs should be on 2 different nodes
        ips = items.map { |i| i.dig("spec", "virtualCIDR") }.sort
        nodes_used = items.map { |i| i.dig("spec", "nodeName") }.uniq

        expect(ips).to eq(vip_addresses.map { |ip| with_prefix(ip) }.sort)
        expect(nodes_used.length).to eq(2)
        expect([node1, node2, node3]).to include(*nodes_used)
      end
    end
  end

  describe "endpoint readiness" do
    context "with not-ready endpoints" do
      it "does not create VipAddress resources for not-ready endpoints" do
        node = nodes.first
        vip_address = "10.0.1.10"

        # Create a pod that will never be ready
        create_pod("pod-1", node_name: node, ready: false)
        create_service("test-svc", vip_addresses: [vip_address])

        # Wait a bit and verify no VipAddress is created
        sleep 5
        items = get_vip_addresses(namespace: namespace)
        expect(items).to be_empty, "VipAddress should not be created for not-ready endpoint"
      end
    end

    context "with mixed ready and not-ready endpoints" do
      it "only creates VipAddress on the node with ready endpoint" do
        node1, node2 = nodes.take(2)
        vip_address = "10.0.1.10"

        # Pod on node1 is ready, pod on node2 is not
        create_pod("pod-1", node_name: node1, ready: true)
        create_pod("pod-2", node_name: node2, ready: false)
        create_service("test-svc", vip_addresses: [vip_address])

        # Wait for VipAddress resource
        items = wait_for_vip_addresses(namespace: namespace, count: 1, timeout: 30)
        expect(items).not_to be_nil, "VipAddress resources were not created"
        expect(items.length).to eq(1)

        # IP should be on the node with the ready endpoint
        ext_ip = items.first
        expect(ext_ip.dig("spec", "virtualCIDR")).to eq(with_prefix(vip_address))
        expect(ext_ip.dig("spec", "nodeName")).to eq(node1)
      end
    end
  end

  describe "endpoint changes" do
    context "when adding a new endpoint" do
      it "rebalances IPs across nodes" do
        node1, node2 = nodes.take(2)
        vip_addresses = ["10.0.1.10", "10.0.1.11"]

        # Start with one pod - all IPs go to node1
        create_pod("pod-1", node_name: node1)
        create_service("test-svc", vip_addresses: vip_addresses)

        # All IPs should be on node1 initially
        items = wait_for_vip_addresses(namespace: namespace, count: 2, timeout: 30)
        expect(items).not_to be_nil
        nodes_used = items.map { |i| i.dig("spec", "nodeName") }.uniq
        expect(nodes_used).to eq([node1])

        # Add a second pod on node2
        create_pod("pod-2", node_name: node2)

        # Wait for rebalancing - IPs should be distributed across both nodes
        sleep 5
        items = get_vip_addresses(namespace: namespace)
        expect(items.length).to eq(2)

        # IPs should now be distributed across both nodes
        nodes_used = items.map { |i| i.dig("spec", "nodeName") }.sort
        expect(nodes_used).to eq([node1, node2].sort)
      end
    end

    context "when removing an endpoint" do
      it "moves IPs from removed node to remaining nodes" do
        node1, node2 = nodes.take(2)
        vip_addresses = ["10.0.1.10", "10.0.1.11"]

        # Start with two pods
        create_pod("pod-1", node_name: node1)
        create_pod("pod-2", node_name: node2)
        create_service("test-svc", vip_addresses: vip_addresses)

        # IPs should be distributed
        items = wait_for_vip_addresses(namespace: namespace, count: 2, timeout: 30)
        expect(items).not_to be_nil
        nodes_used = items.map { |i| i.dig("spec", "nodeName") }.sort
        expect(nodes_used).to eq([node1, node2].sort)

        # Remove pod on node2
        delete_pod("pod-2", namespace: namespace)

        # Wait for IPs to move to node1
        sleep 5
        items = get_vip_addresses(namespace: namespace)
        expect(items.length).to eq(2)

        nodes_used = items.map { |i| i.dig("spec", "nodeName") }.uniq
        expect(nodes_used).to eq([node1])
      end
    end

    context "when endpoint becomes not ready" do
      it "moves IPs from not-ready node to ready nodes" do
        node1, node2 = nodes.take(2)
        vip_addresses = ["10.0.1.10", "10.0.1.11"]

        # Start with two ready pods
        create_pod("pod-1", node_name: node1, ready: true)
        create_pod("pod-2", node_name: node2, ready: true)
        create_service("test-svc", vip_addresses: vip_addresses)

        # IPs should be distributed
        items = wait_for_vip_addresses(namespace: namespace, count: 2, timeout: 30)
        expect(items).not_to be_nil
        nodes_used = items.map { |i| i.dig("spec", "nodeName") }.sort
        expect(nodes_used).to eq([node1, node2].sort)

        # Delete pod-2 and recreate as not-ready
        delete_pod("pod-2", namespace: namespace)
        sleep 2
        create_pod("pod-2-notready", node_name: node2, ready: false)

        # Wait for IPs to move to node1
        sleep 5
        items = get_vip_addresses(namespace: namespace)
        expect(items.length).to eq(2)

        nodes_used = items.map { |i| i.dig("spec", "nodeName") }.uniq
        expect(nodes_used).to eq([node1])
      end
    end
  end

  describe "service deletion" do
    it "cleans up all VipAddress resources when service is deleted" do
      node1, node2 = nodes.take(2)
      vip_addresses = ["10.0.1.10", "10.0.1.11"]

      create_pod("pod-1", node_name: node1)
      create_pod("pod-2", node_name: node2)
      create_service("test-svc", vip_addresses: vip_addresses)

      # Verify VipAddresses are created
      items = wait_for_vip_addresses(namespace: namespace, count: 2, timeout: 30)
      expect(items).not_to be_nil
      expect(items.length).to eq(2)

      # Delete the service
      result = kubectl_delete("service", "test-svc", namespace: namespace)
      expect(result).to be_success

      # Verify VipAddresses are cleaned up
      cleaned = wait_for_vip_addresses_cleanup(namespace: namespace, timeout: 30)
      expect(cleaned).to be(true), "VipAddress resources were not cleaned up"
    end
  end

  describe "pods on same node" do
    context "with multiple pods on the same node" do
      it "creates VipAddress on the node with all endpoints" do
        node = nodes.first
        vip_address = "10.0.1.10"

        # Create multiple pods on the same node
        create_pod("pod-1", node_name: node)
        create_pod("pod-2", node_name: node)
        create_service("test-svc", vip_addresses: [vip_address])

        # Wait for VipAddress resource
        items = wait_for_vip_addresses(namespace: namespace, count: 1, timeout: 30)
        expect(items).not_to be_nil, "VipAddress resources were not created"
        expect(items.length).to eq(1)

        # IP should be on the node
        ext_ip = items.first
        expect(ext_ip.dig("spec", "virtualCIDR")).to eq(with_prefix(vip_address))
        expect(ext_ip.dig("spec", "nodeName")).to eq(node)
      end
    end
  end

  describe "resource naming" do
    context "with a single VipAddress" do
      it "names VipAddress as {serviceName}-{index}" do
        node = nodes.first
        vip_address = "10.0.1.10"

        create_pod("pod-1", node_name: node)
        create_service("test-svc", vip_addresses: [vip_address])

        items = wait_for_vip_addresses(namespace: namespace, count: 1, timeout: 30)
        expect(items).not_to be_nil
        ext_ip = items.first

        expect(ext_ip.dig("metadata", "name")).to eq("test-svc-1")
        expect(ext_ip.dig("metadata", "namespace")).to eq(namespace)
      end
    end

    context "with multiple VipAddresses" do
      it "assigns unique sequential names" do
        node = nodes.first
        vip_addresses = ["10.0.1.10", "10.0.1.11"]

        create_pod("pod-1", node_name: node)
        create_service("test-svc", vip_addresses: vip_addresses)

        items = wait_for_vip_addresses(namespace: namespace, count: 2, timeout: 30)
        expect(items).not_to be_nil

        names = items.map { |i| i.dig("metadata", "name") }.sort
        expect(names).to eq(["test-svc-1", "test-svc-2"])
      end
    end
  end

  describe "mark allocation" do
    context "with VipConfig" do
      it "allocates firewallMark and routeTable" do
        node = nodes.first
        vip_address = "10.0.1.10"

        create_pod("pod-1", node_name: node)
        create_service("test-svc", vip_addresses: [vip_address])

        items = wait_for_vip_addresses(namespace: namespace, count: 1, timeout: 30)
        expect(items).not_to be_nil
        ext_ip = items.first

        expect(ext_ip.dig("spec", "firewallMark")).not_to be_nil
        expect(ext_ip.dig("spec", "routeTable")).not_to be_nil
        expect(ext_ip.dig("spec", "routingPriority")).not_to be_nil
      end
    end
  end

  describe "external traffic policy" do
    it "creates VipAddress for service without externalTrafficPolicy=Local" do
      node = nodes.first
      vip_address = "10.0.1.10"

      create_pod("pod-1", node_name: node)
      create_service("test-svc", vip_addresses: [vip_address], external_traffic_policy: "Cluster")

      items = wait_for_vip_addresses(namespace: namespace, count: 1, timeout: 30)
      expect(items).not_to be_nil, "VipAddress should be created even with eTP=Cluster"
      expect(items.length).to eq(1)

      ext_ip = items.first
      expect(ext_ip.dig("spec", "virtualCIDR")).to eq(with_prefix(vip_address))
      expect(ext_ip.dig("spec", "nodeName")).to eq(node)
    end
  end

  describe "multi-network service" do
    # Create a second VipNetwork for this test group
    let(:second_network_name) { "vip-controller-test-2" }

    before do
      network_yaml = IntegrationTest.network_yaml(
        name: second_network_name,
        interface: "eth0",
        gateway_ip: "192.168.1.1",
        network_cidr: "192.168.1.0/24"
      )
      result = kubectl_apply(network_yaml)
      expect(result).to be_success, "Failed to create second network: #{result.message}"
    end

    after do
      kubectl("delete vipnetworks.#{IntegrationTest::API_GROUP} #{second_network_name} --ignore-not-found")
    end

    it "assigns IPs to correct networks when service spans two VipNetworks" do
      node = nodes.first
      vip_addresses = ["10.0.1.10", "192.168.1.10"]

      create_pod("pod-1", node_name: node)
      create_service("test-svc", vip_addresses: vip_addresses)

      items = wait_for_vip_addresses(namespace: namespace, count: 2, timeout: 30)
      expect(items).not_to be_nil, "VipAddress resources were not created"
      expect(items.length).to eq(2)

      # Verify each IP is associated with the correct network
      ip1 = items.find { |i| i.dig("spec", "virtualCIDR") == "10.0.1.10/24" }
      ip2 = items.find { |i| i.dig("spec", "virtualCIDR") == "192.168.1.10/24" }

      expect(ip1).not_to be_nil
      expect(ip1.dig("spec", "network")).to eq(network_name)

      expect(ip2).not_to be_nil
      expect(ip2.dig("spec", "network")).to eq(second_network_name)
    end
  end

  describe "overlapping VipNetworks" do
    let(:overlapping_network_name) { "vip-controller-overlap" }

    before do
      # Create a network that overlaps with the default test network (10.0.1.0/24)
      network_yaml = IntegrationTest.network_yaml(
        name: overlapping_network_name,
        interface: "eth0",
        gateway_ip: "10.0.0.1",
        network_cidr: "10.0.0.0/16"
      )
      result = kubectl_apply(network_yaml)
      expect(result).to be_success, "Failed to create overlapping network: #{result.message}"
    end

    after do
      kubectl("delete vipnetworks.#{IntegrationTest::API_GROUP} #{overlapping_network_name} --ignore-not-found")
    end

    it "disables overlapping network and sets error condition on affected service" do
      node = nodes.first

      # Use an IP only in the broader /16 range (not in the /24)
      create_pod("pod-1", node_name: node)
      create_service("test-svc", vip_addresses: ["10.0.2.10"])

      # Wait for the controller to process — the service should get an error
      # because 10.0.2.10 is only in the /16 network, which gets disabled
      condition = wait_for_service_condition("test-svc", namespace: namespace, type: "IpAllocated", timeout: 30)
      expect(condition).not_to be_nil, "IpAllocated condition was not set on service"
      expect(condition["status"]).to eq("False")
      expect(condition["message"]).to include("disabled")
    end
  end

  describe "VipConfig validation" do
    let(:config_values) do
      { name: "default", firewall_mark: 0x010000, firewall_mark_mask: 0xFF0000,
        route_table: 10_000, routing_priority: 10_000 }
    end

    after do
      kubectl_apply(IntegrationTest.vip_config_yaml(**config_values))
    end

    {
      firewall_mark: 0x020000,
      firewall_mark_mask: 0x7F0000,
      route_table: 11_000,
      routing_priority: 11_000,
    }.each do |field, value|
      it "rejects a change of #{field}" do
        result = kubectl_apply(IntegrationTest.vip_config_yaml(**config_values, field => value))

        expect(result).not_to be_success, "Changing #{field} was accepted"
        expect(result.message).to include("Value is immutable")
      end
    end

    it "accepts a change of maxAddressCount" do
      result = kubectl_apply(IntegrationTest.vip_config_yaml(**config_values, max_address_count: 128))

      expect(result).to be_success, "Changing maxAddressCount was rejected: #{result.message}"
    end
  end
end
