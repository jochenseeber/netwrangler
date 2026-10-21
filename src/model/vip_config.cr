require "json"
require "./resource"

module Netwrangler::Model
  # Singleton custom resource for global virtual IP configuration
  class VipConfig < Resource
    class Spec
      include JSON::Serializable

      @[JSON::Field(key: "firewallMark")]
      property firewall_mark : Int32

      @[JSON::Field(key: "firewallMarkMask")]
      property firewall_mark_mask : UInt32

      @[JSON::Field(key: "routeTable")]
      property route_table : Int32

      @[JSON::Field(key: "routingPriority")]
      property routing_priority : Int32

      @[JSON::Field(key: "maxAddressCount")]
      property max_address_count : Int32

      @[JSON::Field(key: "clusterCIDRs")]
      property cluster_cidrs : Array(String) = [] of String

      def initialize(
        *,
        @firewall_mark : Int32,
        @firewall_mark_mask : UInt32,
        @route_table : Int32,
        @routing_priority : Int32,
        @max_address_count : Int32,
        @cluster_cidrs : Array(String) = [] of String,
      )
      end

      def_clone
    end

    @[JSON::Field(key: "spec")]
    property spec : Spec

    def initialize(
      *,
      @metadata : ObjectMeta,
      @spec : Spec,
    )
      super(api_version: "netwrangler.dev/v1", kind: "VipConfig", metadata: @metadata)
    end

    def firewall_mark : Int32
      @spec.firewall_mark
    end

    def firewall_mark_mask : UInt32
      @spec.firewall_mark_mask
    end

    def route_table : Int32
      @spec.route_table
    end

    def routing_priority : Int32
      @spec.routing_priority
    end

    def max_address_count : Int32
      @spec.max_address_count
    end

    def cluster_cidrs : Array(String)
      @spec.cluster_cidrs
    end

    def_clone
  end
end
