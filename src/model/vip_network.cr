require "json"
require "./resource"

module Netwrangler::Model
  # Custom resource representing an VIP network configuration
  class VipNetwork < Resource
    # Spec of an VIP network
    class Spec
      include JSON::Serializable

      @[JSON::Field(key: "interface")]
      property interface : String

      @[JSON::Field(key: "gatewayIP")]
      property gateway_ip : String?

      @[JSON::Field(key: "networkCIDR")]
      property network_cidr : String

      @[JSON::Field(key: "sourceCIDRs")]
      property source_cidrs : Array(String) = [] of String

      def initialize(
        *,
        @interface : String,
        @gateway_ip : String?,
        @network_cidr : String,
        @source_cidrs : Array(String) = [] of String,
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
      super(api_version: "netwrangler.dev/v1", kind: "VipNetwork", metadata: @metadata)
    end

    # Convenience accessors for spec fields
    def interface : String
      @spec.interface
    end

    def gateway_ip : String?
      @spec.gateway_ip
    end

    def network_cidr : String
      @spec.network_cidr
    end

    def source_cidrs : Array(String)
      @spec.source_cidrs
    end

    def_clone
  end
end
