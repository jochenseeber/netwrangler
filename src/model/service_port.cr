require "json"

module Netwrangler::Model
  # Kubernetes ServicePort
  class ServicePort
    include JSON::Serializable

    @[JSON::Field(key: "name")]
    property name : String?

    @[JSON::Field(key: "port")]
    property port : Int32

    @[JSON::Field(key: "protocol")]
    property protocol : String?

    @[JSON::Field(key: "targetPort")]
    property target_port : (Int32 | String)?

    @[JSON::Field(key: "nodePort")]
    property node_port : Int32?

    def initialize(
      @port : Int32,
      *,
      @name : String? = nil,
      @protocol : String? = nil,
      @target_port : (Int32 | String)? = nil,
      @node_port : Int32? = nil,
    )
    end

    def_clone
  end
end
