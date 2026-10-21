# frozen_string_literal: true

require_relative "../spec_helper"

TEST_NFT_VERSIONS_NAMESPACE = "vip-nft-versions-test"
TEST_NFT_VERSIONS_NETWORK = "vip-nft-versions-test"
TEST_NFT_VERSIONS_INTERFACE = "eth0"
TEST_NFT_VERSIONS_FIREWALL_MARK = 0x040000
TEST_NFT_VERSIONS_FIREWALL_MARK_MASK = 0xFF0000
TEST_NFT_VERSIONS_ROUTE_TABLE = 10_900
TEST_NFT_VERSIONS_PRIORITY = 10_900
TEST_NFT_BUILDS_DIRECTORY = "/usr/local/sbin"

RSpec.describe "Agent nft builds" do
  include IntegrationTest::KindHelper

  let(:namespace) { TEST_NFT_VERSIONS_NAMESPACE }

  before(:all) do
    extend IntegrationTest::KubectlHelper
    extend IntegrationTest::KindHelper

    @nodes = get_node_names
    raise "No nodes found in cluster" if @nodes.empty?

    @node = @nodes.first
    gateway_ip = discover_gateway(@node)
    @network_prefix = discover_network_prefix(@node, TEST_NFT_VERSIONS_INTERFACE)
    @vip_address = generate_test_vip_addresses(gateway_ip, count: 1).first

    listing = agent_exec(@node, "ls #{TEST_NFT_BUILDS_DIRECTORY}")
    raise "Failed to list the agent's tools: #{listing.message}" unless listing.success?

    @nft_versions = listing.message.lines.map(&:strip).grep(%r{\Anft-[0-9.]+\z}).map { |name| name.delete_prefix("nft-") }
    @nft_versions.sort_by! { |version| Gem::Version.new(version) }

    delete_namespace(TEST_NFT_VERSIONS_NAMESPACE)
    result = create_namespace(TEST_NFT_VERSIONS_NAMESPACE)
    raise "Failed to create namespace: #{result.message}" unless result.success?

    network_yaml = IntegrationTest.network_yaml(
      name: TEST_NFT_VERSIONS_NETWORK,
      interface: TEST_NFT_VERSIONS_INTERFACE,
      gateway_ip: gateway_ip,
      network_cidr: discover_network_cidr(@node, TEST_NFT_VERSIONS_INTERFACE)
    )
    result = kubectl_apply(network_yaml)
    raise "Failed to create VipNetwork: #{result.message}" unless result.success?

    config_yaml = IntegrationTest.vip_config_yaml(
      name: "default",
      firewall_mark: TEST_NFT_VERSIONS_FIREWALL_MARK,
      firewall_mark_mask: TEST_NFT_VERSIONS_FIREWALL_MARK_MASK,
      route_table: TEST_NFT_VERSIONS_ROUTE_TABLE,
      routing_priority: TEST_NFT_VERSIONS_PRIORITY
    )
    result = kubectl_apply(config_yaml)
    raise "Failed to create VipConfig: #{result.message}" unless result.success?
  end

  after(:all) do
    extend IntegrationTest::KubectlHelper
    extend IntegrationTest::KindHelper

    delete_namespace(TEST_NFT_VERSIONS_NAMESPACE)
    kubectl("delete vipnetworks.#{IntegrationTest::API_GROUP} #{TEST_NFT_VERSIONS_NETWORK} --ignore-not-found")
    kubectl("delete vipconfigs.#{IntegrationTest::API_GROUP} default --ignore-not-found")

    get_node_names.each do |node|
      cleanup_mangle_table(node)
      cleanup_fwmark_rules(node)
      cleanup_vip_addresses(node, TEST_NFT_VERSIONS_INTERFACE)
    end
  end

  after do
    kubectl("delete vipaddresses.#{IntegrationTest::API_GROUP} --all --namespace=#{namespace} --ignore-not-found")
    wait_for_map_entry_removal(@node, "ingress-marks-ipv4", @vip_address, timeout: 30)
  end

  # Creates a VipAddress on the node and waits for its map entry, which the
  # agent can only write by running nft
  def reconcile_vip_address(name)
    yaml = IntegrationTest.vip_address_yaml(
      name: name,
      namespace: namespace,
      network: TEST_NFT_VERSIONS_NETWORK,
      node_name: @node,
      virtual_cidr: "#{@vip_address}/#{@network_prefix}",
      interface: TEST_NFT_VERSIONS_INTERFACE,
      firewall_mark: TEST_NFT_VERSIONS_FIREWALL_MARK,
      ports: [{ protocol: "TCP", port: 80 }]
    )
    result = kubectl_apply(yaml)
    expect(result).to be_success, "Failed to create VipAddress: #{result.message}"

    expect(wait_for_map_entry(@node, "ingress-marks-ipv4", @vip_address, TEST_NFT_VERSIONS_FIREWALL_MARK, timeout: 30))
      .to be(true), "Map entry for #{@vip_address} did not appear on #{@node}"
  end

  it "bundles several nft builds named nft-<version>" do
    expect(@nft_versions.size).to be > 1, "Expected several nft builds, found #{@nft_versions.inspect}"
  end

  it "bundles builds that report the version they are named after" do
    @nft_versions.each do |version|
      result = agent_exec(@node, "#{TEST_NFT_BUILDS_DIRECTORY}/nft-#{version} --version")

      expect(result).to be_success, "nft-#{version} failed: #{result.message}"
      expect(result.message).to include("nftables v#{version} ")
    end
  end

  it "runs the latest build by default" do
    reconcile_vip_address("test-nft-latest")

    expect(get_agent_logs(@node, since: "120s"))
      .to include("Running nft as #{TEST_NFT_BUILDS_DIRECTORY}/nft-#{@nft_versions.last}")
  end

  context "with NETWRANGLER_NFT_VERSION set to the oldest build" do
    before(:all) do
      result = helmfile("sync --set agent.nftVersion=#{@nft_versions.first}")
      raise "Failed to deploy the agent with nft #{@nft_versions.first}: #{result.message}" unless result.success?

      wait_for_daemonset_ready(
        "netwrangler-agent",
        namespace: IntegrationTest::CONTROLLER_NAMESPACE,
        timeout: 120
      ) || raise("Agent DaemonSet not ready with nft #{@nft_versions.first}")
    end

    after(:all) do
      result = helmfile_apply
      raise "Failed to restore the latest nft: #{result.message}" unless result.success?

      wait_for_daemonset_ready(
        "netwrangler-agent",
        namespace: IntegrationTest::CONTROLLER_NAMESPACE,
        timeout: 120
      ) || raise("Agent DaemonSet not ready after restoring the latest nft")
    end

    it "reconciles a VipAddress with the selected build" do
      reconcile_vip_address("test-nft-oldest")

      expect(get_agent_logs(@node, since: "120s"))
        .to include("Running nft as #{TEST_NFT_BUILDS_DIRECTORY}/nft-#{@nft_versions.first}")
    end
  end
end
