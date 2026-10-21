require "json"
require "../model/service"
require "../model/endpoint_slice"
require "../model/pod"
require "../model/vip_network"
require "../model/vip_address"
require "../model/vip_config"
require "../model/vip_gateway"
require "../model/vip_route"

module Netwrangler::Controller
  # Shell-operator stores K8s objects in either:
  # - "object" field (event-based hooks: Added/Modified/Deleted)
  # - "objects" field (synchronization events)
  class ResourceSnapshot(T)
    include JSON::Serializable

    # Single object (event-based hooks)
    getter object : T? = nil

    # Multiple objects (synchronization events)
    getter objects : Array(T)? = nil

    # Returns all objects regardless of which field was populated
    def all_objects : Array(T)
      @object.try { |obj| [obj] } || @objects || [] of T
    end
  end

  # Container for all resource snapshots in a binding context
  class Snapshots
    include JSON::Serializable

    @[JSON::Field(key: "services")]
    getter services : Array(ResourceSnapshot(Model::Service)) = [] of ResourceSnapshot(Model::Service)

    @[JSON::Field(key: "endpoint_slices")]
    getter endpoint_slices : Array(ResourceSnapshot(Model::EndpointSlice)) = [] of ResourceSnapshot(Model::EndpointSlice)

    @[JSON::Field(key: "vip_networks")]
    getter vip_networks : Array(ResourceSnapshot(Model::VipNetwork)) = [] of ResourceSnapshot(Model::VipNetwork)

    @[JSON::Field(key: "vip_addresses")]
    getter vip_addresses : Array(ResourceSnapshot(Model::VipAddress)) = [] of ResourceSnapshot(Model::VipAddress)

    @[JSON::Field(key: "vip_configs")]
    getter vip_configs : Array(ResourceSnapshot(Model::VipConfig)) = [] of ResourceSnapshot(Model::VipConfig)

    @[JSON::Field(key: "vip_gateways")]
    getter vip_gateways : Array(ResourceSnapshot(Model::VipGateway)) = [] of ResourceSnapshot(Model::VipGateway)

    @[JSON::Field(key: "vip_routes")]
    getter vip_routes : Array(ResourceSnapshot(Model::VipRoute)) = [] of ResourceSnapshot(Model::VipRoute)

    @[JSON::Field(key: "pods")]
    getter pods : Array(ResourceSnapshot(Model::Pod)) = [] of ResourceSnapshot(Model::Pod)
  end

  # Represents a single binding context from shell-operator
  class BindingContext
    include JSON::Serializable

    getter binding : String
    getter snapshots : Snapshots

    # Extract Model objects from snapshots (handles both object and objects fields)
    def services : Array(Model::Service)
      snapshots.services.flat_map(&.all_objects)
    end

    def endpoint_slices : Array(Model::EndpointSlice)
      snapshots.endpoint_slices.flat_map(&.all_objects)
    end

    def vip_networks : Array(Model::VipNetwork)
      snapshots.vip_networks.flat_map(&.all_objects)
    end

    def vip_addresses : Array(Model::VipAddress)
      snapshots.vip_addresses.flat_map(&.all_objects)
    end

    def vip_configs : Array(Model::VipConfig)
      snapshots.vip_configs.flat_map(&.all_objects)
    end

    def vip_gateways : Array(Model::VipGateway)
      snapshots.vip_gateways.flat_map(&.all_objects)
    end

    def vip_routes : Array(Model::VipRoute)
      snapshots.vip_routes.flat_map(&.all_objects)
    end

    def pods : Array(Model::Pod)
      snapshots.pods.flat_map(&.all_objects)
    end
  end
end
