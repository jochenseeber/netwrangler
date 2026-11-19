# frozen_string_literal: true

require_relative "../kind_cluster/node_shell"
require_relative "../kind_cluster/wireguard_mesh"
require_relative "checks/gateway_routing_wireguard"
require_relative "manifests"
require_relative "traffic"

module Demo
  # Removes everything the demo put on the cluster, in the order the controller
  # and the agents need to clean up after it. The Docker networks and the
  # WireGuard mesh stay; the integration tests use them too.
  class Cleanup
    # How long the namespaces may take to go, with the VipAddresses and
    # VipRoutes in them.
    NAMESPACE_TIMEOUT = "180s"

    # What kubectl says when a kind or resource type is unknown: the CRDs are
    # absent, so there is nothing of that type to delete.
    UNKNOWN_TYPE = %r{doesn't have a resource type|no matches for kind}

    # @param shell [KindCluster::NodeShell]
    # @param mesh [KindCluster::WireguardMesh]
    # @param output [IO] where progress goes
    def initialize(shell:, mesh:, output: $stdout)
      @shell = shell
      @mesh = mesh
      @output = output
    end

    # Delete the example namespaces, which takes the VipAddresses and VipRoutes
    # in them along, and the gateways, then the WireGuard example's host routes
    # and allowed IPs, the cluster-wide configuration and the egress server
    # container. Does nothing for what is already gone.
    def run
      delete_namespaces
      delete_gateways
      clean_mesh
      delete_cluster_objects
      remove_server
      @output.puts "demo removed"
    end

    private

    def delete_namespaces
      namespaces = example_objects("Namespace")
      @output.puts "deleting namespaces #{namespaces.join(", ")}"
      @shell.kubectl!("delete", "namespace", *namespaces, "--ignore-not-found", "--wait", "--timeout",
                      NAMESPACE_TIMEOUT)
    end

    def delete_gateways
      gateways = example_objects("VipGateway")
      return if gateways.empty?

      @output.puts "deleting VipGateways #{gateways.join(", ")}"
      tolerate_unknown_type(@shell.kubectl("delete", "vipgateways", *gateways, "--ignore-not-found"))
    end

    # The agents remove the destination from the allowed IPs they added, but a
    # restarted agent has forgotten them; the host routes are the demo's own.
    def clean_mesh
      @shell.nodes.each do |node|
        next unless @mesh.interface?(node)

        @mesh.host_routes(node).each do |address|
          @output.puts "#{node}: deleting route #{address}/32 dev #{KindCluster::WireguardMesh::INTERFACE}"
          @mesh.remove_host_route(node, address)
        end
      end
      @mesh.remove_allowed_ip(Checks::GatewayRoutingWireguard::DESTINATION)
    end

    def delete_cluster_objects
      @output.puts "deleting examples/cluster"
      tolerate_unknown_type(@shell.kubectl("delete", "--ignore-not-found", "--filename", "-",
                                           input: Manifests.stream("examples/cluster")))
    end

    def remove_server
      return unless @shell.docker("container", "inspect", Traffic::SERVER).success?

      result = @shell.docker("rm", "--force", Traffic::SERVER)
      raise "docker rm #{Traffic::SERVER} failed: #{result.stderr.strip}" unless result.success?

      @output.puts "removed container #{Traffic::SERVER}"
    end

    # The names of the objects of +kind+ in the example directories.
    def example_objects(kind) = Manifests.objects([kind], exclude: ["cluster"]).map(&:last)

    # Raise when +result+ failed for another reason than an unknown resource type.
    def tolerate_unknown_type(result)
      return if result.success? || result.stderr.match?(UNKNOWN_TYPE)

      raise "kubectl failed with #{result.exit_code}: #{result.stderr.strip}"
    end
  end
end
