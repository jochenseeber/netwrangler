# frozen_string_literal: true

require_relative "../spec_helper"

# Test constants
TEST_NAMESPACE = "vip-agent-test"
TEST_NETWORK_NAME = "vip-agent-test"
TEST_INTERFACE = "eth0"
TEST_MANGLE_TABLE = "netwrangler"
TEST_ROUTE_TABLE = 10_200
TEST_FIREWALL_MARK = 0x010000
TEST_FIREWALL_MARK_MASK = 0xFF0000
TEST_ROUTING_POLICY_RULE_PRIORITY = 10_200
TEST_SERVICE_NAME = "test-service"
TEST_PRECEDENCE_GATEWAY = "agent-precedence"
# Not the gateway spec's destination, so the two suites never share one
TEST_PRECEDENCE_DESTINATION = "198.18.1.0/24"
TEST_PRECEDENCE_ADDRESS = "198.18.1.1"
TEST_PRECEDENCE_TABLE = 10_650
TEST_PRECEDENCE_PRIORITY = TEST_ROUTING_POLICY_RULE_PRIORITY - 1_000
# A gateway that shares the VIP route table, applied once the VIP leaves the node
TEST_SHARED_TABLE_GATEWAY = "agent-shared-table"
TEST_SHARED_TABLE_DESTINATION = "198.18.3.0/24"
TEST_SHARED_TABLE_PRIORITY = TEST_ROUTING_POLICY_RULE_PRIORITY - 500
TEST_RULE_EVENTS = "/tmp/netwrangler-shared-table-events"

