require "json"
require "../util/qualified_name"

module Netwrangler::Model
  # Base class for Kubernetes resources
  abstract class Resource
    include JSON::Serializable

    @[JSON::Field(key: "apiVersion")]
    property api_version : String

    @[JSON::Field(key: "kind")]
    property kind : String

    @[JSON::Field(key: "metadata")]
    property metadata : ObjectMeta

    def initialize(*, @api_version : String, @kind : String, @metadata : ObjectMeta)
    end

    def qualified_name : Util::QualifiedName
      ObjectReference.new(
        name: @metadata.name!,
        namespace: @metadata.namespace!
      )
    end

    def reference : ObjectReference
      ObjectReference.new(
        kind: @kind,
        api_version: @api_version,
        name: @metadata.name,
        namespace: @metadata.namespace,
        uid: @metadata.uid
      )
    end

    def_clone
  end
end
