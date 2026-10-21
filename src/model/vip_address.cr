require "json"
require "./resource"

module Netwrangler::Model
  # Custom resource representing an virtual IP assignment
  class VipAddress < Resource
    # Represents a port exposed on an virtual IP
    class Port
      include JSON::Serializable

      @[JSON::Field(key: "port")]
      property port : Int32

      @[JSON::Field(key: "protocol")]
      property protocol : String

      def initialize(*, @port : Int32, @protocol : String)
      end

      def_equals @port, @protocol
      def_clone
    end

    # Spec of an virtual IP
    class Spec
      include JSON::Serializable

      @[JSON::Field(key: "network")]
      property network : String

      @[JSON::Field(key: "nodeName")]
      property node_name : String

      @[JSON::Field(key: "virtualCIDR")]
      property virtual_cidr : String

      @[JSON::Field(key: "interface")]
      property interface : String

      @[JSON::Field(key: "gatewayIP")]
      property gateway_ip : String?

      @[JSON::Field(key: "firewallMark")]
      property firewall_mark : Int32?

      @[JSON::Field(key: "routeTable")]
      property route_table : Int32?

      @[JSON::Field(key: "routingPriority")]
      property routing_priority : Int32?

      @[JSON::Field(key: "egressEnabled")]
      property egress_enabled : Bool?

      @[JSON::Field(key: "endpointIPs")]
      property endpoint_ips : Array(String) = [] of String

      @[JSON::Field(key: "sourceCIDRs")]
      property source_cidrs : Array(String) = [] of String

      @[JSON::Field(key: "ports")]
      property ports : Array(Port) = [] of Port

      def initialize(
        *,
        @network : String,
        @node_name : String,
        @virtual_cidr : String,
        @interface : String,
        @gateway_ip : String? = nil,
        @firewall_mark : Int32? = nil,
        @route_table : Int32? = nil,
        @routing_priority : Int32? = nil,
        @egress_enabled : Bool? = nil,
        @endpoint_ips : Array(String) = [] of String,
        @source_cidrs : Array(String) = [] of String,
        @ports : Array(Port) = [] of Port,
      )
      end

      def_equals @network, @node_name, @virtual_cidr, @interface, @gateway_ip, @firewall_mark, @route_table, @routing_priority, @egress_enabled, @endpoint_ips, @source_cidrs, @ports
      def_clone
    end

    @[JSON::Field(key: "spec")]
    property spec : Spec

    def initialize(
      *,
      @metadata : ObjectMeta,
      @spec : Spec,
    )
      super(api_version: "netwrangler.dev/v1", kind: "VipAddress", metadata: @metadata)
    end

    # Convenience accessors for spec fields
    def network : String
      @spec.network
    end

    def node_name : String
      @spec.node_name
    end

    def virtual_cidr : String
      @spec.virtual_cidr
    end

    def interface : String
      @spec.interface
    end

    def gateway_ip : String?
      @spec.gateway_ip
    end

    def firewall_mark : Int32?
      @spec.firewall_mark
    end

    def route_table : Int32?
      @spec.route_table
    end

    def routing_priority : Int32?
      @spec.routing_priority
    end

    def egress_enabled : Bool?
      @spec.egress_enabled
    end

    def endpoint_ips : Array(String)
      @spec.endpoint_ips
    end

    def source_cidrs : Array(String)
      @spec.source_cidrs
    end

    def ports : Array(Port)
      @spec.ports
    end

    def_clone
  end
end
