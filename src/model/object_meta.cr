require "json"
require "./owner_reference"

module Netwrangler::Model
  # Kubernetes object metadata
  class ObjectMeta
    include JSON::Serializable

    @[JSON::Field(key: "name")]
    property name : String?

    @[JSON::Field(key: "namespace")]
    property namespace : String?

    @[JSON::Field(key: "uid")]
    property uid : String?

    @[JSON::Field(key: "generation")]
    property generation : Int64?

    @[JSON::Field(key: "labels")]
    property labels : Hash(String, String)?

    @[JSON::Field(key: "annotations")]
    property annotations : Hash(String, String)?

    @[JSON::Field(key: "ownerReferences")]
    property owner_references : Array(OwnerReference)?

    def initialize(
      *,
      @name : String? = nil,
      @namespace : String? = nil,
      @uid : String? = nil,
      @generation : Int64? = nil,
      @labels : Hash(String, String)? = nil,
      @annotations : Hash(String, String)? = nil,
      @owner_references : Array(OwnerReference)? = nil,
    )
    end

    def name! : String
      @name || raise NilAssertionError.new("ObjectMeta#name is nil")
    end

    def namespace! : String
      @namespace || raise NilAssertionError.new("ObjectMeta#namespace is nil")
    end

    def uid! : String
      @uid || raise NilAssertionError.new("ObjectMeta#uid is nil")
    end

    def labels! : Hash(String, String)
      @labels || raise NilAssertionError.new("ObjectMeta#labels is nil")
    end

    def_clone
  end
end
