# frozen_string_literal: true

require_relative "base"

module Demo
  module Checks
    # Three virtual IPs on one Service. When the node that holds one loses its
    # pods, the controller moves its addresses to a node with a ready endpoint.
    class Failover < Base
      NAMESPACE = "netwrangler-failover"
      ADDRESSES = %w[10.89.1.210 10.89.1.211 10.89.1.212].freeze
      SELECTOR = "app=whoami"

      # How long the controller may take to move the addresses off the node, in seconds.
      MOVE_TIMEOUT = 90

      # @param report [Report]
      def run(report)
        @cordoned = nil
        report.check("a request from #{PUBLIC_NETWORK} to each of #{ADDRESSES.join(", ")} answers") do
          all_answer
        end
        node = nil
        begin
          report.check("a node holding #{ADDRESSES.first} is cordoned and its failover pods are deleted") do
            node = fail_node
            true
          end
          if node
            report.check("within #{MOVE_TIMEOUT} s no failover VipAddress names #{node}") { wait_until_moved(node) }
            report.check("all three addresses answer again") { all_answer }
          end
        ensure
          uncordon(@cordoned) if @cordoned
        end
      end

      private

      # Uncordon a worker that an aborted earlier run left cordoned. The control
      # plane is not touched, as the demo never cordons it.
      def uncordon_workers
        @shell.workers.each { |worker| uncordon(worker) if cordoned?(worker) }
      end

      def cordoned?(node)
        @shell.kubectl!("get", "node", node, "--output", "jsonpath={.spec.unschedulable}").strip == "true"
      end

      def uncordon(node) = @shell.kubectl!("uncordon", node)

      def all_answer
        failures = ADDRESSES.filter_map do |address|
          outcome = answers("Hostname: whoami-") { @traffic.from_network(PUBLIC_NETWORK, "http://#{address}/") }
          "#{address}: #{outcome}" unless outcome == true
        end
        failures.empty? || failures.join(" / ")
      end

      # Uncordon what an aborted earlier run left cordoned, then cordon the node
      # of the first address and delete the failover pods on it.
      #
      # @return [String] the node
      # @raise [RuntimeError] when no VipAddress names a node for the first address
      def fail_node
        uncordon_workers
        node = wait_for_vip_node(NAMESPACE, ADDRESSES.first)
        raise no_vip_node(ADDRESSES.first) unless node

        @cordoned = node
        @shell.kubectl!("cordon", node)
        pods = running_pods(NAMESPACE, selector: SELECTOR, node: node)
        return node if pods.empty?

        @shell.kubectl!("delete", "pod", "--namespace", NAMESPACE, "--wait=false", *pods)
        node
      end

      def wait_until_moved(node)
        remaining = []
        moved = Wait.until(timeout: MOVE_TIMEOUT) do
          remaining = vip_addresses(NAMESPACE).select { |item| item.dig("spec", "nodeName") == node }
          remaining.empty?
        end
        moved || "#{remaining.map { |item| item.dig("spec", "virtualCIDR") }.join(", ")} still on #{node}"
      end
    end
  end
end
