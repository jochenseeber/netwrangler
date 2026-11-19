# frozen_string_literal: true

require_relative "deployment"
require_relative "manifests"
require_relative "report"
require_relative "checks/egress"
require_relative "checks/failover"
require_relative "checks/gateway_routing"
require_relative "checks/gateway_routing_wireguard"
require_relative "checks/ingress"
require_relative "checks/several_networks"

module Demo
  # One directory of `examples/`, and the +checks_class+ that proves with real
  # traffic that it works.
  Example = Data.define(:name, :checks_class) do
    # Where its manifests are, relative to the project.
    def directory = "examples/#{name}"

    # The namespace its manifests live in.
    def namespace = checks_class::NAMESPACE

    # Apply the example, wait until its Deployments have rolled out and run its
    # checks. The example stays applied.
    #
    # @param shell [KindCluster::NodeShell]
    # @param traffic [Traffic]
    # @param output [IO] where the check lines go
    # @return [Report]
    def run(shell:, traffic:, output: $stdout)
      output.puts "#{name}: applying #{directory}"
      shell.kubectl!("apply", "--filename", "-", input: Manifests.stream(directory))
      Deployment.wait_for_rollouts(shell, namespace, kinds: %w[deployment], timeout: ROLLOUT_TIMEOUT)
      traffic.ensure_client_image
      Report.new(output: output).tap { |report| checks_class.new(shell: shell, traffic: traffic).run(report) }
    end
  end

  # How long an example's Deployment may take to roll out, image pull included.
  ROLLOUT_TIMEOUT = "180s"

  # The examples, in the order `rake demo:deploy` runs them.
  EXAMPLES = [
    Example.new(name: "ingress", checks_class: Checks::Ingress),
    Example.new(name: "egress", checks_class: Checks::Egress),
    Example.new(name: "several-networks", checks_class: Checks::SeveralNetworks),
    Example.new(name: "failover", checks_class: Checks::Failover),
    Example.new(name: "gateway-routing", checks_class: Checks::GatewayRouting),
    Example.new(name: "gateway-routing-wireguard", checks_class: Checks::GatewayRoutingWireguard),
  ].freeze
end
