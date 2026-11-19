require "json"
require "log"
require "../model/condition"
require "../model/service"
require "../model/service_spec"
require "../model/endpoint_slice"
require "../model/pod"
require "../model/vip_network"
require "../model/vip_address"
require "../model/vip_config"
require "../model/vip_gateway"
require "../model/vip_route"
require "../model/object_meta"
require "../model/object_reference"
require "../util/ipv4_network"
require "../util/qualified_name"
require "./controller_binding_context"
require "./ip_allocator"

module Netwrangler::Controller
  # Main class for managing virtual IP allocations across Kubernetes nodes
  class ControllerHook
    Log = ::Log.for(self)

    # Event binding names
    EVENT_NAME_RESYNC          = "resync"
    EVENT_NAME_SERVICES        = "services"
    EVENT_NAME_ENDPOINT_SLICES = "endpoint_slices"
    EVENT_NAME_VIP_NETWORKS    = "vip_networks"
    EVENT_NAME_VIP_ADDRESSES   = "vip_addresses"
    EVENT_NAME_VIP_CONFIGS     = "vip_configs"
    EVENT_NAME_VIP_GATEWAYS    = "vip_gateways"
    EVENT_NAME_PODS            = "pods"
    EVENT_NAME_VIP_ROUTES      = "vip_routes"
    EVENT_GROUP                = "vip_address_controller"

    # Label and annotation constants for gateway processing
    LABEL_GATEWAY = "netwrangler.dev/gateway"

    # jqFilter for Services - extracts only the fields needed for change detection
    SERVICE_FILTER = <<-JQ
      {
        externalIPs: .spec.externalIPs,
        ports: [.spec.ports[]? | {port, protocol}]
      }
      JQ

    # jqFilter for EndpointSlices - extracts service name and ready endpoints
    ENDPOINT_SLICE_FILTER = <<-JQ
      {
        serviceName: .metadata.labels["kubernetes.io/service-name"],
        endpoints: [.endpoints[]? | {nodeName, ready: .conditions.ready}]
      }
      JQ

    # jqFilter for VipNetwork CRDs - extracts only the spec
    VIP_NETWORK_FILTER = ".spec"

    # jqFilter for VipAddress CRDs - extracts only the spec
    VIP_ADDRESS_FILTER = ".spec"

    # jqFilter for VipConfig CRDs - extracts only the spec
    VIP_CONFIG_FILTER = ".spec"

    # jqFilter for VipGateway CRDs - extracts only the spec
    VIP_GATEWAY_FILTER = ".spec"

    # jqFilter for VipRoute CRDs - extracts only the spec
    VIP_ROUTE_FILTER = ".spec"

    # jqFilter for Pods - extracts fields needed for change detection
    POD_FILTER = <<-JQ
      {
        "podIP": .status.podIP,
        "phase": .status.phase,
        "nodeName": .spec.nodeName,
        "labels": (.metadata.labels // {})
      }
      JQ

    def initialize(*, @manager_name : String = "netwrangler", @debug : Bool = false)
    end

    def run(binding_context_path : String, kubernetes_patch_path : String) : Nil
      binding_context_content = File.read(binding_context_path)

      if @debug
        Log.debug { "Binding context JSON input:\n#{binding_context_content}" }
      end

      contexts = Array(BindingContext).from_json(binding_context_content)
      # All bindings share a group, so shell-operator sends a single Group context with merged snapshots
      context = contexts.first

      allocator = IpAllocator.new(
        services: context.services,
        endpoint_slices: context.endpoint_slices,
        vip_networks: context.vip_networks,
        vip_addresses: context.vip_addresses,
        vip_configs: context.vip_configs,
        manager_name: @manager_name,
        debug: @debug
      )

      result = allocator.allocate

      # Resolve VipRoutes from VipGateways and matching Pods
      vip_route_operations = resolve_vip_gateways(
        vip_gateways: context.vip_gateways,
        pods: context.pods,
        existing_vip_routes: context.vip_routes,
      )

      # Write operations to shell-operator patch file (one JSON object per line)
      operations = build_operations(result) + vip_route_operations
      content = operations.map(&.to_json).join("\n")

      if @debug
        Log.debug { "Writing #{operations.size} operations to #{kubernetes_patch_path}" }
        operations.each_with_index do |op, i|
          Log.debug { "Operation #{i}: #{op.to_json}" }
        end
      end

      File.write(kubernetes_patch_path, content)
    end

    private def build_operations(result : IpAllocator::AllocationResult) : Array(JSON::Any)
      ops = [] of JSON::Any

      # 1. Delete: deleted_ips + updated_ips (updated = delete then recreate)
      result.deleted_ips.each { |ref| ops << delete_operation(ref) }
      result.updated_ips.each { |ip| ops << delete_operation(ip.reference) }

      # 2. Create: added_ips + updated_ips
      result.added_ips.each { |ip| ops << create_operation(ip) }
      result.updated_ips.each { |ip| ops << create_operation(ip) }

      # 3. Status updates for services
      result.service_conditions.each { |name, cond| ops << status_patch(name, cond) }

      ops
    end

    private def delete_operation(ref : Model::ObjectReference) : JSON::Any
      JSON.parse({
        operation:  "Delete",
        apiVersion: ref.api_version,
        kind:       ref.kind,
        namespace:  ref.namespace,
        name:       ref.name,
      }.to_json)
    end

    private def create_operation(ip : Model::VipAddress) : JSON::Any
      JSON.parse({
        operation: "Create",
        object:    ip,
      }.to_json)
    end

    private def status_patch(name : Util::QualifiedName, condition : Model::Condition) : JSON::Any
      JSON.parse({
        operation:   "MergePatch",
        apiVersion:  "v1",
        kind:        "Service",
        namespace:   name.namespace,
        name:        name.name,
        subresource: "status",
        mergePatch:  {status: {conditions: [condition]}},
      }.to_json)
    end

    private def resolve_vip_gateways(
      *,
      vip_gateways : Array(Model::VipGateway),
      pods : Array(Model::Pod),
      existing_vip_routes : Array(Model::VipRoute),
    ) : Array(JSON::Any)
      ops = [] of JSON::Any
      desired_routes = {} of String => Model::VipRoute

      vip_gateways.each do |gateway|
        gateway_name = gateway.metadata.name!
        selector = gateway.pod_selector.match_labels

        matching_pods = pods.select do |pod|
          pod_labels = pod.metadata.labels || {} of String => String
          next false unless selector.all? { |key, value| pod_labels[key]? == value }
          next false unless pod.phase == "Running"
          next false unless pod.pod_ip
          true
        end

        matching_pods.each do |pod|
          pod_name = pod.metadata.name!
          pod_namespace = pod.metadata.namespace!
          pod_ip = pod.pod_ip
          node_name = pod.node_name
          next unless pod_ip && node_name

          route_name = "#{pod_name}-#{gateway_name}"

          route = Model::VipRoute.new(
            metadata: Model::ObjectMeta.new(
              name: route_name,
              namespace: pod_namespace,
              labels: {
                IpAllocator::LABEL_MANAGED => @manager_name,
                LABEL_GATEWAY              => gateway_name,
              },
            ),
            spec: Model::VipRoute::Spec.new(
              destination_cidr: gateway.destination_cidr,
              gateway_node: node_name,
              pod_ip: pod_ip,
              route_table: gateway.route_table,
              routing_priority: gateway.routing_priority,
            ),
          )

          key = "#{pod_namespace}/#{route_name}"
          desired_routes[key] = route
        end
      end

      existing_by_key = existing_vip_routes.to_h do |vip_route|
        key = "#{vip_route.metadata.namespace!}/#{vip_route.metadata.name!}"
        {key, vip_route}
      end

      # Delete VipRoutes no longer needed
      existing_by_key.each do |key, vip_route|
        next if desired_routes.has_key?(key)
        ops << delete_operation(vip_route.reference)
      end

      # Create new VipRoutes
      desired_routes.each do |key, route|
        next if existing_by_key.has_key?(key)
        ops << create_vip_route_operation(route)
      end

      # Update VipRoutes where spec changed
      desired_routes.each do |key, desired|
        existing = existing_by_key[key]?
        next unless existing
        next if desired.spec == existing.spec
        ops << delete_operation(existing.reference)
        ops << create_vip_route_operation(desired)
      end

      ops
    end

    private def create_vip_route_operation(route : Model::VipRoute) : JSON::Any
      JSON.parse({
        operation: "Create",
        object:    route,
      }.to_json)
    end

    def print_config(io : IO = STDOUT) : Nil
      config = {
        configVersion: "v1",
        schedule:      [
          {
            name:         EVENT_NAME_RESYNC,
            group:        EVENT_GROUP,
            crontab:      "*/30 * * * * *",
            allowFailure: true,
          },
        ],
        kubernetes: [
          {
            name:                         EVENT_NAME_SERVICES,
            group:                        EVENT_GROUP,
            apiVersion:                   "v1",
            kind:                         "Service",
            executeHookOnEvent:           ["Added", "Modified", "Deleted"],
            executeHookOnSynchronization: true,
            keepFullObjectsInMemory:      true,
            allowFailure:                 true,
            labelSelector:                {
              matchLabels: {
                IpAllocator::LABEL_INGRESS => "enabled",
              },
            },
            jqFilter: SERVICE_FILTER.strip,
          },
          {
            name:                         EVENT_NAME_ENDPOINT_SLICES,
            group:                        EVENT_GROUP,
            apiVersion:                   "discovery.k8s.io/v1",
            kind:                         "EndpointSlice",
            executeHookOnEvent:           ["Added", "Modified", "Deleted"],
            executeHookOnSynchronization: true,
            keepFullObjectsInMemory:      true,
            allowFailure:                 true,
            jqFilter:                     ENDPOINT_SLICE_FILTER.strip,
          },
          {
            name:                         EVENT_NAME_VIP_NETWORKS,
            group:                        EVENT_GROUP,
            apiVersion:                   "netwrangler.dev/v1",
            kind:                         "VipNetwork",
            executeHookOnEvent:           ["Added", "Modified", "Deleted"],
            executeHookOnSynchronization: true,
            keepFullObjectsInMemory:      true,
            allowFailure:                 true,
            jqFilter:                     VIP_NETWORK_FILTER.strip,
          },
          {
            name:                         EVENT_NAME_VIP_ADDRESSES,
            group:                        EVENT_GROUP,
            apiVersion:                   "netwrangler.dev/v1",
            kind:                         "VipAddress",
            executeHookOnEvent:           ["Added", "Modified", "Deleted"],
            executeHookOnSynchronization: true,
            keepFullObjectsInMemory:      true,
            allowFailure:                 true,
            labelSelector:                {
              matchLabels: {
                IpAllocator::LABEL_MANAGED => @manager_name,
              },
            },
            jqFilter: VIP_ADDRESS_FILTER.strip,
          },
          {
            name:                         EVENT_NAME_VIP_CONFIGS,
            group:                        EVENT_GROUP,
            apiVersion:                   "netwrangler.dev/v1",
            kind:                         "VipConfig",
            executeHookOnEvent:           ["Added", "Modified", "Deleted"],
            executeHookOnSynchronization: true,
            keepFullObjectsInMemory:      true,
            allowFailure:                 true,
            jqFilter:                     VIP_CONFIG_FILTER.strip,
          },
          {
            name:                         EVENT_NAME_VIP_GATEWAYS,
            group:                        EVENT_GROUP,
            apiVersion:                   "netwrangler.dev/v1",
            kind:                         "VipGateway",
            executeHookOnEvent:           ["Added", "Modified", "Deleted"],
            executeHookOnSynchronization: true,
            keepFullObjectsInMemory:      true,
            allowFailure:                 true,
            jqFilter:                     VIP_GATEWAY_FILTER.strip,
          },
          {
            name:                         EVENT_NAME_PODS,
            group:                        EVENT_GROUP,
            apiVersion:                   "v1",
            kind:                         "Pod",
            executeHookOnEvent:           ["Added", "Modified", "Deleted"],
            executeHookOnSynchronization: true,
            keepFullObjectsInMemory:      true,
            allowFailure:                 true,
            labelSelector:                {
              matchLabels: {
                LABEL_GATEWAY => "enabled",
              },
            },
            jqFilter: POD_FILTER.strip,
          },
          {
            name:                         EVENT_NAME_VIP_ROUTES,
            group:                        EVENT_GROUP,
            apiVersion:                   "netwrangler.dev/v1",
            kind:                         "VipRoute",
            executeHookOnEvent:           ["Added", "Modified", "Deleted"],
            executeHookOnSynchronization: true,
            keepFullObjectsInMemory:      true,
            allowFailure:                 true,
            labelSelector:                {
              matchLabels: {
                IpAllocator::LABEL_MANAGED => @manager_name,
              },
            },
            jqFilter: VIP_ROUTE_FILTER.strip,
          },
        ],
      }
      io.puts config.to_json
    end
  end
end
