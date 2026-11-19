# frozen_string_literal: true

require "json"
require_relative "../../kind_cluster/demo_networks"
require_relative "../traffic"
require_relative "../wait"

module Demo
  # The checks of each example, one class per example.
  module Checks
    # What the checks of every example share: the shell and the traffic they send,
    # and lookups of the objects the controller creates.
    class Base
      # How long the controller may take to create a VipAddress that names a
      # node and network, in seconds.
      VIP_ADDRESS_TIMEOUT = 60

      # The Docker network that stands for the outside world, where the
      # requests to an ingress address come from.
      PUBLIC_NETWORK = KindCluster::DemoNetworks::PUBLIC.name

      # @param shell [KindCluster::NodeShell]
      # @param traffic [Traffic]
      def initialize(shell:, traffic:)
        @shell = shell
        @traffic = traffic
      end

      private

      # The VipAddresses in +namespace+, as parsed JSON objects.
      def vip_addresses(namespace)
        JSON.parse(@shell.kubectl!("get", "vipaddresses", "--namespace", namespace, "--output", "json")).fetch("items")
      end

      # The VipAddress in +namespace+ whose virtual IP is +address+, or nil.
      def vip_address(namespace, address) = with_address(vip_addresses(namespace), address)

      # Wait up to VIP_ADDRESS_TIMEOUT seconds for the VipAddress of +address+
      # to name a node. A failed lookup, such as a passing API server error,
      # counts as not yet.
      #
      # @return [String, nil] the node, or nil when none came in time
      def wait_for_vip_node(namespace, address)
        node = nil
        Wait.until(timeout: VIP_ADDRESS_TIMEOUT) do
          result = @shell.kubectl("get", "vipaddresses", "--namespace", namespace, "--output", "json")
          node = result.success? ? with_address(JSON.parse(result.stdout).fetch("items"), address) : nil
          node = node&.dig("spec", "nodeName")
          !node.to_s.empty?
        end
        node.to_s.empty? ? nil : node
      end

      # Why {#wait_for_vip_node} found no node for +address+.
      def no_vip_node(address) = "no VipAddress for #{address} named a node within #{VIP_ADDRESS_TIMEOUT} s"

      # The names of the running pods in +namespace+ that match the label
      # selector +selector+ (`app=client`) and run on +node+.
      #
      # @return [Array<String>]
      def running_pods(namespace, selector:, node:)
        running_pod_objects(namespace, selector: selector, node: node).map { |pod| pod.dig("metadata", "name") }
      end

      # The running pods in +namespace+ that match the label selector
      # +selector+, on +node+ or, without one, on any node, as parsed JSON
      # objects. A pod that is being deleted does not count.
      #
      # @return [Array<Hash>]
      def running_pod_objects(namespace, selector:, node: nil)
        fields = ["status.phase=Running", *("spec.nodeName=#{node}" if node)].join(",")
        output = @shell.kubectl!("get", "pods", "--namespace", namespace, "--selector", selector,
                                 "--field-selector", fields, "--output", "json")
        JSON.parse(output).fetch("items").reject { |pod| pod.dig("metadata", "deletionTimestamp") }
      end

      # The VipAddress among +items+ whose virtual IP is +address+, or nil.
      def with_address(items, address)
        items.find { |item| item.dig("spec", "virtualCIDR").to_s.split("/").first == address }
      end

      # Send requests with the block until one answers with a body that contains
      # +expected+, for at most +timeout+ seconds. The block returns a
      # KindCluster::CommandResult.
      #
      # @return [true, String] true, or why no request got that answer
      def answers(expected, timeout: 30)
        result = nil
        answered = Wait.until(timeout: timeout) do
          result = yield
          result.success? && result.stdout.include?(expected)
        end
        answered || "no answer with #{expected.inspect} in #{timeout} s; last request #{Traffic.describe(result)}"
      end
    end
  end
end
