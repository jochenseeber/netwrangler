require "json"
require "./service_port"

module Netwrangler::Model
  # ServiceSpec for Kubernetes Service resources
  class ServiceSpec
    include JSON::Serializable

    @[JSON::Field(key: "type")]
    property type : String?

    @[JSON::Field(key: "selector")]
    property selector : Hash(String, String)?

    @[JSON::Field(key: "loadBalancerIP")]
    property load_balancer_ip : String?

    @[JSON::Field(key: "loadBalancerClass")]
    property load_balancer_class : String?

    @[JSON::Field(key: "ports")]
    property ports : Array(ServicePort)?

    @[JSON::Field(key: "externalIPs")]
    property external_ips : Array(String)?

    @[JSON::Field(key: "externalTrafficPolicy")]
    property external_traffic_policy : String?

    @[JSON::Field(key: "internalTrafficPolicy")]
    property internal_traffic_policy : String?

    def initialize(
      *,
      @type : String? = nil,
      @selector : Hash(String, String)? = nil,
      @load_balancer_ip : String? = nil,
      @load_balancer_class : String? = nil,
      @ports : Array(ServicePort)? = nil,
      @external_ips : Array(String)? = nil,
      @external_traffic_policy : String? = nil,
      @internal_traffic_policy : String? = nil,
    )
    end

    def_clone
  end
end
