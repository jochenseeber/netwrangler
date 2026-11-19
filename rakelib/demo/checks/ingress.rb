# frozen_string_literal: true

require_relative "base"

module Demo
  module Checks
    # A Service's external IP placed on a node and reached from outside the
    # cluster.
    class Ingress < Base
      NAMESPACE = "netwrangler-ingress"
      ADDRESS = "10.89.1.200"

      # @param report [Report]
      def run(report)
        report.check("within #{VIP_ADDRESS_TIMEOUT} s a VipAddress for #{ADDRESS} exists in #{NAMESPACE} " \
                     "and names a node") do
          wait_for_vip_node(NAMESPACE, ADDRESS) ? true : no_vip_node(ADDRESS)
        end
        report.check("a request from #{PUBLIC_NETWORK} to http://#{ADDRESS}/ answers with Hostname: whoami-") do
          answers("Hostname: whoami-") { @traffic.from_network(PUBLIC_NETWORK, "http://#{ADDRESS}/") }
        end
      end
    end
  end
end
