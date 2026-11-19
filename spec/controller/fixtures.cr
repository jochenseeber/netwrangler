require "../../src/model/service"
require "../../src/model/service_spec"
require "../../src/model/endpoint_slice"
require "../../src/model/vip_network"
require "../../src/model/vip_address"
require "../../src/model/vip_config"
require "../../src/model/vip_gateway"
require "../../src/model/vip_route"
require "../../src/model/pod"
require "../../src/model/object_meta"
require "../../src/model/owner_reference"
require "../../src/util/qualified_name"
require "../../src/controller/controller_binding_context"

module ControllerFixtures
  # Label key for service name in EndpointSlice
  LABEL_SERVICE_NAME = "kubernetes.io/service-name"

  # Label key for ingress opt-in
  LABEL_INGRESS = "netwrangler.dev/ingress"

  # Creates a Service with test data
  def self.service(
    name : String = "test-service",
    namespace : String = "default",
    uid : String = "service-uid-123",
    generation : Int64 = 1_i64,
    external_ips : Array(String) = ["10.0.1.10"],
    ingress : Bool = true,
    external_traffic_policy : String? = "Local",
    ports : Array(Netwrangler::Model::ServicePort) = [Netwrangler::Model::ServicePort.new(port: 80, protocol: "TCP")],
  ) : Netwrangler::Model::Service
    labels = ingress ? {LABEL_INGRESS => "enabled"} : nil

    metadata = Netwrangler::Model::ObjectMeta.new(
      name: name,
      namespace: namespace,
      uid: uid,
      generation: generation,
      labels: labels
    )

    spec = Netwrangler::Model::ServiceSpec.new(
      external_ips: external_ips,
      external_traffic_policy: external_traffic_policy,
      ports: ports
    )

    Netwrangler::Model::Service.new(metadata: metadata, spec: spec)
  end

  # Creates an EndpointSlice with test data
  def self.endpoint_slice(
    name : String = "test-service-abc123",
    namespace : String = "default",
    service_name : String? = "test-service",
    nodes : Array(String) = ["node-1"],
    addresses : Array(Array(String))? = nil,
  ) : Netwrangler::Model::EndpointSlice
    labels = service_name ? {LABEL_SERVICE_NAME => service_name} : nil

    metadata = Netwrangler::Model::ObjectMeta.new(
      name: name,
      namespace: namespace,
      labels: labels
    )

    # Create endpoints from nodes array - each node entry creates a ready endpoint
    endpoints = nodes.map_with_index do |node_name, index|
      conditions = Netwrangler::Model::EndpointSlice::Endpoint::Conditions.new(ready: true)
      endpoint_addresses = addresses.try(&.[index]?) || ["10.244.0.#{index + 1}"]
      Netwrangler::Model::EndpointSlice::Endpoint.new(
        addresses: endpoint_addresses,
        node_name: node_name,
        conditions: conditions
      )
    end

    Netwrangler::Model::EndpointSlice.new(
      metadata: metadata,
      address_type: "IPv4",
      endpoints: endpoints
    )
  end

  # Creates an VipNetwork with test data
  def self.vip_network(
    name : String = "test-network",
    uid : String = "network-uid-123",
    interface : String = "eth0",
    gateway_ip : String = "10.0.1.1",
    network_cidr : String = "10.0.1.0/24",
    source_cidrs : Array(String) = [] of String,
  ) : Netwrangler::Model::VipNetwork
    metadata = Netwrangler::Model::ObjectMeta.new(
      name: name,
      uid: uid
    )

    spec = Netwrangler::Model::VipNetwork::Spec.new(
      interface: interface,
      gateway_ip: gateway_ip,
      network_cidr: network_cidr,
      source_cidrs: source_cidrs,
    )

    Netwrangler::Model::VipNetwork.new(metadata: metadata, spec: spec)
  end

  # Creates an VipConfig with test data
  def self.vip_config(
    name : String = "default",
    uid : String = "config-uid-123",
    firewall_mark : Int32 = 0x010000,
    firewall_mark_mask : UInt32 = 0xFF0000_u32,
    route_table : Int32 = 100,
    routing_priority : Int32 = 100,
    max_address_count : Int32 = 254,
    cluster_cidrs : Array(String) = [] of String,
  ) : Netwrangler::Model::VipConfig
    metadata = Netwrangler::Model::ObjectMeta.new(
      name: name,
      uid: uid
    )

    spec = Netwrangler::Model::VipConfig::Spec.new(
      firewall_mark: firewall_mark,
      firewall_mark_mask: firewall_mark_mask,
      route_table: route_table,
      routing_priority: routing_priority,
      max_address_count: max_address_count,
      cluster_cidrs: cluster_cidrs
    )

    Netwrangler::Model::VipConfig.new(metadata: metadata, spec: spec)
  end

  # Creates an VipAddress with test data
  def self.vip_address(
    name : String = "test-service-1",
    namespace : String = "default",
    network : String = "test-network",
    node_name : String = "node-1",
    virtual_cidr : String = "10.0.1.10/24",
    interface : String = "eth0",
    gateway_ip : String? = "10.0.1.1",
    firewall_mark : Int32? = nil,
    route_table : Int32? = nil,
    routing_priority : Int32? = nil,
    egress_enabled : Bool? = nil,
    endpoint_ips : Array(String) = [] of String,
    ports : Array(Netwrangler::Model::VipAddress::Port) = [] of Netwrangler::Model::VipAddress::Port,
    labels : Hash(String, String)? = nil,
  ) : Netwrangler::Model::VipAddress
    metadata = Netwrangler::Model::ObjectMeta.new(
      name: name,
      namespace: namespace,
      labels: labels
    )

    spec = Netwrangler::Model::VipAddress::Spec.new(
      network: network,
      node_name: node_name,
      virtual_cidr: virtual_cidr,
      interface: interface,
      gateway_ip: gateway_ip,
      firewall_mark: firewall_mark,
      route_table: route_table,
      routing_priority: routing_priority,
      egress_enabled: egress_enabled,
      endpoint_ips: endpoint_ips,
      ports: ports
    )

    Netwrangler::Model::VipAddress.new(metadata: metadata, spec: spec)
  end

  # Creates a Pod with test data
  def self.pod(
    name : String = "gateway-pod-1",
    namespace : String = "default",
    uid : String = "pod-uid-123",
    labels : Hash(String, String) = {"app" => "gateway", "netwrangler.dev/gateway" => "enabled"},
    pod_ip : String? = "10.244.1.1",
    phase : String = "Running",
    node_name : String? = "node-1",
  ) : Netwrangler::Model::Pod
    metadata = Netwrangler::Model::ObjectMeta.new(
      name: name,
      namespace: namespace,
      uid: uid,
      labels: labels
    )

    pod_spec = Netwrangler::Model::Pod::PodSpec.new(
      node_name: node_name
    )

    status = Netwrangler::Model::Pod::PodStatus.new(
      pod_ip: pod_ip,
      phase: phase
    )

    Netwrangler::Model::Pod.new(metadata: metadata, pod_spec: pod_spec, status: status)
  end

  # Creates a VipGateway with test data
  def self.vip_gateway(
    name : String = "test-gateway",
    uid : String = "gateway-uid-123",
    destination_cidr : String = "10.0.0.0/8",
    route_table : Int32 = 200,
    routing_priority : Int32 = 200,

    pod_selector_labels : Hash(String, String) = {"app" => "gateway"},
  ) : Netwrangler::Model::VipGateway
    metadata = Netwrangler::Model::ObjectMeta.new(
      name: name,
      uid: uid
    )

    pod_selector = Netwrangler::Model::VipGateway::PodSelector.new(
      match_labels: pod_selector_labels
    )

    spec = Netwrangler::Model::VipGateway::Spec.new(
      destination_cidr: destination_cidr,
      route_table: route_table,
      routing_priority: routing_priority,

      pod_selector: pod_selector
    )

    Netwrangler::Model::VipGateway.new(metadata: metadata, spec: spec)
  end

  # Creates a VipRoute with test data
  def self.vip_route(
    name : String = "test-route",
    namespace : String = "default",
    uid : String = "route-uid-123",
    destination_cidr : String = "10.0.0.0/8",
    gateway_node : String = "node-1",
    pod_ip : String = "10.244.1.1",
    route_table : Int32 = 200,
    routing_priority : Int32 = 200,

    labels : Hash(String, String)? = nil,
    owner_references : Array(Netwrangler::Model::OwnerReference)? = nil,
  ) : Netwrangler::Model::VipRoute
    metadata = Netwrangler::Model::ObjectMeta.new(
      name: name,
      namespace: namespace,
      uid: uid,
      labels: labels,
      owner_references: owner_references
    )

    spec = Netwrangler::Model::VipRoute::Spec.new(
      destination_cidr: destination_cidr,
      gateway_node: gateway_node,
      pod_ip: pod_ip,
      route_table: route_table,
      routing_priority: routing_priority,
    )

    Netwrangler::Model::VipRoute.new(metadata: metadata, spec: spec)
  end

  # Creates a multi-node service scenario for integration testing
  def self.multi_node_service_scenario(
    service_name : String = "test-service",
    namespace : String = "default",
    network_name : String = "test-network",
    node_count : Int32 = 3,
    ips_per_service : Int32 = 6,
    endpoints_per_node : Array(Int32) = [2, 2, 2],
  ) : NamedTuple(
    services: Array(Netwrangler::Model::Service),
    endpoint_slices: Array(Netwrangler::Model::EndpointSlice),
    vip_networks: Array(Netwrangler::Model::VipNetwork),
    vip_addresses: Array(Netwrangler::Model::VipAddress),
    vip_configs: Array(Netwrangler::Model::VipConfig))
    # Generate virtual IPs
    vip_addresses_array = (1..ips_per_service).map { |index| "10.0.1.#{10 + index}" }.to_a

    # Create service
    svc = service(
      name: service_name,
      namespace: namespace,
      uid: "service-uid-#{service_name}",
      external_ips: vip_addresses_array
    )

    # Create endpoint slices for each node
    endpoint_slices_array = (1..node_count).map do |node_idx|
      node_name = "node-#{node_idx}"
      endpoint_count = endpoints_per_node[node_idx - 1]

      # Generate unique endpoint addresses for each endpoint on this node
      node_addresses = (1..endpoint_count).map do |ep_idx|
        ["10.244.#{node_idx}.#{ep_idx}"]
      end.to_a

      # Create one endpoint slice per node with multiple endpoints (same node repeated)
      endpoint_slice(
        name: "#{service_name}-#{node_name}",
        namespace: namespace,
        service_name: service_name,
        nodes: Array.new(endpoint_count, node_name),
        addresses: node_addresses
      )
    end.to_a

    # Create VIP network
    net = vip_network(
      name: network_name,
      uid: "network-uid-#{network_name}",
      interface: "eth0",
      gateway_ip: "10.0.1.1"
    )

    # Create virtual IP config
    config = vip_config

    {
      services:        [svc],
      endpoint_slices: endpoint_slices_array,
      vip_networks:    [net],
      vip_addresses:   [] of Netwrangler::Model::VipAddress,
      vip_configs:     [config],
    }
  end

  # ==========================================
  # Binding context helpers for testing BindingContext
  # ==========================================

  # Creates a binding context JSON string for testing with Model objects
  # Shell-operator stores full objects in "object" field with keepFullObjectsInMemory: true
  def self.binding_context_json(
    binding_name : String = "vip_address_controller",
    services : Array(Netwrangler::Model::Service) = [] of Netwrangler::Model::Service,
    endpoint_slices : Array(Netwrangler::Model::EndpointSlice) = [] of Netwrangler::Model::EndpointSlice,
    vip_networks : Array(Netwrangler::Model::VipNetwork) = [] of Netwrangler::Model::VipNetwork,
    vip_addresses : Array(Netwrangler::Model::VipAddress) = [] of Netwrangler::Model::VipAddress,
    vip_configs : Array(Netwrangler::Model::VipConfig) = [] of Netwrangler::Model::VipConfig,
    vip_gateways : Array(Netwrangler::Model::VipGateway) = [] of Netwrangler::Model::VipGateway,
    vip_routes : Array(Netwrangler::Model::VipRoute) = [] of Netwrangler::Model::VipRoute,
    pods : Array(Netwrangler::Model::Pod) = [] of Netwrangler::Model::Pod,
  ) : String
    # Wrap each resource in an object wrapper (shell-operator format with keepFullObjectsInMemory)
    services_json = services.map { |service| %({"object": #{service.to_json}}) }.join(",")
    endpoint_slices_json = endpoint_slices.map { |endpoint_slice| %({"object": #{endpoint_slice.to_json}}) }.join(",")
    vip_networks_json = vip_networks.map { |network| %({"object": #{network.to_json}}) }.join(",")
    vip_addresses_json = vip_addresses.map { |vip_address| %({"object": #{vip_address.to_json}}) }.join(",")
    vip_configs_json = vip_configs.map { |vip_config| %({"object": #{vip_config.to_json}}) }.join(",")
    vip_gateways_json = vip_gateways.map { |vip_gateway| %({"object": #{vip_gateway.to_json}}) }.join(",")
    vip_routes_json = vip_routes.map { |vip_route| %({"object": #{vip_route.to_json}}) }.join(",")
    pods_json = pods.map { |pod| %({"object": #{pod.to_json}}) }.join(",")

    <<-JSON
      [{
        "binding": "#{binding_name}",
        "snapshots": {
          "services": [#{services_json}],
          "endpoint_slices": [#{endpoint_slices_json}],
          "vip_networks": [#{vip_networks_json}],
          "vip_addresses": [#{vip_addresses_json}],
          "vip_configs": [#{vip_configs_json}],
          "vip_gateways": [#{vip_gateways_json}],
          "vip_routes": [#{vip_routes_json}],
          "pods": [#{pods_json}]
        }
      }]
      JSON
  end

  # Creates a binding context JSON string for synchronization events
  # Shell-operator uses "objects" array for synchronization events
  def self.binding_context_json_sync(
    binding_name : String = "vip_address_controller",
    services : Array(Netwrangler::Model::Service) = [] of Netwrangler::Model::Service,
    endpoint_slices : Array(Netwrangler::Model::EndpointSlice) = [] of Netwrangler::Model::EndpointSlice,
    vip_networks : Array(Netwrangler::Model::VipNetwork) = [] of Netwrangler::Model::VipNetwork,
    vip_addresses : Array(Netwrangler::Model::VipAddress) = [] of Netwrangler::Model::VipAddress,
    vip_configs : Array(Netwrangler::Model::VipConfig) = [] of Netwrangler::Model::VipConfig,
    vip_gateways : Array(Netwrangler::Model::VipGateway) = [] of Netwrangler::Model::VipGateway,
    vip_routes : Array(Netwrangler::Model::VipRoute) = [] of Netwrangler::Model::VipRoute,
    pods : Array(Netwrangler::Model::Pod) = [] of Netwrangler::Model::Pod,
  ) : String
    # Wrap resources in objects array (shell-operator synchronization format)
    services_json = services.empty? ? "" : %({"objects": [#{services.map(&.to_json).join(",")}]})
    endpoint_slices_json = endpoint_slices.empty? ? "" : %({"objects": [#{endpoint_slices.map(&.to_json).join(",")}]})
    vip_networks_json = vip_networks.empty? ? "" : %({"objects": [#{vip_networks.map(&.to_json).join(",")}]})
    vip_addresses_json = vip_addresses.empty? ? "" : %({"objects": [#{vip_addresses.map(&.to_json).join(",")}]})
    vip_configs_json = vip_configs.empty? ? "" : %({"objects": [#{vip_configs.map(&.to_json).join(",")}]})
    vip_gateways_json = vip_gateways.empty? ? "" : %({"objects": [#{vip_gateways.map(&.to_json).join(",")}]})
    vip_routes_json = vip_routes.empty? ? "" : %({"objects": [#{vip_routes.map(&.to_json).join(",")}]})
    pods_json = pods.empty? ? "" : %({"objects": [#{pods.map(&.to_json).join(",")}]})

    <<-JSON
      [{
        "binding": "#{binding_name}",
        "type": "Group",
        "snapshots": {
          "services": [#{services_json}],
          "endpoint_slices": [#{endpoint_slices_json}],
          "vip_networks": [#{vip_networks_json}],
          "vip_addresses": [#{vip_addresses_json}],
          "vip_configs": [#{vip_configs_json}],
          "vip_gateways": [#{vip_gateways_json}],
          "vip_routes": [#{vip_routes_json}],
          "pods": [#{pods_json}]
        }
      }]
      JSON
  end
end
