require "json"

module Netwrangler::Model
  # Kubernetes ObjectReference
  class ObjectReference
    include JSON::Serializable

    @[JSON::Field(key: "kind")]
    property kind : String?

    @[JSON::Field(key: "namespace")]
    property namespace : String?

    @[JSON::Field(key: "name")]
    property name : String?

    @[JSON::Field(key: "uid")]
    property uid : String?

    @[JSON::Field(key: "apiVersion")]
    property api_version : String?

    @[JSON::Field(key: "resourceVersion")]
    property resource_version : String?

    def initialize(
      *,
      @kind : String? = nil,
      @namespace : String? = nil,
      @name : String? = nil,
      @uid : String? = nil,
      @api_version : String? = nil,
      @resource_version : String? = nil,
    )
    end

    def_clone
  end
end
