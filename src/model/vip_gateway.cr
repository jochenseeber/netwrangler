require "json"
require "./resource"

module Netwrangler::Model
  # Custom resource representing a VIP gateway configuration
  class VipGateway < Resource
    class PodSelector
      include JSON::Serializable

      @[JSON::Field(key: "matchLabels")]
      property match_labels : Hash(String, String)

      def initialize(*, @match_labels : Hash(String, String))
      end

      def_clone
    end

    # Spec of a VIP gateway
    class Spec
      include JSON::Serializable

      @[JSON::Field(key: "destinationCIDR")]
      property destination_cidr : String

      @[JSON::Field(key: "routeTable")]
      property route_table : Int32

      @[JSON::Field(key: "routingPriority")]
      property routing_priority : Int32

      @[JSON::Field(key: "podSelector")]
      property pod_selector : PodSelector

      def initialize(*, @destination_cidr, @route_table, @routing_priority, @pod_selector)
      end

      def_clone
    end

    @[JSON::Field(key: "spec")]
    property spec : Spec

    def initialize(*, @metadata : ObjectMeta, @spec : Spec)
      super(api_version: "netwrangler.dev/v1", kind: "VipGateway", metadata: @metadata)
    end

    # Convenience accessors
    def destination_cidr : String
      @spec.destination_cidr
    end

    def route_table : Int32
      @spec.route_table
    end

    def routing_priority : Int32
      @spec.routing_priority
    end

    def pod_selector : PodSelector
      @spec.pod_selector
    end

    def_clone
  end
end
