require "./ipv4_network"

module Netwrangler::Util
  # Represents a shell-operator binding context
  class BindingContext
    include JSON::Serializable

    @[JSON::Field(key: "binding")]
    getter binding : String

    @[JSON::Field(key: "snapshots")]
    getter snapshots : Snapshots
  end

  # Container for all snapshot types by binding name
  class Snapshots
    include JSON::Serializable

    @[JSON::Field(key: "vip_addresses")]
    getter vip_addresses : Array(VipAddressSnapshot) = [] of VipAddressSnapshot

    @[JSON::Field(key: "vip_networks")]
    getter vip_networks : Array(VipNetworkSnapshot) = [] of VipNetworkSnapshot

    @[JSON::Field(key: "vip_configs")]
    getter vip_configs : Array(VipAddressConfigSnapshot) = [] of VipAddressConfigSnapshot

    @[JSON::Field(key: "vip_routes")]
    getter vip_routes : Array(VipRouteSnapshot) = [] of VipRouteSnapshot

    @[JSON::Field(key: "vip_gateways")]
    getter vip_gateways : Array(VipGatewaySnapshot) = [] of VipGatewaySnapshot
  end

  # Base class for all snapshot types
  abstract class Snapshot
    include JSON::Serializable

    # Returns the name of the resource
    abstract def name : String
  end

  # Snapshot for VipAddress resources
  class VipAddressSnapshot < Snapshot
    @[JSON::Field(key: "filterResult")]
    getter filter_result : VipAddressFilterResult

    def name : String
      filter_result.name
    end

    delegate :namespace, :network, :virtual_cidr, :interface, :gateway_ip, :firewall_mark, :route_table, :routing_priority, :egress_enabled, :endpoint_ips, :source_cidrs, :ports, to: filter_result
  end

  # Snapshot for VipNetwork resources
  class VipNetworkSnapshot < Snapshot
    @[JSON::Field(key: "filterResult")]
    getter filter_result : VipNetworkFilterResult

    def name : String
      filter_result.name
    end

    delegate :interface, :gateway_ip, :network_cidr, :source_cidrs, to: filter_result
  end

  # Base class for all filter results
  abstract class FilterResult
    include JSON::Serializable

    # Returns the name of the resource
    abstract def name : String
  end

  # Port information from VipAddress jqFilter
  class PortInfo
    include JSON::Serializable

    @[JSON::Field(key: "port")]
    getter port : Int32

    @[JSON::Field(key: "protocol")]
    getter protocol : String
  end

  # Filter result for VipAddress resources
  class VipAddressFilterResult < FilterResult
    @[JSON::Field(key: "name")]
    getter name : String

    @[JSON::Field(key: "namespace")]
    getter namespace : String

    @[JSON::Field(key: "network")]
    getter network : String

    @[JSON::Field(key: "virtual_cidr")]
    getter virtual_cidr : String

    @[JSON::Field(key: "interface")]
    getter interface : String

    @[JSON::Field(key: "gateway_ip")]
    getter gateway_ip : String?

    @[JSON::Field(key: "firewall_mark")]
    getter firewall_mark : Int32?

    @[JSON::Field(key: "route_table")]
    getter route_table : Int32?

    @[JSON::Field(key: "routing_priority")]
    getter routing_priority : Int32?

    @[JSON::Field(key: "egress_enabled")]
    getter egress_enabled : Bool?

    @[JSON::Field(key: "endpoint_ips")]
    getter endpoint_ips : Array(String)

    @[JSON::Field(key: "source_cidrs")]
    getter source_cidrs : Array(String) = [] of String

    @[JSON::Field(key: "ports")]
    getter ports : Array(PortInfo) = [] of PortInfo

    def after_initialize
      validate_cidr(@virtual_cidr, field_name: "virtual IP")
      if gw = @gateway_ip
        validate_ipv4(gw, field_name: "gateway IP")
      end
      @endpoint_ips.each { |ip| validate_ipv4(ip, field_name: "endpoint IP") }
    end

    private def validate_cidr(value : String, *, field_name : String) : Nil
      IPv4Network.parse(value)
    rescue ArgumentError
      raise ArgumentError.new("VipAddress #{@namespace}/#{@name} has invalid #{field_name}: #{value}")
    end

    private def validate_ipv4(value : String, *, field_name : String) : Nil
      IPv4Address.parse(value)
    rescue ArgumentError
      raise ArgumentError.new("VipAddress #{@namespace}/#{@name} has invalid #{field_name}: #{value}")
    end
  end

  # Filter result for VipNetwork resources
  class VipNetworkFilterResult < FilterResult
    @[JSON::Field(key: "name")]
    getter name : String

    @[JSON::Field(key: "interface")]
    getter interface : String

    @[JSON::Field(key: "gateway_ip")]
    getter gateway_ip : String?

    @[JSON::Field(key: "network_cidr")]
    getter network_cidr : String

    @[JSON::Field(key: "source_cidrs")]
    getter source_cidrs : Array(String) = [] of String
  end

  # Snapshot for VipConfig resources
  class VipAddressConfigSnapshot < Snapshot
    @[JSON::Field(key: "filterResult")]
    getter filter_result : VipAddressConfigFilterResult

    def name : String
      filter_result.name
    end

    delegate :firewall_mark, :firewall_mark_mask, :route_table, :routing_priority, :max_address_count, :cluster_cidrs, to: filter_result
  end

  # Filter result for VipConfig resources
  class VipAddressConfigFilterResult < FilterResult
    @[JSON::Field(key: "name")]
    getter name : String

    @[JSON::Field(key: "firewall_mark")]
    getter firewall_mark : Int32

    @[JSON::Field(key: "firewall_mark_mask")]
    getter firewall_mark_mask : UInt32

    @[JSON::Field(key: "route_table")]
    getter route_table : Int32

    @[JSON::Field(key: "routing_priority")]
    getter routing_priority : Int32

    @[JSON::Field(key: "max_address_count")]
    getter max_address_count : Int32

    @[JSON::Field(key: "cluster_cidrs")]
    getter cluster_cidrs : Array(String) = [] of String
  end

  # Snapshot for VipRoute resources
  class VipRouteSnapshot < Snapshot
    @[JSON::Field(key: "filterResult")]
    getter filter_result : VipRouteFilterResult

    def name : String
      filter_result.name
    end

    delegate :namespace, :destination_cidr, :gateway_node, :pod_ip, :route_table, :routing_priority, to: filter_result
  end

  # Filter result for VipRoute resources
  class VipRouteFilterResult < FilterResult
    @[JSON::Field(key: "name")]
    getter name : String

    @[JSON::Field(key: "namespace")]
    getter namespace : String

    @[JSON::Field(key: "destination_cidr")]
    getter destination_cidr : String

    @[JSON::Field(key: "gateway_node")]
    getter gateway_node : String

    @[JSON::Field(key: "pod_ip")]
    getter pod_ip : String

    @[JSON::Field(key: "route_table")]
    getter route_table : Int32

    @[JSON::Field(key: "routing_priority")]
    getter routing_priority : Int32
  end

  # Snapshot for VipGateway resources
  class VipGatewaySnapshot < Snapshot
    @[JSON::Field(key: "filterResult")]
    getter filter_result : VipGatewayFilterResult

    def name : String
      filter_result.name
    end

    delegate :destination_cidr, :route_table, :routing_priority, to: filter_result
  end

  # Filter result for VipGateway resources. The destination stays a string so
  # the agent can skip one malformed gateway instead of failing the parse of
  # the whole binding context.
  class VipGatewayFilterResult < FilterResult
    @[JSON::Field(key: "name")]
    getter name : String

    @[JSON::Field(key: "destination_cidr")]
    getter destination_cidr : String

    @[JSON::Field(key: "route_table")]
    getter route_table : Int32

    @[JSON::Field(key: "routing_priority")]
    getter routing_priority : Int32
  end
end
