require "json"

module Netwrangler::Model
  # Kubernetes owner reference
  class OwnerReference
    include JSON::Serializable

    @[JSON::Field(key: "apiVersion")]
    property api_version : String

    @[JSON::Field(key: "kind")]
    property kind : String

    @[JSON::Field(key: "name")]
    property name : String

    @[JSON::Field(key: "uid")]
    property uid : String

    @[JSON::Field(key: "controller")]
    property controller : Bool?

    @[JSON::Field(key: "blockOwnerDeletion")]
    property block_owner_deletion : Bool?

    def initialize(
      *,
      @api_version : String,
      @kind : String,
      @name : String,
      @uid : String,
      @controller : Bool? = nil,
      @block_owner_deletion : Bool? = nil,
    )
    end

    def_clone
  end
end
