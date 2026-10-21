require "json"
require "./resource"
require "./service_spec"

module Netwrangler::Model
  # Kubernetes Service resource
  class Service < Resource
    @[JSON::Field(key: "spec")]
    property spec : ServiceSpec?

    def initialize(
      *,
      @metadata : ObjectMeta,
      @spec : ServiceSpec? = nil,
    )
      super(api_version: "v1", kind: "Service", metadata: @metadata)
    end

    def selector : Hash(String, String)?
      @spec.try(&.selector)
    end

    def load_balancer_ip : String?
      @spec.try(&.load_balancer_ip)
    end

    def load_balancer_ip=(value : String?)
      if spec = @spec
        spec.load_balancer_ip = value
      else
        @spec = ServiceSpec.new(load_balancer_ip: value)
      end
    end

    def ports : Array(ServicePort)?
      @spec.try(&.ports)
    end

    def_clone
  end
end
