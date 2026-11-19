# frozen_string_literal: true

require "json"
require_relative "node_shell"

module KindCluster
  # A standing WireGuard mesh between the kind nodes: one +wg-demo+ interface per
  # node and a peer for each other node, which may route that node's pod network
  # and its +eth0+ address. The demo's WireGuard gateway and the WireGuard
  # integration spec both run on it.
  class WireguardMesh
    INTERFACE = "wg-demo"
    PORT = 51_820

    # The interfaces that check reverse paths loosely: the mesh's, and +eth0+,
    # where the answers to what a node sends through the mesh come back.
    LOOSE_INTERFACES = [INTERFACE, "eth0"].freeze

    # What the mesh needs to know about one node.
    Member = Data.define(:node, :address, :pod_cidr) do
      # The peer's endpoint as `wg show` prints it.
      def endpoint = "#{address}:#{PORT}"

      # The networks a peer for this node may route.
      def allowed_ips = [pod_cidr, "#{address}/32"]
    end

    # @param shell [NodeShell]
    # @param output [IO] where progress goes
    def initialize(shell:, output: $stdout)
      @shell = shell
      @output = output
    end

    # Rebuild the mesh when a node lacks the interface or a peer's endpoint is not
    # the current +eth0+ address of its node (a restarted node may have another);
    # do nothing otherwise.
    def ensure
      members = @shell.nodes.map { |node| member(node) }
      if intact?(members)
        @output.puts "WireGuard mesh #{INTERFACE} up to date"
      else
        rebuild(members)
        @output.puts "WireGuard mesh #{INTERFACE} built for #{members.map(&:node).join(", ")}"
      end
    end

    # The public key of a node's interface.
    #
    # @return [String]
    def public_key(node) = @shell.run!(node, "wg show #{INTERFACE} public-key").strip

    # Remove +cidr+ from the allowed IPs of every peer on every node, keeping the
    # rest of each peer's list. A node without the interface has nothing to remove.
    def remove_allowed_ip(cidr)
      @shell.nodes.each do |node|
        next unless interface?(node)

        allowed_ips(node).each do |key, ips|
          next unless ips.include?(cidr)

          set_allowed_ips(node, key, ips - [cidr])
        end
      end
    end

    # Whether +node+ has the interface.
    def interface?(node) = @shell.run(node, "ip link show #{INTERFACE}").success?

    # The allowed IPs of a node's peers, by peer public key.
    #
    # @return [Hash{String => Array<String>}]
    def allowed_ips(node)
      @shell.run!(node, "wg show #{INTERFACE} allowed-ips").lines.to_h do |line|
        key, ips = line.chomp.split("\t", 2)
        [key, ips.to_s.split.reject { |ip| ip == "(none)" }]
      end
    end

    # How many bytes a node has sent to the peer with the public key +key+.
    #
    # @return [Integer]
    def sent_bytes(node, key)
      line = @shell.run!(node, "wg show #{INTERFACE} transfer").lines.find { |entry| entry.start_with?("#{key}\t") }
      raise "#{node} has no #{INTERFACE} peer #{key}" if line.nil?

      line.split("\t")[2].to_i
    end

    # The addresses that a node routes through the interface with a host route
    # (`<address>/32 dev wg-demo`). The mesh itself routes nothing through it.
    #
    # @return [Array<String>]
    def host_routes(node)
      routes = JSON.parse(@shell.run!(node, "ip -json route show dev #{INTERFACE}"))
      routes.map { |route| route["dst"].to_s }.reject { |dst| dst.include?("/") || dst == "default" }
    end

    # Route +address+ through the interface on +node+.
    def add_host_route(node, address) = @shell.run!(node, "ip route replace #{address}/32 dev #{INTERFACE}")

    # Delete the host route of +address+ through the interface on +node+.
    def remove_host_route(node, address) = @shell.run!(node, "ip route del #{address}/32 dev #{INTERFACE}")

    private

    def member(node)
      address = JSON.parse(@shell.run!(node, "ip -json -4 addr show eth0")).dig(0, "addr_info", 0, "local")
      raise "#{node} has no IPv4 address on eth0" if address.nil?

      pod_cidr = @shell.kubectl!("get", "node", node, "-o", "jsonpath={.spec.podCIDR}").strip
      raise "node #{node} has no pod CIDR" if pod_cidr.empty?

      Member.new(node: node, address: address, pod_cidr: pod_cidr)
    end

    def intact?(members)
      members.all? do |member|
        others = members - [member]
        endpoints = peer_endpoints(member.node)
        !endpoints.nil? && endpoints.sort == others.map(&:endpoint).sort && reverse_paths_set?(member)
      end
    end

    # The endpoints of a node's peers, or nil when it has no such interface.
    def peer_endpoints(node)
      result = @shell.run(node, "wg show #{INTERFACE} endpoints")
      return nil unless result.success?

      result.stdout.lines.map { |line| line.split("\t")[1].to_s.strip }
    end

    # Whether the node's interface has its +eth0+ address and both interfaces
    # check reverse paths loosely; see {#create_interface}.
    def reverse_paths_set?(member)
      interface_addresses(member.node) == ["#{member.address}/32"] &&
        LOOSE_INTERFACES.all? { |name| rp_filter(member.node, name) == "2" }
    end

    # The IPv4 addresses of a node's interface, with their prefix lengths.
    def interface_addresses(node)
      links = JSON.parse(@shell.run!(node, "ip -json -4 addr show #{INTERFACE}"))
      links.flat_map { |link| link["addr_info"] || [] }.map { |info| "#{info["local"]}/#{info["prefixlen"]}" }
    end

    def rp_filter(node, name) = @shell.run(node, "sysctl -n net.ipv4.conf.#{name}.rp_filter").stdout.strip

    def rebuild(members)
      members.each { |member| create_interface(member) }
      keys = members.to_h { |member| [member.node, public_key(member.node)] }
      members.each do |member|
        (members - [member]).each do |other|
          @shell.run!(member.node, "wg set #{INTERFACE} peer #{keys.fetch(other.node)} " \
                                   "endpoint #{other.endpoint} allowed-ips #{other.allowed_ips.join(",")}")
        end
      end
    end

    # The key is generated and handed over on the node, so it never leaves it and
    # never lands in a file.
    #
    # The interface carries the node's +eth0+ address as a /32, which adds a
    # second `local` entry for it to the local table and no route to the main
    # one. With rp_filter on, strict or loose, the kernel drops a packet that
    # arrives on an interface without an IPv4 address unless its source routes
    # back through that interface. The mesh routes only pod IPs and the
    # destination through it, so without the address the receiving node drops
    # the masqueraded traffic from the mesh. kind-masq-agent masquerades pod
    # traffic leaving through the interface to that address, which the peers
    # allow.
    #
    # The answer to a packet sent through the mesh comes back on +eth0+, while
    # the sender routes the answer's source through the mesh, so strict reverse
    # path filtering on +eth0+ drops it. Loose filtering on both interfaces lets
    # it pass. The effective setting is the higher of `all` and the
    # interface's, so `all` stays as it is.
    def create_interface(member)
      node = member.node
      @shell.run!(node, "ip link del #{INTERFACE} 2>/dev/null; ip link add #{INTERFACE} type wireguard")
      @shell.run!(node, "wg genkey | wg set #{INTERFACE} listen-port #{PORT} private-key /dev/stdin")
      @shell.run!(node, "ip addr add #{member.address}/32 dev #{INTERFACE}")
      @shell.run!(node, "ip link set #{INTERFACE} up")
      LOOSE_INTERFACES.each { |name| @shell.run!(node, "sysctl -w net.ipv4.conf.#{name}.rp_filter=2") }
    end

    def set_allowed_ips(node, key, ips)
      @shell.run!(node, "wg set #{INTERFACE} peer #{key} allowed-ips '#{ips.join(",")}'")
    end
  end
end
