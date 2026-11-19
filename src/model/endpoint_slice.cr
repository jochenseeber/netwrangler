require "json"
require "./resource"
require "./object_reference"

module Netwrangler::Model
  # Kubernetes EndpointSlice resource
  class EndpointSlice < Resource
    class Port
      include JSON::Serializable

      @[JSON::Field(key: "name")]
      property name : String?

      @[JSON::Field(key: "port")]
      property port : Int32

      @[JSON::Field(key: "protocol")]
      property protocol : String?

      @[JSON::Field(key: "appProtocol")]
      property app_protocol : String?

      def initialize(
        @port : Int32,
        *,
        @name : String? = nil,
        @protocol : String? = nil,
        @app_protocol : String? = nil,
      )
      end

      def_clone
    end

    class Endpoint
      include JSON::Serializable

      # Conditions represents the condition of an endpoint
      class Conditions
        include JSON::Serializable

        @[JSON::Field(key: "ready")]
        property ready : Bool?

        @[JSON::Field(key: "serving")]
        property serving : Bool?

        @[JSON::Field(key: "terminating")]
        property terminating : Bool?

        def initialize(
          *,
          @ready : Bool? = nil,
          @serving : Bool? = nil,
          @terminating : Bool? = nil,
        )
        end

        def_clone
      end

      @[JSON::Field(key: "addresses")]
      property addresses : Array(String)

      @[JSON::Field(key: "nodeName")]
      property node_name : String?

      @[JSON::Field(key: "targetRef")]
      property target_ref : ObjectReference?

      @[JSON::Field(key: "conditions")]
      property conditions : Conditions?

      @[JSON::Field(key: "hostname")]
      property hostname : String?

      @[JSON::Field(key: "zone")]
      property zone : String?

      def node_name! : String
        @node_name || raise NilAssertionError.new("Endpoint#node_name is nil")
      end

      def initialize(
        *,
        @addresses : Array(String),
        @node_name : String? = nil,
        @target_ref : ObjectReference? = nil,
        @conditions : Conditions? = nil,
        @hostname : String? = nil,
        @zone : String? = nil,
      )
      end

      def_clone
    end

    @[JSON::Field(key: "addressType")]
    property address_type : String

    @[JSON::Field(key: "endpoints")]
    property endpoints : Array(Endpoint)?

    @[JSON::Field(key: "ports")]
    property ports : Array(Port)?

    def initialize(
      *,
      @metadata : ObjectMeta,
      @address_type : String,
      @endpoints : Array(Endpoint)? = nil,
      @ports : Array(Port)? = nil,
    )
      super(api_version: "discovery.k8s.io/v1", kind: "EndpointSlice", metadata: @metadata)
    end

    def_clone
  end
end
