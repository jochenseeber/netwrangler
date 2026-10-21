require "./spec_helper"
require "./fixtures"

describe Netwrangler::Controller::BindingContext do
  describe "JSON parsing" do
    it "parses empty binding context" do
      json = ControllerFixtures.binding_context_json
      contexts = Array(Netwrangler::Controller::BindingContext).from_json(json)
      context = contexts.first

      context.services.should be_empty
      context.endpoint_slices.should be_empty
      context.vip_networks.should be_empty
      context.vip_addresses.should be_empty
    end

    it "parses services from binding context" do
      service = ControllerFixtures.service(
        name: "my-service",
        namespace: "prod",
        external_ips: ["10.0.1.10", "10.0.1.11"]
      )

      json = ControllerFixtures.binding_context_json(services: [service])
      contexts = Array(Netwrangler::Controller::BindingContext).from_json(json)
      context = contexts.first

      context.services.size.should eq(1)
      parsed_service = context.services.first
      parsed_service.metadata.name.should eq("my-service")
      parsed_service.metadata.namespace.should eq("prod")
      parsed_service.spec.try(&.external_ips).should eq(["10.0.1.10", "10.0.1.11"])
    end

    it "parses endpoint slices from binding context" do
      endpoint_slice = ControllerFixtures.endpoint_slice(
        name: "svc-abc123",
        namespace: "default",
        service_name: "svc",
        nodes: ["node-1", "node-2"]
      )

      json = ControllerFixtures.binding_context_json(endpoint_slices: [endpoint_slice])
      contexts = Array(Netwrangler::Controller::BindingContext).from_json(json)
      context = contexts.first

      context.endpoint_slices.size.should eq(1)
      parsed_slice = context.endpoint_slices.first
      parsed_slice.metadata.name.should eq("svc-abc123")
      parsed_slice.metadata.namespace.should eq("default")
      parsed_slice.endpoints.try(&.size).should eq(2)
    end

    it "parses VIP networks from binding context" do
      network = ControllerFixtures.vip_network(
        name: "main-net",
        interface: "eth1",
        gateway_ip: "192.168.1.1",
        network_cidr: "192.168.0.0/16"
      )

      json = ControllerFixtures.binding_context_json(vip_networks: [network])
      contexts = Array(Netwrangler::Controller::BindingContext).from_json(json)
      context = contexts.first

      context.vip_networks.size.should eq(1)
      parsed_network = context.vip_networks.first
      parsed_network.metadata.name.should eq("main-net")
      parsed_network.interface.should eq("eth1")
      parsed_network.gateway_ip.should eq("192.168.1.1")
      parsed_network.network_cidr.should eq("192.168.0.0/16")
    end

    it "parses virtual IPs from binding context" do
      vip_address = ControllerFixtures.vip_address(
        name: "net-10-0-1-10",
        namespace: "default",
        network: "net",
        node_name: "node-1",
        virtual_cidr: "10.0.1.10/24"
      )

      json = ControllerFixtures.binding_context_json(vip_addresses: [vip_address])
      contexts = Array(Netwrangler::Controller::BindingContext).from_json(json)
      context = contexts.first

      context.vip_addresses.size.should eq(1)
      parsed_ip = context.vip_addresses.first
      parsed_ip.metadata.name.should eq("net-10-0-1-10")
      parsed_ip.metadata.namespace.should eq("default")
      parsed_ip.network.should eq("net")
      parsed_ip.node_name.should eq("node-1")
      parsed_ip.virtual_cidr.should eq("10.0.1.10/24")
    end

    it "parses all resource types together" do
      service = ControllerFixtures.service
      endpoint_slice = ControllerFixtures.endpoint_slice
      network = ControllerFixtures.vip_network
      vip_address = ControllerFixtures.vip_address

      json = ControllerFixtures.binding_context_json(
        services: [service],
        endpoint_slices: [endpoint_slice],
        vip_networks: [network],
        vip_addresses: [vip_address]
      )
      contexts = Array(Netwrangler::Controller::BindingContext).from_json(json)
      context = contexts.first

      context.services.size.should eq(1)
      context.endpoint_slices.size.should eq(1)
      context.vip_networks.size.should eq(1)
      context.vip_addresses.size.should eq(1)
    end

    it "parses multiple services" do
      service1 = ControllerFixtures.service(name: "svc-1")
      service2 = ControllerFixtures.service(name: "svc-2")

      json = ControllerFixtures.binding_context_json(services: [service1, service2])
      contexts = Array(Netwrangler::Controller::BindingContext).from_json(json)
      context = contexts.first

      context.services.size.should eq(2)
      context.services.map(&.metadata.name).should contain("svc-1")
      context.services.map(&.metadata.name).should contain("svc-2")
    end

    it "handles missing snapshots gracefully" do
      # Minimal binding context with missing snapshot keys
      json = %([{"binding": "test", "snapshots": {}}])
      contexts = Array(Netwrangler::Controller::BindingContext).from_json(json)
      context = contexts.first

      context.services.should be_empty
      context.endpoint_slices.should be_empty
      context.vip_networks.should be_empty
      context.vip_addresses.should be_empty
    end

    it "preserves service ingress label" do
      service = ControllerFixtures.service

      json = ControllerFixtures.binding_context_json(services: [service])
      contexts = Array(Netwrangler::Controller::BindingContext).from_json(json)
      context = contexts.first

      parsed_service = context.services.first
      parsed_service.metadata.labels.try(&.["netwrangler.dev/ingress"]?).should eq("enabled")
    end

    it "preserves endpoint slice labels" do
      endpoint_slice = ControllerFixtures.endpoint_slice(service_name: "linked-service")

      json = ControllerFixtures.binding_context_json(endpoint_slices: [endpoint_slice])
      contexts = Array(Netwrangler::Controller::BindingContext).from_json(json)
      context = contexts.first

      parsed_slice = context.endpoint_slices.first
      parsed_slice.metadata.labels.try(&.["kubernetes.io/service-name"]?).should eq("linked-service")
    end

    it "parses VIP configs from binding context" do
      config = ControllerFixtures.vip_config(name: "test-config")

      json = ControllerFixtures.binding_context_json(vip_configs: [config])
      contexts = Array(Netwrangler::Controller::BindingContext).from_json(json)
      context = contexts.first

      context.vip_configs.size.should eq(1)
      context.vip_configs.first.metadata.name.should eq("test-config")
    end

    it "preserves nil gateway_ip" do
      # Create VIP network without gateway
      metadata = Netwrangler::Model::ObjectMeta.new(
        name: "no-gateway-net",
        uid: "uid-123"
      )
      spec = Netwrangler::Model::VipNetwork::Spec.new(
        interface: "eth0",
        gateway_ip: nil,
        network_cidr: "10.0.1.0/24"
      )
      network = Netwrangler::Model::VipNetwork.new(metadata: metadata, spec: spec)

      json = ControllerFixtures.binding_context_json(vip_networks: [network])
      contexts = Array(Netwrangler::Controller::BindingContext).from_json(json)
      context = contexts.first

      parsed_network = context.vip_networks.first
      parsed_network.gateway_ip.should be_nil
    end
  end

  describe "Synchronization events with objects array" do
    it "parses empty sync binding context" do
      json = ControllerFixtures.binding_context_json_sync
      contexts = Array(Netwrangler::Controller::BindingContext).from_json(json)
      context = contexts.first

      context.services.should be_empty
      context.endpoint_slices.should be_empty
      context.vip_networks.should be_empty
      context.vip_addresses.should be_empty
    end

    it "parses services from objects array" do
      service1 = ControllerFixtures.service(name: "svc-1")
      service2 = ControllerFixtures.service(name: "svc-2")

      json = ControllerFixtures.binding_context_json_sync(services: [service1, service2])
      contexts = Array(Netwrangler::Controller::BindingContext).from_json(json)
      context = contexts.first

      context.services.size.should eq(2)
      context.services.map(&.metadata.name).should contain("svc-1")
      context.services.map(&.metadata.name).should contain("svc-2")
    end

    it "parses endpoint slices from objects array" do
      slice1 = ControllerFixtures.endpoint_slice(name: "slice-1", nodes: ["node-1"])
      slice2 = ControllerFixtures.endpoint_slice(name: "slice-2", nodes: ["node-2"])

      json = ControllerFixtures.binding_context_json_sync(endpoint_slices: [slice1, slice2])
      contexts = Array(Netwrangler::Controller::BindingContext).from_json(json)
      context = contexts.first

      context.endpoint_slices.size.should eq(2)
      context.endpoint_slices.map(&.metadata.name).should contain("slice-1")
      context.endpoint_slices.map(&.metadata.name).should contain("slice-2")
    end

    it "parses VIP networks from objects array" do
      net1 = ControllerFixtures.vip_network(name: "net-1")
      net2 = ControllerFixtures.vip_network(name: "net-2")

      json = ControllerFixtures.binding_context_json_sync(vip_networks: [net1, net2])
      contexts = Array(Netwrangler::Controller::BindingContext).from_json(json)
      context = contexts.first

      context.vip_networks.size.should eq(2)
      context.vip_networks.map(&.metadata.name).should contain("net-1")
      context.vip_networks.map(&.metadata.name).should contain("net-2")
    end

    it "parses virtual IPs from objects array" do
      ip1 = ControllerFixtures.vip_address(name: "ip-1", virtual_cidr: "10.0.1.10")
      ip2 = ControllerFixtures.vip_address(name: "ip-2", virtual_cidr: "10.0.1.11")

      json = ControllerFixtures.binding_context_json_sync(vip_addresses: [ip1, ip2])
      contexts = Array(Netwrangler::Controller::BindingContext).from_json(json)
      context = contexts.first

      context.vip_addresses.size.should eq(2)
      context.vip_addresses.map(&.metadata.name).should contain("ip-1")
      context.vip_addresses.map(&.metadata.name).should contain("ip-2")
    end

    it "parses all resource types from objects arrays" do
      service = ControllerFixtures.service
      endpoint_slice = ControllerFixtures.endpoint_slice
      network = ControllerFixtures.vip_network
      vip_address = ControllerFixtures.vip_address

      json = ControllerFixtures.binding_context_json_sync(
        services: [service],
        endpoint_slices: [endpoint_slice],
        vip_networks: [network],
        vip_addresses: [vip_address]
      )
      contexts = Array(Netwrangler::Controller::BindingContext).from_json(json)
      context = contexts.first

      context.services.size.should eq(1)
      context.endpoint_slices.size.should eq(1)
      context.vip_networks.size.should eq(1)
      context.vip_addresses.size.should eq(1)
    end
  end
end