RSpec.describe "VipAddress Agent" do
  include IntegrationTest::KindHelper

  let(:namespace) { TEST_NAMESPACE }
  let(:nodes) { get_node_names }

  before(:all) do
    extend IntegrationTest::KubectlHelper
    extend IntegrationTest::KindHelper

    # The controller only watches VipAddress resources with the managed-by label,
    # so test VipAddresses (created without that label) are safe from controller deletion.

    # Clean up leftover resources from previous test runs
    delete_namespace(TEST_NAMESPACE)

    @nodes = get_node_names
    raise "No nodes found in cluster" if @nodes.empty?

    # Discover network configuration from the first node
    @gateway_ip = discover_gateway(@nodes.first)
    @network_prefix = discover_network_prefix(@nodes.first, TEST_INTERFACE)
    @network_cidr = discover_network_cidr(@nodes.first, TEST_INTERFACE)
    @vip_addresses = generate_test_vip_addresses(@gateway_ip, count: 2)

    # Verify interface exists on all nodes
    @nodes.each do |node|
      raise "Interface #{TEST_INTERFACE} not found on node #{node}" unless interface_exists?(node, TEST_INTERFACE)
    end

    # Check nftables availability (may not be supported on all platforms)
    @nft_available = nft_available?(@nodes.first)

    # Create test namespace
    result = create_namespace(TEST_NAMESPACE)
    raise "Failed to create namespace: #{result.message}" unless result.success?

    # Create VipNetwork resource
    network_yaml = IntegrationTest.network_yaml(
      name: TEST_NETWORK_NAME,
      interface: TEST_INTERFACE,
      gateway_ip: @gateway_ip,
      network_cidr: @network_cidr
    )
    result = kubectl_apply(network_yaml)
    raise "Failed to create VipNetwork: #{result.message}" unless result.success?

    # Create VipConfig resource (marks, route table, routing preference are global)
    config_yaml = IntegrationTest.vip_config_yaml(
      name: "default",
      firewall_mark: TEST_FIREWALL_MARK,
      firewall_mark_mask: TEST_FIREWALL_MARK_MASK,
      route_table: TEST_ROUTE_TABLE,
      routing_priority: TEST_ROUTING_POLICY_RULE_PRIORITY
    )
    result = kubectl_apply(config_yaml)
    raise "Failed to create VipConfig: #{result.message}" unless result.success?

    # Wait for agent DaemonSet to be ready
    ready = wait_for_daemonset_ready(
      "netwrangler-agent",
      namespace: IntegrationTest::CONTROLLER_NAMESPACE,
      timeout: 120
    )
    raise "Agent DaemonSet not ready within timeout" unless ready
  end

  after(:all) do
    extend IntegrationTest::KubectlHelper
    extend IntegrationTest::KindHelper

    # Clean up namespace and cluster-scoped resources
    delete_namespace(TEST_NAMESPACE)
    kubectl("delete vipnetworks.#{IntegrationTest::API_GROUP} #{TEST_NETWORK_NAME} --ignore-not-found")
    kubectl("delete vipconfigs.#{IntegrationTest::API_GROUP} default --ignore-not-found")

    # Clean up infrastructure on all nodes
    nodes = get_node_names
    nodes.each do |node|
      cleanup_mangle_table(node)
      cleanup_fwmark_rules(node)
      cleanup_vip_addresses(node, TEST_INTERFACE)
    end
  end

  after do
    # Delete all VipAddress resources in test namespace
    kubectl(
      "delete vipaddresses.#{IntegrationTest::API_GROUP} " \
      "--all --namespace=#{namespace} --ignore-not-found"
    )

    # Wait for agent to process deletions and clean up VIPs
    nodes.each do |node|
      wait_for_vip_address_removal(node, TEST_INTERFACE, @vip_addresses[0], timeout: 10)
      wait_for_vip_address_removal(node, TEST_INTERFACE, @vip_addresses[1], timeout: 5)
    end
  end

  # Helper to create an VipAddress and apply it
  def create_vip_address(name, node_name:, virtual_cidr:, gateway_ip: nil,
                         firewall_mark: nil,
                         route_table: nil, routing_priority: nil,
                         egress_enabled: nil,
                         source_cidrs: [],
                         endpoint_ips: [], ports: [])
    # vipAddress now includes /prefix (e.g., "172.18.255.200/16")
    vip_address_with_prefix = "#{virtual_cidr}/#{@network_prefix}"

    yaml = IntegrationTest.vip_address_yaml(
      name: name,
      namespace: namespace,
      network: TEST_NETWORK_NAME,
      node_name: node_name,
      virtual_cidr: vip_address_with_prefix,
      interface: TEST_INTERFACE,
      gateway_ip: gateway_ip,
      firewall_mark: firewall_mark,
      route_table: route_table,
      routing_priority: routing_priority,
      egress_enabled: egress_enabled,
      source_cidrs: source_cidrs,
      endpoint_ips: endpoint_ips,
      ports: ports
    )
    result = kubectl_apply(yaml)
    expect(result).to be_success, "Failed to create VipAddress #{name}: #{result.message}"
  end

  describe "VIP addresses" do
    context "with a single VipAddress" do
      it "assigns VIP address to the correct node" do
        node = nodes.first
        ip = @vip_addresses[0]

        create_vip_address("test-vip-1", node_name: node, virtual_cidr: ip)

        expect(wait_for_vip_address(node, TEST_INTERFACE, ip, timeout: 30))
          .to be(true), "VIP #{ip} did not appear on #{node}"
      end
    end

    context "when a VIP is added" do
      it "sends a gratuitous ARP announcement" do
        node = nodes.first
        ip = @vip_addresses[0]

        create_vip_address("test-arp-announce", node_name: node, virtual_cidr: ip)

        expect(wait_for_vip_address(node, TEST_INTERFACE, ip, timeout: 30))
          .to be(true), "VIP #{ip} did not appear on #{node}"

        logs = get_agent_logs(node, since: "30s")
        expect(logs).to include("Sending ARP announcements for #{ip} on #{TEST_INTERFACE}"),
                        "Agent did not log ARP announcements for #{ip}"
      end
    end

    context "with multiple VipAddresses on the same node" do
      it "assigns all VIP addresses to the node" do
        node = nodes.first

        create_vip_address("test-vip-1", node_name: node, virtual_cidr: @vip_addresses[0])
        create_vip_address("test-vip-2",
                           node_name: node, virtual_cidr: @vip_addresses[1])

        expect(wait_for_vip_address(node, TEST_INTERFACE, @vip_addresses[0], timeout: 30))
          .to be(true), "VIP #{@vip_addresses[0]} did not appear on #{node}"
        expect(wait_for_vip_address(node, TEST_INTERFACE, @vip_addresses[1], timeout: 30))
          .to be(true), "VIP #{@vip_addresses[1]} did not appear on #{node}"
      end
    end

    context "with VipAddresses on different nodes" do
      it "assigns each VIP only to its assigned node" do
        skip "Cluster has fewer than 2 nodes" if nodes.length < 2

        node1, node2 = nodes.take(2)

        create_vip_address("test-vip-1", node_name: node1, virtual_cidr: @vip_addresses[0])
        create_vip_address("test-vip-2",
                           node_name: node2, virtual_cidr: @vip_addresses[1])

        expect(wait_for_vip_address(node1, TEST_INTERFACE, @vip_addresses[0], timeout: 30))
          .to be(true), "VIP #{@vip_addresses[0]} did not appear on #{node1}"
        expect(wait_for_vip_address(node2, TEST_INTERFACE, @vip_addresses[1], timeout: 30))
          .to be(true), "VIP #{@vip_addresses[1]} did not appear on #{node2}"

        # Verify VIPs are NOT on the wrong nodes
        expect(get_vip_addresses(node1, TEST_INTERFACE)).not_to include(@vip_addresses[1])
        expect(get_vip_addresses(node2, TEST_INTERFACE)).not_to include(@vip_addresses[0])
      end
    end
  end

  describe "firewall marks" do
    before do
      skip "nftables not available (kernel module nf_tables not loaded)" unless nft_available?(nodes.first)
    end

    context "with VipAddress" do
      it "adds mark rule for the virtual IP" do
        node = nodes.first
        ip = @vip_addresses[0]

        create_vip_address("test-fwmark-1",
                           node_name: node, virtual_cidr: ip,
                           gateway_ip: @gateway_ip,
                           firewall_mark: TEST_FIREWALL_MARK,
                           ports: [{ protocol: "TCP", port: 80 }])

        mark = TEST_FIREWALL_MARK
        expect(wait_for_map_entry(node, "ingress-marks-ipv4", ip, mark, timeout: 30))
          .to be(true), "Ingress map entry for #{ip} => #{format("0x%08x", mark)} did not appear"
      end
    end

    context "with VipAddress having multiple ports" do
      it "adds a single mark entry per VIP address" do
        node = nodes.first
        ip = @vip_addresses[0]

        create_vip_address("test-fwmark-multiport",
                           node_name: node, virtual_cidr: ip,
                           gateway_ip: @gateway_ip,
                           firewall_mark: TEST_FIREWALL_MARK,
                           ports: [{ protocol: "TCP", port: 80 }, { protocol: "TCP", port: 443 }])

        mark = TEST_FIREWALL_MARK
        expect(wait_for_map_entry(node, "ingress-marks-ipv4", ip, mark, timeout: 30))
          .to be(true), "Ingress map entry for #{ip} did not appear"
        entries = get_map_entries(node, "ingress-marks-ipv4")
        expect(entries.count { |e| e[:ip] == ip }).to eq(1)
      end
    end

    context "with VipAddress having egress enabled" do
      it "adds egress mark rule for endpoint IPs" do
        node = nodes.first
        ip = @vip_addresses[0]
        create_vip_address("test-fwmark-egress",
                           node_name: node, virtual_cidr: ip,
                           gateway_ip: @gateway_ip,
                           firewall_mark: TEST_FIREWALL_MARK,
                           egress_enabled: true,
                           endpoint_ips: ["10.244.0.1"],
                           ports: [{ protocol: "TCP", port: 80 }])

        mark = TEST_FIREWALL_MARK
        expect(wait_for_map_entry(node, "egress-marks-ipv4", "10.244.0.1", mark, timeout: 30))
          .to be(true), "Egress map entry for 10.244.0.1 => #{format("0x%08x", mark)} did not appear"
      end
    end

    context "with a VipGateway" do
      after do
        kubectl("delete vipgateways.#{IntegrationTest::API_GROUP} #{TEST_PRECEDENCE_GATEWAY} --ignore-not-found")
      end

      def create_precedence_gateway
        result = kubectl_apply(IntegrationTest.vip_gateway_yaml(
          name: TEST_PRECEDENCE_GATEWAY, destination_cidr: TEST_PRECEDENCE_DESTINATION,
          route_table: TEST_PRECEDENCE_TABLE, routing_priority: TEST_PRECEDENCE_PRIORITY
        ))
        expect(result).to be_success, "Failed to create VipGateway: #{result.message}"
      end

      it "guards both egress mark rules with the gateway destinations" do
        node = nodes.first
        create_precedence_gateway
        expect(wait_for_gateway_destination_entry(node, TEST_PRECEDENCE_DESTINATION)).to be(true)

        expect(wait_for_mark_rule(node, "filter-prerouting", "egress-marks-ipv4") do |rule|
          egress_guarded?(rule) && mark_rule_fields(rule) == ["ct original ip saddr", "ct original ip daddr"]
        end).to be(true), "Specific egress rule is not guarded"
        expect(wait_for_mark_rule(node, "filter-prerouting", "egress-marks-default-ipv4") do |rule|
          egress_guarded?(rule) && mark_rule_fields(rule) == ["ct original ip saddr"]
        end).to be(true), "Default egress rule is not guarded"

        # No unguarded rule looks up an egress map next to the guarded one
        %w[egress-marks-ipv4 egress-marks-default-ipv4].each do |map|
          rules = mark_rules(node, "filter-prerouting", map)
          expect(rules.size).to eq(1), "Expected one rule for #{map}, got: #{rules.inspect}"
          expect(egress_guarded?(rules.first)).to be(true), "Unguarded rule for #{map}: #{rules.first}"
        end
      end

      it "keeps the guarded rule across resyncs" do
        node = nodes.first
        create_precedence_gateway
        expect(wait_for_mark_rule(node, "filter-prerouting", "egress-marks-default-ipv4") { |rule| egress_guarded?(rule) })
          .to be(true)

        before_handles = mark_rule_handles(node, "filter-prerouting", "egress-marks-default-ipv4")
        expect(before_handles.size).to eq(1), "Expected one rule for the default egress map: #{before_handles}"
        stable = holds_for? { mark_rule_handles(node, "filter-prerouting", "egress-marks-default-ipv4") == before_handles }
        expect(stable).to be(true), "The agent re-created the guarded rule during a resync"
      end

      it "logs a source network that overlaps the gateway as an error once, not on every resync" do
        node = nodes.first
        create_precedence_gateway
        create_vip_address("test-overlap",
                           node_name: node, virtual_cidr: @vip_addresses[0],
                           gateway_ip: @gateway_ip,
                           firewall_mark: TEST_FIREWALL_MARK,
                           route_table: TEST_ROUTE_TABLE,
                           routing_priority: TEST_ROUTING_POLICY_RULE_PRIORITY,
                           egress_enabled: true,
                           source_cidrs: [TEST_PRECEDENCE_DESTINATION],
                           endpoint_ips: ["10.244.0.1"],
                           ports: [{ protocol: "TCP", port: 80 }])

        overlap = %r{ERROR - netwrangler\.agent\.agent_hook: VipAddress #{namespace}/test-overlap source network #{Regexp.escape(TEST_PRECEDENCE_DESTINATION)} overlaps VipGateway #{TEST_PRECEDENCE_GATEWAY}}
        logged = 20.times.any? do
          next true if get_agent_logs(node, since: "90s").match?(overlap)

          sleep 3
          false
        end
        expect(logged).to be(true), "The overlap was not logged as an error"

        # At least one more resync and several events run in this time
        sleep 40
        errors = get_agent_logs(node, since: "5m").scan(overlap).size
        expect(errors).to eq(1), "The overlap was logged as an error #{errors} times"
      end

      it "keeps a gateway's rule and fallback in a table its VIP leaves behind" do
        node = nodes.first
        create_vip_address("test-shared-table",
                           node_name: node, virtual_cidr: @vip_addresses[0],
                           gateway_ip: @gateway_ip,
                           firewall_mark: TEST_FIREWALL_MARK,
                           route_table: TEST_ROUTE_TABLE,
                           routing_priority: TEST_ROUTING_POLICY_RULE_PRIORITY,
                           ports: [{ protocol: "TCP", port: 80 }])
        expect(wait_for_fwmark_rule(node, TEST_FIREWALL_MARK, TEST_FIREWALL_MARK_MASK, TEST_ROUTE_TABLE))
          .to be(true), "VIP rule did not appear"

        # Refused on this node while the VIP uses the table
        result = kubectl_apply(IntegrationTest.vip_gateway_yaml(
          name: TEST_SHARED_TABLE_GATEWAY, destination_cidr: TEST_SHARED_TABLE_DESTINATION,
          route_table: TEST_ROUTE_TABLE, routing_priority: TEST_SHARED_TABLE_PRIORITY
        ))
        expect(result).to be_success, "Failed to create VipGateway: #{result.message}"

        # The monitor stops on its own; the node has no pkill
        kind_exec(node, "rm -f #{TEST_RULE_EVENTS}; (timeout 120 ip monitor rule > #{TEST_RULE_EVENTS} 2>&1 &)")
        sleep 1
        kubectl_delete("vipaddress.#{IntegrationTest::API_GROUP}", "test-shared-table", namespace: namespace)

        expect(wait_for_fwmark_rule_removal(node, TEST_ROUTE_TABLE, timeout: 60)).to be(true), "VIP rule stayed"
        expect(wait_for_destination_rule(node, TEST_SHARED_TABLE_DESTINATION, TEST_ROUTE_TABLE, timeout: 60))
          .to be(true), "Gateway rule did not appear once the VIP left"
        expect(wait_for_route(node, TEST_ROUTE_TABLE.to_s, TEST_SHARED_TABLE_DESTINATION, type: "unreachable"))
          .to be(true), "Gateway fallback did not appear once the VIP left"

        # Through a full resync neither the rule nor the fallback goes, not even briefly
        kept = holds_for? do
          get_destination_rules(node).any? { |r| r[:destination] == TEST_SHARED_TABLE_DESTINATION } &&
            get_routes(node, TEST_ROUTE_TABLE.to_s).any? { |r| r[:type] == "unreachable" }
        end
        expect(kept).to be(true), "Gateway rule or fallback disappeared"
        events = kind_exec(node, "cat #{TEST_RULE_EVENTS}").message.lines
        expect(events.grep(/^Deleted .*to #{Regexp.escape(TEST_SHARED_TABLE_DESTINATION)} /)).to be_empty,
                                                                                            "The gateway rule was deleted: #{events.join}"
      ensure
        kind_exec(node, "rm -f #{TEST_RULE_EVENTS}") if node
        kubectl("delete vipgateways.#{IntegrationTest::API_GROUP} #{TEST_SHARED_TABLE_GATEWAY} --ignore-not-found")
      end

      it "sends unmarked traffic to the gateway and marked replies to the VIP, whatever the priorities" do
        node = nodes.first
        ip = @vip_addresses[0]
        create_precedence_gateway
        create_vip_address("test-precedence",
                           node_name: node, virtual_cidr: ip,
                           gateway_ip: @gateway_ip,
                           firewall_mark: TEST_FIREWALL_MARK,
                           route_table: TEST_ROUTE_TABLE,
                           routing_priority: TEST_ROUTING_POLICY_RULE_PRIORITY,
                           egress_enabled: true,
                           source_cidrs: ["0.0.0.0/0"],
                           endpoint_ips: ["10.244.0.1"],
                           ports: [{ protocol: "TCP", port: 80 }])

        expect(wait_for_fwmark_rule(node, TEST_FIREWALL_MARK, TEST_FIREWALL_MARK_MASK, TEST_ROUTE_TABLE)).to be(true)
        expect(wait_for_route(node, TEST_ROUTE_TABLE.to_s, "default")).to be(true), "VIP table has no default route"
        expect(wait_for_route(node, TEST_PRECEDENCE_TABLE.to_s, TEST_PRECEDENCE_DESTINATION, type: "unreachable"))
          .to be(true), "Gateway fallback did not appear"

        # The gateway rule (9200) is evaluated before the VIP rule (10200); its fwmark selector
        # must let marked packets through to the VIP table.
        unmarked = route_get(node, TEST_PRECEDENCE_ADDRESS)
        expect(unmarked.success?).to be(false), "Unmarked traffic was routed: #{unmarked.message}"
        expect(unmarked.message).to include("No route to host")

        marked = route_get(node, "#{TEST_PRECEDENCE_ADDRESS} mark #{format("0x%x", TEST_FIREWALL_MARK)}")
        expect(marked.success?).to be(true), "Marked lookup failed: #{marked.message}"
        expect(marked.message).to include("table #{TEST_ROUTE_TABLE}")
      end
    end

    context "with VipAddress" do
      it "sets the mark bits from the map in one rule, without a chain per VIP" do
        node = nodes.first
        ip = @vip_addresses[0]
        create_vip_address("test-fwmark-chain",
                           node_name: node, virtual_cidr: ip,
                           gateway_ip: @gateway_ip,
                           firewall_mark: TEST_FIREWALL_MARK,
                           ports: [{ protocol: "TCP", port: 80 }])

        expect(wait_for_map_entry(node, "ingress-marks-ipv4", ip, TEST_FIREWALL_MARK, timeout: 30))
          .to be(true), "Ingress map entry did not appear"

        rules = mark_rules(node, "filter-prerouting", "ingress-marks-ipv4")
        expect(rules.size).to eq(1), "Expected one ingress mark rule, got: #{rules.inspect}"
        expect(mark_rule_fields(rules.first)).to eq(["ct original ip daddr", "ct original ip saddr"])
        expect(mark_rule_kept_bits(rules.first)).to eq(~TEST_FIREWALL_MARK_MASK & 0xFFFFFFFF),
                                                    "The rule does not keep the mark bits outside the mask"
        expect(rules.first["expr"]).to include({ "accept" => nil })
        expect(mark_chains(node)).to be_empty, "Mark chains remain: #{mark_chains(node).inspect}"
      end
    end

    context "with the rules of an agent that used mark chains" do
      # The ruleset of the agent before mark maps: verdict maps whose elements
      # jump to a chain per VIP that sets the mark
      def legacy_ruleset(ip)
        mark_chain = format("mark-%08x", TEST_FIREWALL_MARK)
        <<~NFT
          delete table ip netwrangler
          table ip netwrangler {
            chain #{mark_chain} {
              meta mark set meta mark & 0xff00ffff | #{format("0x%08x", TEST_FIREWALL_MARK)}
            }
            map ingress-marks-ipv4 {
              type ipv4_addr . ipv4_addr : verdict; flags interval
              elements = { #{ip} . 192.0.2.0/24 : goto #{mark_chain} }
            }
            map ingress-marks-default-ipv4 { type ipv4_addr : verdict; }
            chain filter-prerouting {
              type filter hook prerouting priority mangle; policy accept;
              ct original ip daddr . ct original ip saddr vmap @ingress-marks-ipv4 comment "Ingress mark lookup"
              ct original ip daddr vmap @ingress-marks-default-ipv4 comment "Ingress mark lookup for default route"
            }
            chain mangle-output {
              type route hook output priority mangle; policy accept;
              ip saddr . ip daddr vmap @ingress-marks-ipv4 comment "Output mark lookup"
            }
          }
        NFT
      end

      it "replaces the verdict maps and mark chains with mark maps" do
        node = nodes.first
        ip = @vip_addresses[0]
        create_vip_address("test-fwmark-migration",
                           node_name: node, virtual_cidr: ip,
                           gateway_ip: @gateway_ip,
                           firewall_mark: TEST_FIREWALL_MARK,
                           ports: [{ protocol: "TCP", port: 80 }])
        expect(wait_for_map_entry(node, "ingress-marks-ipv4", ip, TEST_FIREWALL_MARK, timeout: 30))
          .to be(true), "Ingress map entry did not appear"

        # One nft invocation, so the agent never sees the table half replaced
        result = kind_exec(node, "nft -f - <<'NFT'\n#{legacy_ruleset(ip)}NFT")
        expect(result).to be_success, "Failed to load the legacy ruleset: #{result.message}"
        expect(mark_chains(node)).not_to be_empty

        migrated = 20.times.any? do
          sleep 3
          mark_chains(node).empty? && vmap_rules(node, "filter-prerouting").empty? &&
            vmap_rules(node, "mangle-output").empty? &&
            get_map_entries(node, "ingress-marks-ipv4").any? { |e| e[:ip] == ip && e[:mark] == TEST_FIREWALL_MARK }
        end
        expect(migrated).to be(true),
                            "Not migrated: chains #{mark_chains(node).inspect}, " \
                            "vmap rules #{vmap_rules(node, "filter-prerouting").size + vmap_rules(node, "mangle-output").size}"

        expect(mark_rules(node, "filter-prerouting", "ingress-marks-ipv4").size).to eq(1)
        expect(mark_rules(node, "mangle-output", "ingress-marks-ipv4").size).to eq(1)
        expect(get_map_entries(node, "ingress-marks-ipv4").map { |e| e[:source_cidr] }).not_to include("192.0.2.0/24")
      end
    end

    context "with VipAddress having ingress marks" do
      it "adds an output chain mark rule for locally-generated reply routing" do
        node = nodes.first
        ip = @vip_addresses[0]

        create_vip_address("test-output-chain",
                           node_name: node, virtual_cidr: ip,
                           gateway_ip: @gateway_ip,
                           firewall_mark: TEST_FIREWALL_MARK,
                           ports: [{ protocol: "TCP", port: 80 }])

        # Wait for the ingress map entry first (ensures the agent has processed)
        mark = TEST_FIREWALL_MARK
        expect(wait_for_map_entry(node, "ingress-marks-ipv4", ip, mark, timeout: 30))
          .to be(true), "Ingress map entry did not appear"

        # The mangle-output chain looks the reply up by its source address
        expect(wait_for_mark_rule(node, "mangle-output", "ingress-marks-ipv4", timeout: 10) do |rule|
          mark_rule_fields(rule) == ["ip saddr", "ip daddr"]
        end).to be(true), "Output chain mark rule for @ingress-marks-ipv4 did not appear"
      end
    end

    context "when VipAddress with firewall marks is deleted" do
      it "removes mark rules" do
        node = nodes.first
        ip = @vip_addresses[0]

        create_vip_address("test-fwmark-cleanup",
                           node_name: node, virtual_cidr: ip,
                           gateway_ip: @gateway_ip,
                           firewall_mark: TEST_FIREWALL_MARK,
                           ports: [{ protocol: "TCP", port: 80 }])

        expect(wait_for_map_entry(node, "ingress-marks-ipv4", ip, TEST_FIREWALL_MARK, timeout: 30))
          .to be(true), "Mark rule did not appear"

        # Delete the VipAddress
        kubectl_delete("vipaddress.#{IntegrationTest::API_GROUP}", "test-fwmark-cleanup",
                       namespace: namespace)

        expect(wait_for_map_entry_removal(node, "ingress-marks-ipv4", ip, timeout: 30))
          .to be(true), "Mark rule was not removed"
      end
    end
  end

  describe "SNAT" do
    before do
      skip "nftables not available" unless nft_available?(nodes.first)
    end

    it "creates SNAT map entry for the VIP" do
      node = nodes.first
      ip = @vip_addresses[0]

      create_vip_address("test-snat-1",
                         node_name: node, virtual_cidr: ip,
                         gateway_ip: @gateway_ip,
                         firewall_mark: TEST_FIREWALL_MARK,
                         ports: [{ protocol: "TCP", port: 80 }])

      expect(wait_for_snat_entry(node, ip, timeout: 30))
        .to be(true), "SNAT map entry for #{ip} did not appear"

      expect(has_snat_rule?(node))
        .to be(true), "SNAT rule not found in nat-postrouting chain"
    end

    it "removes SNAT map entry when VipAddress is deleted" do
      node = nodes.first
      ip = @vip_addresses[0]

      create_vip_address("test-snat-cleanup",
                         node_name: node, virtual_cidr: ip,
                         gateway_ip: @gateway_ip,
                         firewall_mark: TEST_FIREWALL_MARK,
                         ports: [{ protocol: "TCP", port: 80 }])

      expect(wait_for_snat_entry(node, ip, timeout: 30))
        .to be(true), "SNAT map entry for #{ip} did not appear"

      kubectl_delete(
        "vipaddress.#{IntegrationTest::API_GROUP}",
        "test-snat-cleanup",
        namespace: namespace
      )

      expect(wait_for_snat_entry_removal(node, ip, timeout: 30))
        .to be(true), "SNAT map entry for #{ip} was not removed"
    end
  end

  describe "cluster networks" do
    before do
      skip "nftables not available" unless nft_available?(nodes.first)
    end

    context "with clusterCIDRs configured" do
      before(:all) do
        extend IntegrationTest::KubectlHelper

        config_yaml = IntegrationTest.vip_config_yaml(
          name: "default",
          firewall_mark: TEST_FIREWALL_MARK,
          firewall_mark_mask: TEST_FIREWALL_MARK_MASK,
          route_table: TEST_ROUTE_TABLE,
          routing_priority: TEST_ROUTING_POLICY_RULE_PRIORITY,
          cluster_cidrs: ["10.244.0.0/16", "10.96.0.0/12"]
        )
        result = kubectl_apply(config_yaml)
        raise "Failed to update VipConfig: #{result.message}" unless result.success?
      end

      after(:all) do
        extend IntegrationTest::KubectlHelper

        config_yaml = IntegrationTest.vip_config_yaml(
          name: "default",
          firewall_mark: TEST_FIREWALL_MARK,
          firewall_mark_mask: TEST_FIREWALL_MARK_MASK,
          route_table: TEST_ROUTE_TABLE,
          routing_priority: TEST_ROUTING_POLICY_RULE_PRIORITY
        )
        kubectl_apply(config_yaml)
      end

      it "populates the cluster-networks set" do
        node = nodes.first
        ip = @vip_addresses[0]

        create_vip_address("test-cluster-net",
                           node_name: node, virtual_cidr: ip,
                           gateway_ip: @gateway_ip,
                           firewall_mark: TEST_FIREWALL_MARK,
                           ports: [{ protocol: "TCP", port: 80 }])

        expect(wait_for_cluster_network_entry(node, "10.244.0.0/16", timeout: 30))
          .to be(true), "Cluster network 10.244.0.0/16 not found in set"
      end

      it "adds return rules to both chains" do
        node = nodes.first
        ip = @vip_addresses[0]

        create_vip_address("test-cluster-rules",
                           node_name: node, virtual_cidr: ip,
                           gateway_ip: @gateway_ip,
                           firewall_mark: TEST_FIREWALL_MARK,
                           ports: [{ protocol: "TCP", port: 80 }])

        # Wait for processing
        mark = TEST_FIREWALL_MARK
        expect(wait_for_map_entry(node, "ingress-marks-ipv4", ip, mark, timeout: 30))
          .to be(true), "Ingress map entry did not appear"

        expect(has_cluster_networks_rule?(node, "filter-prerouting"))
          .to be(true), "Return rule not found in filter-prerouting"

        expect(has_cluster_networks_rule?(node, "mangle-output"))
          .to be(true), "Return rule not found in mangle-output"
      end
    end
  end

  describe "routes" do
    context "with VipAddress having route_table, gateway_ip, and firewall_mark" do
      it "creates policy rule and network route" do
        node = nodes.first
        ip = @vip_addresses[0]

        create_vip_address("test-route-1",
                           node_name: node, virtual_cidr: ip,
                           gateway_ip: @gateway_ip,
                           firewall_mark: TEST_FIREWALL_MARK,
                           route_table: TEST_ROUTE_TABLE,
                           routing_priority: TEST_ROUTING_POLICY_RULE_PRIORITY)

        # Verify policy rule is created with correct priority
        expect(wait_for_fwmark_rule(node, TEST_FIREWALL_MARK, TEST_FIREWALL_MARK_MASK,
                                    TEST_ROUTE_TABLE, priority: TEST_ROUTING_POLICY_RULE_PRIORITY,
                                                      timeout: 30))
          .to be(true), "Policy rule for fwmark #{TEST_FIREWALL_MARK} table #{TEST_ROUTE_TABLE} " \
                        "priority #{TEST_ROUTING_POLICY_RULE_PRIORITY} did not appear"

        # Verify network route exists (connected route, no gateway)
        expect(wait_for_route(node, TEST_ROUTE_TABLE.to_s, @network_cidr, timeout: 30))
          .to be(true), "Network route #{@network_cidr} did not appear in table #{TEST_ROUTE_TABLE}"

        routes = get_routes(node, TEST_ROUTE_TABLE.to_s)
        network_route = routes.find { |r| r[:dst] == @network_cidr }
        expect(network_route[:gateway]).to be_nil, "Network route should not have a gateway"
        expect(network_route[:prefsrc]).to eq(ip), "Network route should have VIP as source"
      end
    end

    context "with VipAddress having source network addresses" do
      it "creates source network routes via gateway" do
        node = nodes.first
        ip = @vip_addresses[0]
        source_network = "10.99.0.0/16"

        create_vip_address("test-route-source",
                           node_name: node, virtual_cidr: ip,
                           gateway_ip: @gateway_ip,
                           firewall_mark: TEST_FIREWALL_MARK,
                           route_table: TEST_ROUTE_TABLE,
                           routing_priority: TEST_ROUTING_POLICY_RULE_PRIORITY,
                           source_cidrs: [source_network])

        # Verify source network route via gateway
        expect(wait_for_route(node, TEST_ROUTE_TABLE.to_s, source_network, timeout: 30))
          .to be(true), "Source network route #{source_network} did not appear in table #{TEST_ROUTE_TABLE}"

        routes = get_routes(node, TEST_ROUTE_TABLE.to_s)
        source_route = routes.find { |r| r[:dst] == source_network }
        expect(source_route[:gateway]).to eq(@gateway_ip),
                                          "Source network route should have gateway #{@gateway_ip}"
        expect(source_route[:prefsrc]).to eq(ip), "Source network route should have VIP as source"
      end
    end

    context "when source network addresses change" do
      it "removes stale routes and adds new ones" do
        node = nodes.first
        ip = @vip_addresses[0]
        old_source = "10.99.0.0/16"
        new_source = "10.100.0.0/16"

        create_vip_address("test-route-update",
                           node_name: node, virtual_cidr: ip,
                           gateway_ip: @gateway_ip,
                           firewall_mark: TEST_FIREWALL_MARK,
                           route_table: TEST_ROUTE_TABLE,
                           routing_priority: TEST_ROUTING_POLICY_RULE_PRIORITY,
                           source_cidrs: [old_source])

        expect(wait_for_route(node, TEST_ROUTE_TABLE.to_s, old_source, timeout: 30))
          .to be(true), "Old source route #{old_source} did not appear"

        # Delete and recreate VipAddress with different source network (all fields are immutable)
        kubectl_delete("vipaddress.#{IntegrationTest::API_GROUP}", "test-route-update",
                       namespace: TEST_NAMESPACE)
        sleep 3
        create_vip_address("test-route-update",
                           node_name: node, virtual_cidr: ip,
                           gateway_ip: @gateway_ip,
                           firewall_mark: TEST_FIREWALL_MARK,
                           route_table: TEST_ROUTE_TABLE,
                           routing_priority: TEST_ROUTING_POLICY_RULE_PRIORITY,
                           source_cidrs: [new_source])

        expect(wait_for_route(node, TEST_ROUTE_TABLE.to_s, new_source, timeout: 30))
          .to be(true), "New source route #{new_source} did not appear"

        expect(wait_for_route_removal(node, TEST_ROUTE_TABLE.to_s, old_source, timeout: 30))
          .to be(true), "Old source route #{old_source} was not removed"
      end
    end

    context "with VipAddresses on two interfaces of one node" do
      let(:second_interface) { "vipdummy0" }
      let(:second_network) { "vip-agent-test-second" }
      let(:second_vip) { "10.250.0.10" }
      let(:second_table) { TEST_ROUTE_TABLE + 1 }
      let(:second_mark) { 0x020000 }

      before do
        kind_exec(nodes.first, "ip link add #{second_interface} type dummy && " \
                               "ip addr add 10.250.0.1/24 dev #{second_interface} && " \
                               "ip link set #{second_interface} up")
        result = kubectl_apply(IntegrationTest.network_yaml(
          name: second_network, interface: second_interface,
          gateway_ip: "10.250.0.254", network_cidr: "10.250.0.0/24"
        ))
        expect(result).to be_success, "Failed to create VipNetwork: #{result.message}"
      end

      after do
        kubectl("delete vipaddresses.#{IntegrationTest::API_GROUP} --all --namespace=#{namespace} --ignore-not-found")
        kubectl("delete vipnetworks.#{IntegrationTest::API_GROUP} #{second_network} --ignore-not-found")
        sleep 5
        kind_exec(nodes.first, "ip link del #{second_interface} 2>/dev/null")
      end

      # Creates one VipAddress on eth0 and one on the dummy interface, and waits for both policy rules
      def create_vips_on_two_interfaces(node)
        create_vip_address("test-two-interfaces-1",
                           node_name: node, virtual_cidr: @vip_addresses[0],
                           gateway_ip: @gateway_ip,
                           firewall_mark: TEST_FIREWALL_MARK,
                           route_table: TEST_ROUTE_TABLE,
                           routing_priority: TEST_ROUTING_POLICY_RULE_PRIORITY,
                           ports: [{ protocol: "TCP", port: 80 }])
        result = kubectl_apply(IntegrationTest.vip_address_yaml(
          name: "test-two-interfaces-2", namespace: namespace, network: second_network,
          node_name: node, virtual_cidr: "#{second_vip}/24", interface: second_interface,
          gateway_ip: "10.250.0.254", firewall_mark: second_mark,
          route_table: second_table, routing_priority: second_table,
          ports: [{ protocol: "TCP", port: 80 }]
        ))
        expect(result).to be_success, "Failed to create VipAddress: #{result.message}"

        expect(wait_for_fwmark_rule(node, TEST_FIREWALL_MARK, TEST_FIREWALL_MARK_MASK, TEST_ROUTE_TABLE))
          .to be(true), "Policy rule for table #{TEST_ROUTE_TABLE} did not appear"
        expect(wait_for_fwmark_rule(node, second_mark, TEST_FIREWALL_MARK_MASK, second_table))
          .to be(true), "Policy rule for table #{second_table} did not appear"
      end

      it "keeps both route tables across a resync" do
        node = nodes.first
        create_vips_on_two_interfaces(node)

        # Let at least one resync run with both interfaces in place
        sleep 35

        logs = get_agent_logs(node, since: "35s")
        expect(logs).to include("Processing VipAddress events"), "The agent did not run during the wait"
        expect(logs).not_to include("Removing stale policy rule"),
                            "The agent removed a route table that an interface still uses"
        expect(wait_for_fwmark_rule(node, second_mark, TEST_FIREWALL_MARK_MASK, second_table, timeout: 1))
          .to be(true), "Policy rule for table #{second_table} is gone after the resync"
      end

      it "keeps the other interface's marks when one interface goes inactive" do
        node = nodes.first
        ip = @vip_addresses[0]
        create_vips_on_two_interfaces(node)
        expect(wait_for_map_entry(node, "ingress-marks-ipv4", ip, TEST_FIREWALL_MARK))
          .to be(true), "Ingress map entry for #{ip} did not appear"

        # An inactive interface that still holds a VIP address is stale
        went_down = Time.now
        kind_exec(node, "ip link set #{second_interface} down")
        expect(wait_for_vip_address_removal(node, second_interface, second_vip, timeout: 60))
          .to be(true), "VIP #{second_vip} was not removed from the inactive interface"

        # Only the agent runs since the interface went down; earlier examples
        # removed VIPs with the same address during their teardown
        logs = get_agent_logs(node, since: "#{(Time.now - went_down).ceil}s")
        expect(logs).to include("Removing IP #{second_vip}/24 from interface #{second_interface}")
        removals = logs.lines.select { |line| line.match?(/removing|deleting/i) }
        touched = removals.grep(/#{Regexp.escape(ip)}|table #{TEST_ROUTE_TABLE}\b/)
        expect(touched).to be_empty, "The agent removed state of the interface that kept its VIP:\n#{touched.join}"
        expect(wait_for_map_entry(node, "ingress-marks-ipv4", ip, TEST_FIREWALL_MARK, timeout: 1))
          .to be(true), "Ingress map entry for #{ip} is gone"
      end
    end
  end

  describe "cleanup" do
    context "when VipAddress is deleted" do
      it "removes VIP address from the node" do
        node = nodes.first
        ip = @vip_addresses[0]

        create_vip_address("test-cleanup-vip", node_name: node, virtual_cidr: ip)

        expect(wait_for_vip_address(node, TEST_INTERFACE, ip, timeout: 30))
          .to be(true), "VIP #{ip} did not appear on #{node}"

        # Delete the VipAddress
        kubectl_delete("vipaddress.#{IntegrationTest::API_GROUP}", "test-cleanup-vip",
                       namespace: namespace)

        expect(wait_for_vip_address_removal(node, TEST_INTERFACE, ip, timeout: 30))
          .to be(true), "VIP #{ip} was not removed from #{node}"
      end
    end

    context "when VipAddress with routes is deleted" do
      it "removes policy rule and route table" do
        node = nodes.first
        ip = @vip_addresses[0]

        create_vip_address("test-cleanup-route",
                           node_name: node, virtual_cidr: ip,
                           gateway_ip: @gateway_ip,
                           firewall_mark: TEST_FIREWALL_MARK,
                           route_table: TEST_ROUTE_TABLE,
                           routing_priority: TEST_ROUTING_POLICY_RULE_PRIORITY)

        expect(wait_for_fwmark_rule(node, TEST_FIREWALL_MARK, TEST_FIREWALL_MARK_MASK,
                                    TEST_ROUTE_TABLE, priority: TEST_ROUTING_POLICY_RULE_PRIORITY,
                                                      timeout: 30))
          .to be(true), "Policy rule did not appear"

        # Delete the VipAddress
        kubectl_delete("vipaddress.#{IntegrationTest::API_GROUP}", "test-cleanup-route",
                       namespace: namespace)

        expect(wait_for_fwmark_rule_removal(node, TEST_ROUTE_TABLE, timeout: 30))
          .to be(true), "Policy rule was not removed"
      end
    end
  end

  describe "full lifecycle" do
    it "creates and cleans up VIPs, policy rules, and routes" do
      node = nodes.first
      ip = @vip_addresses[0]
      source_network = "10.99.0.0/16"

      create_vip_address("test-lifecycle",
                         node_name: node, virtual_cidr: ip,
                         gateway_ip: @gateway_ip,
                         firewall_mark: TEST_FIREWALL_MARK,
                         route_table: TEST_ROUTE_TABLE,
                         routing_priority: TEST_ROUTING_POLICY_RULE_PRIORITY,
                         source_cidrs: [source_network],
                         ports: [{ protocol: "TCP", port: 80 }])

      # Verify VIP, policy rule, and routes are configured
      expect(wait_for_vip_address(node, TEST_INTERFACE, ip, timeout: 30))
        .to be(true), "VIP #{ip} did not appear"
      expect(wait_for_fwmark_rule(node, TEST_FIREWALL_MARK, TEST_FIREWALL_MARK_MASK,
                                  TEST_ROUTE_TABLE, priority: TEST_ROUTING_POLICY_RULE_PRIORITY,
                                                    timeout: 30))
        .to be(true), "Policy rule did not appear"
      expect(wait_for_route(node, TEST_ROUTE_TABLE.to_s, @network_cidr, timeout: 30))
        .to be(true), "Network route did not appear"
      expect(wait_for_route(node, TEST_ROUTE_TABLE.to_s, source_network, timeout: 30))
        .to be(true), "Source network route did not appear"

      # Delete the VipAddress
      kubectl_delete("vipaddress.#{IntegrationTest::API_GROUP}", "test-lifecycle",
                     namespace: namespace)

      # Verify VIP, policy rule, and routes are cleaned up
      expect(wait_for_vip_address_removal(node, TEST_INTERFACE, ip, timeout: 30))
        .to be(true), "VIP #{ip} was not removed"
      expect(wait_for_fwmark_rule_removal(node, TEST_ROUTE_TABLE, timeout: 30))
        .to be(true), "Policy rule was not removed"
    end
  end
end
