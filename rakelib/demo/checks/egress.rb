# frozen_string_literal: true

require_relative "base"

module Demo
  module Checks
    # Pods behind an egress-enabled Service leave the cluster with the virtual IP
    # of their node as source address. Only the node that holds the address
    # rewrites to it, so the request comes from the pod on that node.
    class Egress < Base
      NAMESPACE = "netwrangler-egress"
      ADDRESS = "10.89.1.201"
      SELECTOR = "app=client"

      # @param report [Report]
      def run(report)
        url = "http://#{Traffic::SERVER_ADDRESS}/"
        report.check("a request from the client pod on the node holding #{ADDRESS} to #{url} " \
                     "comes from #{ADDRESS}") do
          @traffic.ensure_server
          request_from_holder(url)
        end
        report.check("the VipAddress for #{ADDRESS} has egressEnabled: true") do
          enabled = vip_address(NAMESPACE, ADDRESS)&.dig("spec", "egressEnabled")
          enabled == true || "egressEnabled is #{enabled.inspect}"
        end
      end

      private

      def request_from_holder(url)
        node = wait_for_vip_node(NAMESPACE, ADDRESS)
        return no_vip_node(ADDRESS) unless node

        pod = running_pods(NAMESPACE, selector: SELECTOR, node: node).first
        return "no running pod with #{SELECTOR} on #{node}" unless pod

        answers("RemoteAddr: #{ADDRESS}:") { @traffic.from_pod(NAMESPACE, pod, url) }
      end
    end
  end
end
