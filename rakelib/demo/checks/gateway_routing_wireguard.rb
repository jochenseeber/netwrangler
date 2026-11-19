# frozen_string_literal: true

require "json"
require_relative "../../kind_cluster/wireguard_mesh"
require_relative "gateway_routing"

module Demo
  module Checks
    # Like GatewayRouting, but the other nodes reach the gateway pod through the
    # WireGuard mesh. A host route for the pod's IP through wg-demo, which the
    # demo adds on every node but the pod's, makes the agent see the pod behind
    # a WireGuard peer, so it adds the destination to that peer's allowed IPs.
    class GatewayRoutingWireguard < GatewayRouting
      NAMESPACE = "netwrangler-gateway-routing-wireguard"
      GATEWAY = "demo-gateway-wireguard"
      DESTINATION = "10.90.2.0/24"
      ADDRESS = "10.90.2.1"
      TABLE = 201

      # How long the agents may take to add the destination to the allowed IPs,
      # in seconds. They re-resolve pod routes on events and on their 30 s resync.
      ALLOWED_IPS_TIMEOUT = 90

      # @param report [Report]
      def run(report)
        mesh = KindCluster::WireguardMesh.new(shell: @shell)
        gateway = gateway_pod
        report.check("on every node but the gateway pod's, the pod's IP routes through " \
                     "#{KindCluster::WireguardMesh::INTERFACE}") do
          route_through_mesh(mesh, gateway)
        end
        report.check("a VipRoute for #{gateway_name} names the gateway pod's IP") { vip_route(gateway) }
        report.check("on every other node the peer of the gateway pod's node allows #{DESTINATION}") do
          allowed_on_every_node(mesh, gateway)
        end
        report.check("the client pod's node routes #{DESTINATION} in table #{TABLE} through " \
                     "#{KindCluster::WireguardMesh::INTERFACE}") do
          client_route_through_mesh(gateway)
        end
        report.check("a request from the client pod to #{url} answers with the gateway pod's hostname " \
                     "and goes out through #{KindCluster::WireguardMesh::INTERFACE}") do
          answer_through_mesh(mesh, gateway)
        end
      end

      private

      # The nodes that reach the gateway pod through the mesh.
      def other_nodes(gateway) = @shell.nodes - [pod_node(gateway)]

      # Replace the host routes through the mesh with one for the gateway pod's
      # current IP on every node but its own; a restarted pod has another IP.
      # Then ask the kernel how each node reaches the pod.
      def route_through_mesh(mesh, gateway)
        return gateway if gateway.is_a?(String)

        address = pod_ip(gateway)
        @shell.nodes.each do |node|
          wanted = node == pod_node(gateway) ? [] : [address]
          (mesh.host_routes(node) - wanted).each { |stale| mesh.remove_host_route(node, stale) }
          wanted.each { |host| mesh.add_host_route(node, host) }
        end
        failures = other_nodes(gateway).filter_map do |node|
          route = JSON.parse(@shell.run!(node, "ip -json route get #{address}")).first || {}
          "#{node} routes #{address} through #{route["dev"].inspect}" unless route["dev"] == KindCluster::WireguardMesh::INTERFACE
        end
        failures.empty? || failures.join(" / ")
      end

      # Wait until on every node but the gateway pod's the peer for that node
      # lists the destination in its allowed IPs.
      def allowed_on_every_node(mesh, gateway)
        return gateway if gateway.is_a?(String)

        key = mesh.public_key(pod_node(gateway))
        missing = []
        allowed = Wait.until(timeout: ALLOWED_IPS_TIMEOUT, interval: 5) do
          missing = other_nodes(gateway).reject { |node| mesh.allowed_ips(node).fetch(key, []).include?(DESTINATION) }
          missing.empty?
        end
        allowed || "the peer of #{pod_node(gateway)} lacks #{DESTINATION} on #{missing.join(", ")} " \
                   "after #{ALLOWED_IPS_TIMEOUT} s"
      end

      # Wait until the agent on the client pod's node routes the destination
      # through the mesh. The peer can keep the destination in its allowed IPs
      # while the agent routes it over eth0, such as when it resolved a new pod
      # IP before the host route existed; then the request would not prove the
      # tunnel.
      def client_route_through_mesh(gateway)
        client = client_pod(gateway)
        return client if client.is_a?(String)

        node = pod_node(client)
        devices = []
        routed = Wait.until(timeout: ALLOWED_IPS_TIMEOUT, interval: 5) do
          devices = destination_devices(node)
          devices.include?(KindCluster::WireguardMesh::INTERFACE)
        end
        routed || "#{node} routes #{DESTINATION} in table #{TABLE} through #{devices.inspect} " \
                  "after #{ALLOWED_IPS_TIMEOUT} s"
      end

      # The devices of the unicast routes for the destination in the gateway's
      # table on +node+. A missing table counts as none.
      def destination_devices(node)
        result = @shell.run(node, "ip -json route show table #{TABLE} #{DESTINATION}")
        return [] unless result.success? && !result.stdout.strip.empty?

        JSON.parse(result.stdout).reject { |route| route["type"] == "unreachable" }.map { |route| route["dev"] }
      end

      # Request the destination and confirm that the client pod's node sent
      # bytes to the gateway pod's node through the mesh meanwhile.
      def answer_through_mesh(mesh, gateway)
        client = client_pod(gateway)
        return client if client.is_a?(String)

        node = pod_node(client)
        key = mesh.public_key(pod_node(gateway))
        before = mesh.sent_bytes(node, key)
        outcome = answers("Hostname: #{pod_name(gateway)}") { @traffic.from_pod(namespace, pod_name(client), url) }
        return outcome unless outcome == true

        after = mesh.sent_bytes(node, key)
        after > before || "answered, but #{node} sent nothing to the peer of #{pod_node(gateway)} " \
                          "(#{before} bytes before and after)"
      end
    end
  end
end
