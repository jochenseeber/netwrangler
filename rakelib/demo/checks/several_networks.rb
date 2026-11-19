# frozen_string_literal: true

require_relative "base"

module Demo
  module Checks
    # One Service with a virtual IP on each of two networks, each reached from
    # its own network.
    class SeveralNetworks < Base
      NAMESPACE = "netwrangler-several-networks"

      # The Service's addresses, by the VipNetwork each belongs to.
      ADDRESSES = {
        "public" => "10.89.1.220",
        "private" => "10.89.2.220",
      }.freeze

      # The Docker network each VipNetwork's addresses are reached from.
      DOCKER_NETWORKS = {
        "public" => KindCluster::DemoNetworks::PUBLIC.name,
        "private" => KindCluster::DemoNetworks::PRIVATE.name,
      }.freeze

      # @param report [Report]
      def run(report)
        ADDRESSES.each do |network, address|
          docker_network = DOCKER_NETWORKS.fetch(network)
          report.check("a request from #{docker_network} to http://#{address}/ answers with Hostname: whoami-") do
            answers("Hostname: whoami-") { @traffic.from_network(docker_network, "http://#{address}/") }
          end
        end
        report.check("within #{VIP_ADDRESS_TIMEOUT} s the VipAddresses of #{ADDRESSES.values.join(" and ")} " \
                     "name the networks #{ADDRESSES.keys.join(" and ")}") do
          networks_named
        end
      end

      private

      # Wait up to VIP_ADDRESS_TIMEOUT seconds for each address's VipAddress to
      # name its network.
      def networks_named
        named = {}
        Wait.until(timeout: VIP_ADDRESS_TIMEOUT) do
          items = vip_addresses(NAMESPACE)
          named = ADDRESSES.transform_values { |address| with_address(items, address)&.dig("spec", "network") }
          named.all? { |network, actual| actual == network }
        end
        mismatches = named.reject { |network, actual| actual == network }
        mismatches.empty? || mismatches.map { |network, actual| "#{ADDRESSES[network]} names #{actual.inspect}" }.join(", ")
      end
    end
  end
end
