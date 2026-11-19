# frozen_string_literal: true

require "json"
require_relative "base"

module Demo
  module Checks
    # Traffic for a destination network goes through a gateway pod. The pod
    # answers on an address in the destination itself, so a client pod on
    # another node that gets the gateway pod's answer took the gateway route.
    class GatewayRouting < Base
      NAMESPACE = "netwrangler-gateway-routing"
      GATEWAY = "demo-gateway"
      DESTINATION = "10.90.1.0/24"
      ADDRESS = "10.90.1.1"
      CLIENT_SELECTOR = "app=client"

      # How long the controller may take to create the VipRoute, in seconds.
      ROUTE_TIMEOUT = 60

      # @param report [Report]
      def run(report)
        gateway = gateway_pod
        report.check("a VipRoute for #{gateway_name} names the gateway pod's IP") { vip_route(gateway) }
        report.check("a request from the client pod to #{url} answers with the gateway pod's hostname") do
          answer_from_gateway(gateway)
        end
      end

      private

      def namespace = self.class::NAMESPACE
      def gateway_name = self.class::GATEWAY
      def url = "http://#{self.class::ADDRESS}/"

      # The running gateway pod, or why there is none.
      #
      # @return [Hash, String]
      def gateway_pod
        pods = running_pod_objects(namespace, selector: "app=#{gateway_name}")
        return pods.first if pods.size == 1

        "#{pods.size} running pods with app=#{gateway_name} in #{namespace}, expected 1"
      rescue StandardError => e
        "#{e.class}: #{e.message}"
      end

      def pod_ip(pod) = pod.dig("status", "podIP")
      def pod_node(pod) = pod.dig("spec", "nodeName")
      def pod_name(pod) = pod.dig("metadata", "name")

      # Wait for the VipRoute of the gateway pod: its destination and pod IP.
      def vip_route(gateway)
        return gateway if gateway.is_a?(String)

        routes = []
        found = Wait.until(timeout: ROUTE_TIMEOUT) do
          result = @shell.kubectl("get", "viproutes", "--namespace", namespace, "--output", "json")
          routes = result.success? ? JSON.parse(result.stdout).fetch("items").map { |item| item["spec"] } : []
          routes.any? do |spec|
            spec["destinationCIDR"] == self.class::DESTINATION && spec["podIP"] == pod_ip(gateway)
          end
        end
        found || "no VipRoute for #{self.class::DESTINATION} via #{pod_ip(gateway)} within #{ROUTE_TIMEOUT} s; " \
                 "found #{routes.map { |spec| "#{spec["destinationCIDR"]} via #{spec["podIP"]}" }.inspect}"
      end

      # Request the destination from the client pod, which runs on another node
      # than the gateway pod.
      def answer_from_gateway(gateway)
        client = client_pod(gateway)
        return client if client.is_a?(String)

        answers("Hostname: #{pod_name(gateway)}") { @traffic.from_pod(namespace, pod_name(client), url) }
      end

      # The running client pod, or why there is none on another node than the
      # gateway pod.
      #
      # @return [Hash, String]
      def client_pod(gateway)
        return gateway if gateway.is_a?(String)

        client = running_pod_objects(namespace, selector: CLIENT_SELECTOR).first
        return "no running pod with #{CLIENT_SELECTOR} in #{namespace}" unless client
        return "the client pod runs on the gateway pod's node #{pod_node(gateway)}" if pod_node(client) == pod_node(gateway)

        client
      end
    end
  end
end
