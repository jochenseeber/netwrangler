require "json"
require "./resource"

module Netwrangler::Model
  # Custom resource representing a VIP route
  class VipRoute < Resource
    class Spec
      include JSON::Serializable

      @[JSON::Field(key: "destinationCIDR")]
      property destination_cidr : String

      @[JSON::Field(key: "gatewayNode")]
      property gateway_node : String

      @[JSON::Field(key: "podIP")]
      property pod_ip : String

      @[JSON::Field(key: "routeTable")]
      property route_table : Int32

      @[JSON::Field(key: "routingPriority")]
      property routing_priority : Int32

      def initialize(*, @destination_cidr, @gateway_node, @pod_ip, @route_table, @routing_priority)
      end

      def_equals @destination_cidr, @gateway_node, @pod_ip, @route_table, @routing_priority
      def_clone
    end

    @[JSON::Field(key: "spec")]
    property spec : Spec

    def initialize(*, @metadata : ObjectMeta, @spec : Spec)
      super(api_version: "netwrangler.dev/v1", kind: "VipRoute", metadata: @metadata)
    end

    # Convenience accessors
    def destination_cidr : String
      @spec.destination_cidr
    end

    def gateway_node : String
      @spec.gateway_node
    end

    def pod_ip : String
      @spec.pod_ip
    end

    def route_table : Int32
      @spec.route_table
    end

    def routing_priority : Int32
      @spec.routing_priority
    end

    def_clone
  end
end
