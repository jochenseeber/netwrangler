# frozen_string_literal: true

require_relative "nft_helper"

module IntegrationTest
  # Helper methods for executing commands on kind cluster nodes via docker exec
  module KindHelper
    include NftHelper

    # Execute a command on a kind cluster node via docker exec
    #
    # @param node [String] node name (also the Docker container name)
    # @param command [String] command to execute
    # @return [TestResult] result containing success status and output message
    def kind_exec(node, command)
      stdout, stderr, status = Open3.capture3(
        "docker", "exec", node, "sh", "-c", command
      )

      TestResult.new(
        success: status.success?,
        message: status.success? ? stdout.strip : stderr.strip
      )
    end

    # Get recent agent logs for a specific node
    #
    # @param node [String] node name
    # @param since [String] duration to look back (e.g., "30s", "1m")
    # @return [String] log output
    def get_agent_logs(node, since: "60s")
      pod_name = agent_pod_name(node)
      return "" if pod_name.empty?

      kubectl_output(
        "logs --namespace=#{IntegrationTest::CONTROLLER_NAMESPACE} #{pod_name} --since=#{since}"
      )
    end

    # Errors of `kubectl exec` itself, while the agent container restarts,
    # rather than of the command it runs
    EXEC_UNAVAILABLE = %r{container not found|unable to upgrade connection|container .* is not running}

    # Run a command in the agent container on a node. An agent that stops its
    # container after a failed hook is briefly not there to exec into, so an
    # exec that cannot reach the container is retried; a failing command is not.
    #
    # @param node [String] node name
    # @param command [String] command and arguments, split on whitespace
    # @param attempts [Integer] attempts, 3 seconds apart
    # @return [TestResult] result of the command
    def agent_exec(node, command, attempts: 10)
      result = nil
      attempts.times do |attempt|
        sleep 3 if attempt.positive?
        result = kubectl("exec #{agent_pod_name(node)} --namespace=#{IntegrationTest::CONTROLLER_NAMESPACE} -- #{command}")
        return result unless !result.success? && result.message.match?(EXEC_UNAVAILABLE)
      end
      result
    end

    # Get the name of the agent pod on a node
    #
    # @param node [String] node name
    # @return [String] pod name, empty when no agent pod runs on the node
    def agent_pod_name(node)
      kubectl_output(
        "get pods --namespace=#{IntegrationTest::CONTROLLER_NAMESPACE} " \
        "--selector=app.kubernetes.io/component=agent " \
        "--field-selector=spec.nodeName=#{node} " \
        "--output=jsonpath='{.items[0].metadata.name}'"
      ).delete("'")
    end

    # Check whether nftables is available on a node (kernel module loaded or built-in)
    #
    # @param node [String] node name
    # @return [Boolean] true if nft commands can run successfully
    def nft_available?(node)
      result = kind_exec(node, "nft list tables")
      result.success?
    end

    # Check whether a network interface exists on a node
    #
    # @param node [String] node name
    # @param interface [String] network interface name
    # @return [Boolean] true if the interface exists
    def interface_exists?(node, interface)
      result = kind_exec(node, "ip link show dev #{interface}")
      result.success?
    end

    # Get VIP-labeled IPv4 addresses on an interface
    #
    # @param node [String] node name
    # @param interface [String] network interface name
    # @return [Set<String>] set of VIP IP addresses
    def get_vip_addresses(node, interface)
      result = kind_exec(node, "ip --json addr show dev #{interface}")
      return Set.new unless result.success?

      begin
        interfaces = JSON.parse(result.message)
        return Set.new unless interfaces.is_a?(Array) && !interfaces.empty?

        interfaces.first.fetch("addr_info", [])
          .select { |addr| addr["family"] == "inet" && addr["label"]&.start_with?("vip:") }
          .map { |addr| addr["local"] }
          .to_set
      rescue JSON::ParserError
        Set.new
      end
    end

    # Get source IPs from a routing table
    #
    # @param node [String] node name
    # @param table [String] routing table name or numeric ID
    # @return [Set<String>] set of source IP addresses
    def get_route_sources(node, table)
      result = kind_exec(node, "ip --json route show table #{table} from root 0/0")
      return Set.new unless result.success?

      begin
        routes = JSON.parse(result.message)
        return Set.new unless routes.is_a?(Array)

        routes.filter_map { |route| route["prefsrc"] || route["src"] }.to_set
      rescue JSON::ParserError
        Set.new
      end
    end

    # Set up a routing table on a node for testing
    #
    # For named tables, registers the name in /etc/iproute2/rt_tables.
    # Numeric table IDs work without registration.
    #
    # Raises if the ip rule cannot be added.
    #
    # @param node [String] node name
    # @param interface [String] network interface name
    # @param table [String] routing table name or numeric ID (defaults to interface name)
    # @raise [RuntimeError] if setup fails
    def setup_routing_table(node, interface, table: interface)
      # Named tables need an entry in rt_tables; numeric IDs work directly
      unless table.match?(%r{\A\d+\z})
        result = kind_exec(node,
                           "sh -c 'grep -q \"^200 #{table}$\" /etc/iproute2/rt_tables " \
                           "|| echo \"200 #{table}\" >> /etc/iproute2/rt_tables'")
        raise "Failed to register routing table #{table} on #{node}: #{result.message}" unless result.success?
      end

      # Add ip rule — ignore EEXIST (rule already present)
      result = kind_exec(node, "ip rule add table #{table} priority 100")
      if !result.success? && !result.message.include?("File exists")
        raise "Failed to add ip rule for table #{table} on #{node}: #{result.message}"
      end

      # Verify the rule is in place
      raise "Routing table #{table} rule not found on #{node} after setup" if ip_rules(node, "table #{table}").empty?
    end

    # Clean up routing table on a node
    #
    # Silently ignores errors during cleanup (table/rules may not exist).
    #
    # @param node [String] node name
    # @param interface [String] network interface name
    # @param table [String] routing table name or numeric ID (defaults to interface name)
    def cleanup_routing_table(node, interface, table: interface)
      kind_exec(node, "ip route flush table #{table} 2>/dev/null")
      kind_exec(node, "ip rule del table #{table} 2>/dev/null")
    end

    # Remove all VIP-labeled addresses from an interface on a node
    #
    # @param node [String] node name
    # @param interface [String] network interface name
    def cleanup_vip_addresses(node, interface)
      result = kind_exec(node, "ip --json addr show dev #{interface}")
      return unless result.success?

      begin
        interfaces = JSON.parse(result.message)
        return unless interfaces.is_a?(Array) && !interfaces.empty?

        interfaces.first.fetch("addr_info", [])
          .select { |addr| addr["family"] == "inet" && addr["label"]&.start_with?("vip:") }
          .each { |addr| kind_exec(node, "ip addr del #{addr["local"]}/#{addr["prefixlen"]} dev #{interface}") }
      rescue JSON::ParserError
        # ignore
      end
    end

    # Wait for a VIP address to appear on an interface
    #
    # @param node [String] node name
    # @param interface [String] network interface name
    # @param ip [String] expected IP address
    # @param timeout [Integer] maximum seconds to wait (default: 30)
    # @return [Boolean] true if address appeared
    def wait_for_vip_address(node, interface, ip, timeout: 30)
      timeout.times do
        return true if get_vip_addresses(node, interface).include?(ip)

        sleep 3
      end

      false
    end

    # Wait for a VIP address to be removed from an interface
    #
    # @param node [String] node name
    # @param interface [String] network interface name
    # @param ip [String] IP address expected to be removed
    # @param timeout [Integer] maximum seconds to wait (default: 30)
    # @return [Boolean] true if address was removed
    def wait_for_vip_address_removal(node, interface, ip, timeout: 30)
      timeout.times do
        return true unless get_vip_addresses(node, interface).include?(ip)

        sleep 3
      end

      false
    end

    # Wait for a route source IP to appear in a routing table
    #
    # @param node [String] node name
    # @param table [String] routing table name or numeric ID
    # @param ip [String] expected source IP address
    # @param timeout [Integer] maximum seconds to wait (default: 30)
    # @return [Boolean] true if route appeared
    def wait_for_route_source(node, table, ip, timeout: 30)
      timeout.times do
        return true if get_route_sources(node, table).include?(ip)

        sleep 3
      end

      false
    end

    # Wait for a route source IP to be removed from a routing table
    #
    # @param node [String] node name
    # @param table [String] routing table name or numeric ID
    # @param ip [String] source IP expected to be removed
    # @param timeout [Integer] maximum seconds to wait (default: 30)
    # @return [Boolean] true if route was removed
    def wait_for_route_source_removal(node, table, ip, timeout: 30)
      timeout.times do
        return true unless get_route_sources(node, table).include?(ip)

        sleep 3
      end

      false
    end

    # Get all routes in a routing table
    #
    # @param node [String] node name
    # @param table [String] routing table name or numeric ID
    # @return [Array<Hash>] array of {dst:, type:, gateway:, dev:, prefsrc:, protocol:} hashes
    def get_routes(node, table)
      result = kind_exec(node, "ip --json route show table #{table}")
      return [] unless result.success?

      begin
        routes = JSON.parse(result.message)
        return [] unless routes.is_a?(Array)

        routes.map do |route|
          {
            dst: route["dst"],
            type: route["type"] || "unicast",
            gateway: route["gateway"],
            dev: route["dev"],
            prefsrc: route["prefsrc"],
            protocol: route["protocol"],
          }
        end
      rescue JSON::ParserError
        []
      end
    end

    # Wait for a route with the given destination to appear in a routing table
    #
    # @param node [String] node name
    # @param table [String] routing table name or numeric ID
    # @param dst [String] expected route destination (e.g., "10.0.1.0/24" or "default")
    # @param type [String, nil] expected route type (e.g., "unicast" or "unreachable"), any if nil
    # @param timeout [Integer] maximum seconds to wait (default: 30)
    # @return [Boolean] true if route appeared
    def wait_for_route(node, table, dst, type: nil, timeout: 30)
      timeout.times do
        routes = get_routes(node, table)
        return true if routes.any? { |r| r[:dst] == dst && (type.nil? || r[:type] == type) }

        sleep 3
      end

      false
    end

    # Wait for a route with the given destination to be removed from a routing table
    #
    # @param node [String] node name
    # @param table [String] routing table name or numeric ID
    # @param dst [String] route destination expected to be removed
    # @param type [String, nil] route type expected to be removed, any if nil
    # @param timeout [Integer] maximum seconds to wait (default: 30)
    # @return [Boolean] true if route was removed
    def wait_for_route_removal(node, table, dst, type: nil, timeout: 30)
      timeout.times do
        routes = get_routes(node, table)
        return true unless routes.any? { |r| r[:dst] == dst && (type.nil? || r[:type] == type) }

        sleep 3
      end

      false
    end

    # Clean up the agent-managed netwrangler table on a node
    #
    # @param node [String] node name
    def cleanup_mangle_table(node)
      return unless nft_available?(node)

      kind_exec(node, "nft delete table ip netwrangler 2>/dev/null")
    end

    # Get the VIP policy rules with a fwmark selector from a node
    #
    # @param node [String] node name
    # @return [Array<Hash>] array of {priority:, fwmark:, mask:, table:, protocol:} hashes
    def get_fwmark_rules(node)
      ip_rules(node).filter_map do |rule|
        next unless rule["src"] == "all" && !rule.key?("dst") && !rule.key?("not") && rule["fwmark"]&.start_with?("0x")

        { priority: rule["priority"], fwmark: rule["fwmark"].to_i(16), mask: (rule["fwmask"] || "0xffffffff").to_i(16),
          table: rule["table"].to_i, protocol: rule["protocol"], }
      end
    end

    # Wait for a fwmark policy rule to appear
    #
    # @param node [String] node name
    # @param fwmark [Integer] expected firewall mark value
    # @param mask [Integer] expected firewall mark mask
    # @param table [Integer] expected routing table
    # @param timeout [Integer] maximum seconds to wait (default: 30)
    # @return [Boolean] true if rule appeared
    def wait_for_fwmark_rule(node, fwmark, mask, table, priority: nil, timeout: 30)
      timeout.times do
        rules = get_fwmark_rules(node)
        return true if rules.any? do |r|
          r[:fwmark] == fwmark && r[:mask] == mask && r[:table] == table &&
            (priority.nil? || r[:priority] == priority)
        end

        sleep 3
      end

      false
    end

    # Wait for a fwmark policy rule to be removed
    #
    # @param node [String] node name
    # @param table [Integer] routing table of the rule expected to be removed
    # @param timeout [Integer] maximum seconds to wait (default: 30)
    # @return [Boolean] true if rule was removed
    def wait_for_fwmark_rule_removal(node, table, timeout: 30)
      timeout.times do
        rules = get_fwmark_rules(node)
        return true unless rules.any? { |r| r[:table] == table }

        sleep 3
      end

      false
    end

    # Get the policy rules with a "to" selector from all sources (VipGateway rules)
    #
    # @param node [String] node name
    # @return [Array<Hash>] array of {priority:, destination:, fwmark:, table:, protocol:} hashes; the
    #   destination and fwmark as `ip rule show` prints them
    def get_destination_rules(node)
      ip_rules(node).filter_map do |rule|
        next unless rule["src"] == "all" && rule.key?("dst") && rule["table"].match?(/\A\d+\z/)

        { priority: rule["priority"], destination: [rule["dst"], rule["dstlen"]].compact.join("/"),
          fwmark: rule["fwmark"] && [rule["fwmark"], rule["fwmask"]].compact.join("/"),
          table: rule["table"].to_i, protocol: rule["protocol"], }
      end
    end

    # The policy rules of a node as `ip --json rule show` lists them
    #
    # @param node [String] node name
    # @param selector [String] arguments that select rules, all when empty
    # @return [Array<Hash>] the rules
    def ip_rules(node, selector = "")
      result = kind_exec(node, "ip --json rule show #{selector}")
      return [] unless result.success?

      JSON.parse(result.message)
    rescue JSON::ParserError
      []
    end

    # Wait for a destination policy rule to appear
    #
    # @param node [String] node name
    # @param destination [String] expected destination CIDR
    # @param table [Integer] expected routing table
    # @param fwmark [String, nil] expected fwmark selector as `ip rule` prints it, any if nil
    # @param priority [Integer, nil] expected rule priority, any if nil
    # @param protocol [String, nil] expected protocol as `ip rule` prints it, any if nil
    # @param timeout [Integer] maximum seconds to wait (default: 30)
    # @return [Boolean] true if rule appeared
    def wait_for_destination_rule(node, destination, table, fwmark: nil, priority: nil, protocol: nil, timeout: 30)
      timeout.times do
        rules = get_destination_rules(node)
        return true if rules.any? do |r|
          r[:destination] == destination && r[:table] == table &&
            (fwmark.nil? || r[:fwmark] == fwmark) && (priority.nil? || r[:priority] == priority) &&
            (protocol.nil? || r[:protocol] == protocol)
        end

        sleep 3
      end

      false
    end

    # Wait for a destination policy rule to be removed
    #
    # @param node [String] node name
    # @param destination [String] destination CIDR expected to be removed
    # @param table [Integer] routing table of the rule expected to be removed
    # @param timeout [Integer] maximum seconds to wait (default: 30)
    # @return [Boolean] true if rule was removed
    def wait_for_destination_rule_removal(node, destination, table, timeout: 30)
      timeout.times do
        rules = get_destination_rules(node)
        return true unless rules.any? { |r| r[:destination] == destination && r[:table] == table }

        sleep 3
      end

      false
    end

    # Clean up VipRoute-created policy rules (destination-based)
    #
    # @param node [String] node name
    def cleanup_destination_rules(node)
      get_destination_rules(node).each do |rule|
        kind_exec(node, "ip route flush table #{rule[:table]} 2>/dev/null")
        kind_exec(node, "ip rule del to #{rule[:destination]} table #{rule[:table]} 2>/dev/null")
      end
    end

    # Clean up agent-created fwmark policy rules and routing tables on a node
    #
    # @param node [String] node name
    def cleanup_fwmark_rules(node)
      get_fwmark_rules(node).each do |rule|
        kind_exec(node, "ip route flush table #{rule[:table]} 2>/dev/null")
        kind_exec(node, "ip rule del table #{rule[:table]} 2>/dev/null")
      end
    end

    # Wait for a gateway-destinations set element to disappear
    #
    # @param node [String] node name
    # @param cidr [String] CIDR expected to be removed
    # @param timeout [Integer] maximum seconds to wait
    # @return [Boolean] true if element was removed
    def wait_for_gateway_destination_entry_removal(node, cidr, timeout: 30)
      timeout.times do
        return true unless get_gateway_destination_entries(node).include?(cidr)

        sleep 3
      end

      false
    end

    # Run `ip route get` on a node
    #
    # @param node [String] node name
    # @param args [String] arguments after `ip route get`
    # @return [TestResult] stdout on success, stderr on failure
    def route_get(node, args)
      kind_exec(node, "ip route get #{args}")
    end

    # Whether a condition holds at every check for a duration longer than the
    # agent's 30-second resync
    #
    # @param seconds [Integer] how long the condition must hold
    # @param interval [Integer] seconds between checks
    # @yieldreturn [Boolean] whether the condition holds
    # @return [Boolean] true if the condition held at every check
    def holds_for?(seconds: 36, interval: 3)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
      loop do
        return false unless yield
        return true if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

        sleep interval
      end
    end

    # Discover the default gateway IP on a node
    #
    # @param node [String] node name
    # @return [String] gateway IP address
    # @raise [RuntimeError] if gateway cannot be discovered
    def discover_gateway(node)
      result = kind_exec(node, "ip --json route show default")
      raise "Failed to discover gateway on #{node}: #{result.message}" unless result.success?

      routes = JSON.parse(result.message)
      raise "No default route found on #{node}" unless routes.is_a?(Array) && !routes.empty?

      gateway = routes.first["gateway"]
      raise "No gateway in default route on #{node}" unless gateway

      gateway
    end

    # Discover the network prefix length of the primary IPv4 address on an interface
    #
    # @param node [String] node name
    # @param interface [String] network interface name
    # @return [Integer] network prefix length
    # @raise [RuntimeError] if prefix cannot be discovered
    def discover_network_prefix(node, interface)
      result = kind_exec(node, "ip --json addr show dev #{interface}")
      raise "Failed to discover network prefix on #{node}: #{result.message}" unless result.success?

      interfaces = JSON.parse(result.message)
      raise "No interface data for #{interface} on #{node}" unless interfaces.is_a?(Array) && !interfaces.empty?

      addr_info = interfaces.first.fetch("addr_info", [])
      ipv4 = addr_info.find { |a| a["family"] == "inet" && a["prefixlen"] != 32 }
      raise "No IPv4 address found on #{interface} on #{node}" unless ipv4

      ipv4["prefixlen"]
    end

    # Discover the network CIDR (address/prefix) of the primary IPv4 address on an interface
    #
    # @param node [String] node name
    # @param interface [String] network interface name
    # @return [String] network CIDR (e.g., "10.0.1.0/24")
    # @raise [RuntimeError] if CIDR cannot be discovered
    def discover_network_cidr(node, interface)
      result = kind_exec(node, "ip --json addr show dev #{interface}")
      raise "Failed to discover network CIDR on #{node}: #{result.message}" unless result.success?

      interfaces = JSON.parse(result.message)
      raise "No interface data for #{interface} on #{node}" unless interfaces.is_a?(Array) && !interfaces.empty?

      addr_info = interfaces.first.fetch("addr_info", [])
      ipv4 = addr_info.find { |a| a["family"] == "inet" && a["prefixlen"] != 32 }
      raise "No IPv4 address found on #{interface} on #{node}" unless ipv4

      prefix = ipv4["prefixlen"]
      ip = ipv4["local"]
      octets = ip.split(".").map(&:to_i)
      mask = prefix == 0 ? 0 : (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF
      ip_int = (octets[0] << 24) | (octets[1] << 16) | (octets[2] << 8) | octets[3]
      net_int = ip_int & mask
      network_cidr = "#{(net_int >> 24) & 0xFF}.#{(net_int >> 16) & 0xFF}.#{(net_int >> 8) & 0xFF}.#{net_int & 0xFF}"

      "#{network_cidr}/#{prefix}"
    end

    # Generate test virtual IP addresses in the same subnet as the gateway
    #
    # Uses high addresses (x.x.255.200+) to avoid conflicts with node IPs.
    #
    # @param gateway_ip [String] gateway IP address
    # @param count [Integer] number of IPs to generate
    # @return [Array<String>] list of test IP addresses
    def generate_test_vip_addresses(gateway_ip, count:)
      octets = gateway_ip.split(".").map(&:to_i)
      count.times.map do |i|
        [octets[0], octets[1], 255, 200 + i].join(".")
      end
    end

    # Wait for a DaemonSet to have all desired pods ready
    #
    # @param name [String] DaemonSet name
    # @param namespace [String] namespace of the DaemonSet
    # @param timeout [Integer] maximum seconds to wait (default: 120)
    # @return [Boolean] true if DaemonSet is ready
    def wait_for_daemonset_ready(name, namespace:, timeout: 120)
      timeout.times do
        output = kubectl_output(
          "get daemonset #{name} " \
          "--namespace=#{namespace} " \
          "--output=jsonpath='{.status.desiredNumberScheduled},{.status.numberReady},{.status.updatedNumberScheduled}'"
        )

        desired, ready, updated = output.gsub("'", "").split(",").map(&:to_i)
        return true if desired.positive? && desired == ready && desired == updated

        sleep 3
      end

      false
    end

    # Execute a wg command on a node via the agent pod (which has the wg binary)
    #
    # @param node [String] node name
    # @param args [String] arguments for the wg command
    # @return [TestResult] result of the command
    def wg_exec(node, args)
      agent_exec(node, "wg #{args}")
    end

    # Find the agent pod running on a specific node
    #
    # @param node [String] node name
    # @return [String, nil] pod name or nil
    def agent_pod_on_node(node)
      output = kubectl_output(
        "get pods --namespace=#{IntegrationTest::CONTROLLER_NAMESPACE} " \
        "--selector=app.kubernetes.io/component=agent " \
        "--field-selector=spec.nodeName=#{node} " \
        "--output=jsonpath='{.items[0].metadata.name}'"
      )
      result = output.gsub("'", "")
      result.empty? ? nil : result
    end

    # Run a shell script in the agent pod of a node, which has the wg binary.
    # An agent that stops its container after a failed hook is briefly not
    # there to exec into, so a failed exec is retried, looking the pod up
    # again each time.
    #
    # @param node [String] node name
    # @param script [String] shell script
    # @param attempts [Integer] attempts, 3 seconds apart
    # @return [String] the script's output
    # @raise [RuntimeError] if the script still fails after the last attempt
    def agent_shell!(node, script, attempts: 10)
      error = nil
      attempts.times do |attempt|
        sleep 3 if attempt.positive?
        pod = agent_pod_on_node(node)
        next error = "no agent pod" unless pod

        stdout, stderr, status = Open3.capture3(
          "docker", "exec", IntegrationTest::CONTROL_PLANE_CONTAINER,
          "kubectl", "exec", pod, "--namespace=#{IntegrationTest::CONTROLLER_NAMESPACE}", "--", "sh", "-c", script
        )
        return stdout.strip if status.success?

        error = stderr.strip
      end

      raise "Agent pod on #{node} failed to run #{script.inspect} #{attempts} times: #{error}"
    end

    # Generate a WireGuard key pair via the agent pod
    #
    # @param node [String] node name to run on
    # @return [Array(String, String)] [private_key, public_key]
    def generate_wireguard_keypair(node)
      private_key = agent_shell!(node, "wg genkey")

      [private_key, agent_shell!(node, "echo '#{private_key}' | wg pubkey")]
    end

    # Create a WireGuard interface on a node
    #
    # @param node [String] node name
    # @param interface [String] interface name
    # @param private_key [String] WireGuard private key
    def setup_wireguard_interface(node, interface, private_key:)
      kind_exec(node, "ip link add #{interface} type wireguard")
      # Write key to agent pod's /tmp, set private key, clean up
      agent_shell!(node, "echo '#{private_key}' > /tmp/wg-key-#{interface} && " \
                         "wg set #{interface} private-key /tmp/wg-key-#{interface} && " \
                         "rm -f /tmp/wg-key-#{interface}")
      kind_exec(node, "ip link set #{interface} up")
    end

    # Add a WireGuard peer to an interface
    #
    # @param node [String] node name
    # @param interface [String] interface name
    # @param public_key [String] peer's public key
    # @param allowed_ips [String] comma-separated allowed IPs
    def add_wireguard_peer(node, interface, public_key:, allowed_ips:)
      agent_shell!(node, "wg set #{interface} peer #{public_key} allowed-ips #{allowed_ips}")
    end

    # Get allowed IPs for a specific WireGuard peer
    #
    # @param node [String] node name
    # @param interface [String] interface name
    # @param public_key [String] peer's public key
    # @return [Array<String>] list of allowed IPs
    def get_wireguard_allowed_ips(node, interface, public_key:)
      result = wg_exec(node, "show #{interface} dump")
      return [] unless result.success?

      result.message.each_line.drop(1).each do |line|
        fields = line.split("\t")
        next if fields.size < 4
        next unless fields[0].strip == public_key

        return fields[3].split(",").map(&:strip).reject(&:empty?)
      end

      []
    end

    # Wait for a WireGuard allowed IP to appear
    #
    # @param node [String] node name
    # @param interface [String] interface name
    # @param public_key [String] peer's public key
    # @param ip [String] expected allowed IP (e.g., "10.0.0.0/16")
    # @param timeout [Integer] maximum seconds to wait (default: 30)
    # @return [Boolean] true if IP appeared
    def wait_for_wireguard_allowed_ip(node, interface, public_key:, ip:, timeout: 30)
      timeout.times do
        ips = get_wireguard_allowed_ips(node, interface, public_key: public_key)
        return true if ips.include?(ip)

        sleep 3
      end

      false
    end

    # Wait for a WireGuard allowed IP to be removed
    #
    # @param node [String] node name
    # @param interface [String] interface name
    # @param public_key [String] peer's public key
    # @param ip [String] IP expected to be removed
    # @param timeout [Integer] maximum seconds to wait (default: 30)
    # @return [Boolean] true if IP was removed
    def wait_for_wireguard_allowed_ip_removal(node, interface, public_key:, ip:, timeout: 30)
      timeout.times do
        ips = get_wireguard_allowed_ips(node, interface, public_key: public_key)
        return true unless ips.include?(ip)

        sleep 3
      end

      false
    end

    # Remove a WireGuard interface from a node
    #
    # @param node [String] node name
    # @param interface [String] interface name
    def cleanup_wireguard_interface(node, interface)
      kind_exec(node, "ip link del #{interface} 2>/dev/null")
    end
  end
end
