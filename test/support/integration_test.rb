# frozen_string_literal: true

require "digest"
require "pastel"
require "securerandom"
require "yaml"

# Integration test support module for netwrangler controller
module IntegrationTest
  PASTEL = Pastel.new

  # Kubernetes context for the kind cluster
  KUBE_CONTEXT = "kind-netwrangler"

  # Docker container name of the kind control-plane node (used for docker exec kubectl)
  CONTROL_PLANE_CONTAINER = "netwrangler-control-plane"

  # Namespace where the controller is deployed
  CONTROLLER_NAMESPACE = "netwrangler"

  # Label used to mark services for virtual IP assignment
  CONTROLLER_LABEL = "netwrangler.dev/ingress"

  # API group for custom resources
  API_GROUP = "netwrangler.dev"

  # API version for custom resources
  API_VERSION = "v1"

  # Directory containing deployment configurations
  DEPLOY_DIR = File.expand_path("../../deploy", __dir__)

  # The kubeconfig the kind facet writes for this project's cluster. Tools that
  # run on the host must be pointed at it explicitly: without it they fall back
  # to the user's own ~/.kube/config, which holds no context for a throwaway
  # cluster the facet never wrote there.
  KUBECONFIG_PATH = File.expand_path("../../.work/kube/config", __dir__)

  # The environment every host-side cluster command is given.
  KUBE_ENV = { "KUBECONFIG" => KUBECONFIG_PATH }.freeze

  # Test pod image (containous/whoami provides a simple HTTP server)
  TEST_POD_IMAGE = "containous/whoami"

  # Result of a command execution
  TestResult = Struct.new(:success, :message, keyword_init: true) do
    def success?
      success
    end
  end

  # Convert a string to a valid Kubernetes name
  #
  # Kubernetes names must:
  # - Be at most 63 characters
  # - Contain only lowercase alphanumeric characters or '-'
  # - Start with an alphanumeric character
  # - End with an alphanumeric character
  #
  # @param text [String] text to convert
  # @param max_length [Integer] maximum length of the name
  # @return [String] valid Kubernetes name
  def self.to_k8s_name(text, max_length: 63)
    # Convert to lowercase and replace non-alphanumeric characters with dashes
    name = text.downcase.gsub(%r{[^a-z0-9]+}, "-")

    # Remove leading/trailing dashes
    name = name.gsub(%r{^-+|-+$}, "")

    # Truncate to max length, ensuring we don't end with a dash
    name = name[0, max_length].gsub(%r{-+$}, "") if name.length > max_length

    # Ensure name starts with alphanumeric (prepend 't' if needed)
    name = "t#{name}" if name.match?(%r{^[^a-z0-9]})

    # Ensure name is not empty
    name = "test" if name.empty?

    name
  end

  # Generate a unique network name
  #
  # @param prefix [String] prefix for the network name
  # @return [String] unique_network_name
  def self.unique_network_name(prefix: "network")
    "#{prefix}-#{SecureRandom.hex(4)}"
  end

  # Generate YAML for a test pod
  #
  # @param name [String] pod name
  # @param namespace [String] namespace for the pod
  # @param node_name [String, nil] specific node to schedule on (optional)
  # @param labels [Hash] additional labels for the pod
  # @param ready [Boolean] whether the pod should pass readiness checks
  # @return [String] YAML manifest for the pod
  def self.pod_yaml(name:, namespace:, node_name: nil, labels: {}, ready: true)
    default_labels = { "app" => "test" }
    all_labels = default_labels.merge(labels)

    # Build readiness probe config
    readiness_probe = {
      "httpGet" => {
        "path" => ready ? "/" : "/nonexistent",
        "port" => ready ? 80 : 9999,
      },
      "initialDelaySeconds" => 1,
      "periodSeconds" => ready ? 2 : 1,
    }
    readiness_probe["failureThreshold"] = 1 unless ready

    # Build container spec
    container = {
      "name" => "whoami",
      "image" => TEST_POD_IMAGE,
      "ports" => [{ "containerPort" => 80 }],
      "readinessProbe" => readiness_probe,
      "resources" => {
        "limits" => { "memory" => "64Mi", "cpu" => "100m" },
        "requests" => { "memory" => "32Mi", "cpu" => "50m" },
      },
    }

    # Build pod spec
    spec = { "containers" => [container] }
    spec["nodeName"] = node_name if node_name

    # Build full pod manifest
    pod = {
      "apiVersion" => "v1",
      "kind" => "Pod",
      "metadata" => {
        "name" => name,
        "namespace" => namespace,
        "labels" => all_labels,
      },
      "spec" => spec,
    }

    pod.to_yaml
  end

  # Generate YAML for an VipNetwork resource
  #
  # @param name [String] network name
  # @param interface [String] network interface
  # @param gateway_ip [String] gateway address
  # @param network_cidr [String] network CIDR (e.g., "10.0.1.0/24")
  # @return [String] YAML manifest for the network
  def self.network_yaml(name:, interface: "eth0", gateway_ip: "10.0.1.1",
                        network_cidr: "10.0.1.0/24")
    spec = {
      "interface" => interface,
      "gatewayIP" => gateway_ip,
      "networkCIDR" => network_cidr,
    }

    network = {
      "apiVersion" => "#{API_GROUP}/#{API_VERSION}",
      "kind" => "VipNetwork",
      "metadata" => {
        "name" => name,
      },
      "spec" => spec,
    }

    network.to_yaml
  end

  # Generate YAML for an VipConfig resource
  #
  # @param name [String] config name
  # @param firewall_mark [Integer] base firewall mark value
  # @param firewall_mark_mask [Integer] bitmask for firewall marks
  # @param route_table [Integer] base route table ID
  # @param routing_priority [Integer] base routing policy rule priority
  # @param max_address_count [Integer, nil] maximum number of virtual IPs (optional)
  # @param cluster_cidrs [Array<String>, nil] cluster-internal CIDRs (optional)
  # @return [String] YAML manifest for the VipConfig
  def self.vip_config_yaml(name:, firewall_mark:, firewall_mark_mask:,
                           route_table:, routing_priority:,
                           max_address_count: 254, cluster_cidrs: nil)
    spec = {
      "firewallMark" => firewall_mark,
      "firewallMarkMask" => firewall_mark_mask,
      "routeTable" => route_table,
      "routingPriority" => routing_priority,
      "maxAddressCount" => max_address_count,
    }
    spec["clusterCIDRs"] = cluster_cidrs if cluster_cidrs

    config = {
      "apiVersion" => "#{API_GROUP}/#{API_VERSION}",
      "kind" => "VipConfig",
      "metadata" => {
        "name" => name,
      },
      "spec" => spec,
    }

    config.to_yaml
  end

  # Label used by the agent to select VipAddress resources for a specific node
  AGENT_NODE_LABEL = "netwrangler.dev/node-name"

  # Generate YAML for an VipAddress resource
  #
  # @param name [String] resource name
  # @param namespace [String] namespace for the resource
  # @param network [String] VipNetwork name
  # @param node_name [String] node where this IP is assigned
  # @param virtual_cidr [String] virtual IP address
  # @param interface [String] network interface name
  # @param network_cidr [String] network CIDR (e.g., "10.0.1.0/24")
  # @param route_table [Integer] routing table ID
  # @param firewall_mark_mask [Integer] bitmask for firewall marks
  # @param firewall_mark [Integer] assigned firewall mark value
  # @param gateway_ip [String, nil] gateway address (optional)
  # @param endpoint_ips [Array<String>] pod endpoint IP addresses
  # @param ports [Array<Hash>] service ports, each with :protocol and :port keys
  # @return [String] YAML manifest for the VipAddress
  def self.vip_address_yaml(name:, namespace:, network:, node_name:, virtual_cidr:,
                            interface:,
                            gateway_ip: nil,
                            firewall_mark: nil,
                            route_table: nil, routing_priority: nil,
                            egress_enabled: nil,
                            source_cidrs: [],
                            endpoint_ips: [], ports: [])
    spec = {
      "network" => network,
      "nodeName" => node_name,
      "virtualCIDR" => virtual_cidr,
      "interface" => interface,
    }
    spec["gatewayIP"] = gateway_ip if gateway_ip
    spec["firewallMark"] = firewall_mark if firewall_mark
    spec["routeTable"] = route_table if route_table
    spec["routingPriority"] = routing_priority if routing_priority
    spec["egressEnabled"] = egress_enabled unless egress_enabled.nil?
    spec["sourceCIDRs"] = source_cidrs unless source_cidrs.empty?
    spec["endpointIPs"] = endpoint_ips unless endpoint_ips.empty?
    spec["ports"] = ports.map { |p| { "protocol" => p[:protocol], "port" => p[:port] } } unless ports.empty?

    vip_address_resource = {
      "apiVersion" => "#{API_GROUP}/#{API_VERSION}",
      "kind" => "VipAddress",
      "metadata" => {
        "name" => name,
        "namespace" => namespace,
        "labels" => {
          AGENT_NODE_LABEL => node_name,
        },
      },
      "spec" => spec,
    }

    vip_address_resource.to_yaml
  end

  # Generate YAML for a VipGateway resource
  #
  # @param name [String] gateway name
  # @param destination_cidr [String] destination network CIDR
  # @param route_table [Integer] routing table ID
  # @param routing_priority [Integer] routing policy rule priority
  # @param pod_selector_labels [Hash] pod selector matchLabels for gateway pod selection
  # @return [String] YAML manifest for the VipGateway
  def self.vip_gateway_yaml(name:, destination_cidr:, route_table:,
                            routing_priority:,
                            pod_selector_labels: { "app" => "gateway" })
    {
      "apiVersion" => "#{API_GROUP}/#{API_VERSION}",
      "kind" => "VipGateway",
      "metadata" => { "name" => name },
      "spec" => {
        "destinationCIDR" => destination_cidr,
        "routeTable" => route_table,
        "routingPriority" => routing_priority,
        "podSelector" => { "matchLabels" => pod_selector_labels },
      },
    }.to_yaml
  end

  # Generate YAML for a Service with virtual IPs
  #
  # @param name [String] service name
  # @param namespace [String] namespace for the service
  # @param virtual_cidrs [Array<String>] list of virtual IP addresses
  # @param selector [Hash] pod selector labels
  # @return [String] YAML manifest for the service
  def self.service_yaml(name:, namespace:, vip_addresses:, selector: { "app" => "test" },
                        external_traffic_policy: "Local")
    spec = {
      "type" => "LoadBalancer",
      "externalIPs" => vip_addresses,
      "selector" => selector,
      "ports" => [
        {
          "protocol" => "TCP",
          "port" => 80,
          "targetPort" => 80,
        },
      ],
    }

    spec["externalTrafficPolicy"] = external_traffic_policy if external_traffic_policy

    service = {
      "apiVersion" => "v1",
      "kind" => "Service",
      "metadata" => {
        "name" => name,
        "namespace" => namespace,
        "labels" => {
          CONTROLLER_LABEL => "enabled",
        },
      },
      "spec" => spec,
    }

    service.to_yaml
  end

  # Label prefix used by the agent for VIP annotations
  AGENT_LABEL_PREFIX = "netwrangler.dev"

  # Generate YAML for a Service annotated for the agent
  #
  # Creates a Service with the netwrangler.dev/node-name label and
  # netwrangler.dev/* annotations that the agent watches.
  #
  # @param name [String] service name
  # @param namespace [String] namespace for the service
  # @param node_name [String] target node name
  # @param interface [String] network interface
  # @param network [String] network name
  # @param network_prefix [String] network prefix (e.g., "24")
  # @param gateway_ip [String] gateway IP address
  # @param load_balancer_ip [String] load balancer IP address
  # @param selector [Hash] pod selector labels
  # @return [String] YAML manifest for the annotated service
  def self.agent_service_yaml(name:, namespace:, node_name:, interface:, network:,
                              network_prefix:, gateway_ip:, load_balancer_ip:,
                              selector: { "app" => "test" })
    service = {
      "apiVersion" => "v1",
      "kind" => "Service",
      "metadata" => {
        "name" => name,
        "namespace" => namespace,
        "labels" => {
          "#{AGENT_LABEL_PREFIX}/node-name" => node_name,
        },
        "annotations" => {
          "#{AGENT_LABEL_PREFIX}/interface" => interface,
          "#{AGENT_LABEL_PREFIX}/network" => network,
          "#{AGENT_LABEL_PREFIX}/network-prefix" => network_prefix,
          "#{AGENT_LABEL_PREFIX}/gateway-ip" => gateway_ip,
        },
      },
      "spec" => {
        "type" => "LoadBalancer",
        "loadBalancerIP" => load_balancer_ip,
        "externalTrafficPolicy" => "Local",
        "selector" => selector,
        "ports" => [
          {
            "protocol" => "TCP",
            "port" => 80,
            "targetPort" => 80,
          },
        ],
      },
    }

    service.to_yaml
  end

  # Generate YAML for an EndpointSlice annotated for the agent
  #
  # Creates an EndpointSlice with the netwrangler.dev/node-name label and
  # netwrangler.dev/* annotations that the agent watches.
  #
  # @param name [String] endpoint slice name
  # @param namespace [String] namespace for the endpoint slice
  # @param service_name [String] associated service name
  # @param node_name [String] target node name
  # @param interface [String] network interface
  # @param network [String] network name
  # @param network_prefix [String] network prefix (e.g., "24")
  # @param gateway_ip [String] gateway IP address
  # @param load_balancer_ip [String] load balancer IP address
  # @param addresses [Array<String>] list of endpoint IP addresses
  # @return [String] YAML manifest for the annotated endpoint slice
  def self.agent_endpoint_slice_yaml(name:, namespace:, service_name:, node_name:,
                                     interface:, network:, network_prefix:,
                                     gateway_ip:, load_balancer_ip:, addresses:)
    endpoints = addresses.map do |addr|
      {
        "addresses" => [addr],
        "conditions" => { "ready" => true },
      }
    end

    endpoint_slice = {
      "apiVersion" => "discovery.k8s.io/v1",
      "kind" => "EndpointSlice",
      "metadata" => {
        "name" => name,
        "namespace" => namespace,
        "labels" => {
          "kubernetes.io/service-name" => service_name,
          "#{AGENT_LABEL_PREFIX}/node-name" => node_name,
        },
        "annotations" => {
          "#{AGENT_LABEL_PREFIX}/interface" => interface,
          "#{AGENT_LABEL_PREFIX}/network" => network,
          "#{AGENT_LABEL_PREFIX}/network-prefix" => network_prefix,
          "#{AGENT_LABEL_PREFIX}/gateway-ip" => gateway_ip,
          "#{AGENT_LABEL_PREFIX}/load-balancer-ip" => load_balancer_ip,
        },
      },
      "addressType" => "IPv4",
      "ports" => [
        {
          "protocol" => "TCP",
          "port" => 80,
        },
      ],
      "endpoints" => endpoints,
    }

    endpoint_slice.to_yaml
  end
end
