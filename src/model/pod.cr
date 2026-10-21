require "json"
require "./resource"

module Netwrangler::Model
  # Minimal Kubernetes Pod model for gateway resolution
  class Pod < Resource
    class PodSpec
      include JSON::Serializable

      @[JSON::Field(key: "nodeName")]
      property node_name : String?

      def initialize(*, @node_name : String? = nil)
      end

      def_clone
    end

    class PodStatus
      include JSON::Serializable

      @[JSON::Field(key: "podIP")]
      property pod_ip : String?

      @[JSON::Field(key: "phase")]
      property phase : String?

      def initialize(*, @pod_ip : String? = nil, @phase : String? = nil)
      end

      def_clone
    end

    @[JSON::Field(key: "spec")]
    property pod_spec : PodSpec?

    @[JSON::Field(key: "status")]
    property status : PodStatus?

    def initialize(*, @metadata : ObjectMeta, @pod_spec : PodSpec? = nil, @status : PodStatus? = nil)
      super(api_version: "v1", kind: "Pod", metadata: @metadata)
    end

    def node_name : String?
      @pod_spec.try(&.node_name)
    end

    def pod_ip : String?
      @status.try(&.pod_ip)
    end

    def phase : String?
      @status.try(&.phase)
    end

    def_clone
  end
end
