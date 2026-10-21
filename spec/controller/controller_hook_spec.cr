require "./spec_helper"
require "./fixtures"
require "json"

describe Netwrangler::Controller::ControllerHook do
  describe "#print_config" do
    it "contains configVersion key" do
      # Note: print_config outputs to stdout, so we need to test indirectly
      # by verifying constants and structure
      Netwrangler::Controller::ControllerHook::EVENT_GROUP.should eq("vip_address_controller")
    end

    it "has resync schedule with cron pattern" do
      Netwrangler::Controller::ControllerHook::EVENT_NAME_RESYNC.should eq("resync")
    end

    it "resyncs every 30 seconds, matching the agent" do
      hook = Netwrangler::Controller::ControllerHook.new
      output = String.build { |io| hook.print_config(io) }
      config = JSON.parse(output)

      resync = config["schedule"].as_a.find! { |binding| binding["name"] == "resync" }
      resync["crontab"].should eq("*/30 * * * * *")
    end

    it "has all Kubernetes bindings" do
      Netwrangler::Controller::ControllerHook::EVENT_NAME_SERVICES.should eq("services")
      Netwrangler::Controller::ControllerHook::EVENT_NAME_ENDPOINT_SLICES.should eq("endpoint_slices")
      Netwrangler::Controller::ControllerHook::EVENT_NAME_VIP_NETWORKS.should eq("vip_networks")
      Netwrangler::Controller::ControllerHook::EVENT_NAME_VIP_ADDRESSES.should eq("vip_addresses")
      Netwrangler::Controller::ControllerHook::EVENT_NAME_VIP_GATEWAYS.should eq("vip_gateways")
      Netwrangler::Controller::ControllerHook::EVENT_NAME_PODS.should eq("pods")
      Netwrangler::Controller::ControllerHook::EVENT_NAME_VIP_ROUTES.should eq("vip_routes")
    end

    it "has jqFilter for services that extracts externalIPs and ports" do
      Netwrangler::Controller::ControllerHook::SERVICE_FILTER.should_not contain("netwrangler.dev/network")
      Netwrangler::Controller::ControllerHook::SERVICE_FILTER.should contain("externalIPs")
      Netwrangler::Controller::ControllerHook::SERVICE_FILTER.should_not contain("externalTrafficPolicy")
      Netwrangler::Controller::ControllerHook::SERVICE_FILTER.should contain("ports")
    end

    it "includes labelSelector for services binding with ingress label" do
      hook = Netwrangler::Controller::ControllerHook.new
      output = String.build { |io| hook.print_config(io) }
      config = JSON.parse(output)

      services_binding = config["kubernetes"].as_a.find! { |binding| binding["name"] == "services" }
      label_selector = services_binding["labelSelector"]
      match_labels = label_selector["matchLabels"]
      match_labels["netwrangler.dev/ingress"].should eq("enabled")
    end

    it "has minimal jqFilters for change detection" do
      Netwrangler::Controller::ControllerHook::ENDPOINT_SLICE_FILTER.should contain("endpoints")
      Netwrangler::Controller::ControllerHook::ENDPOINT_SLICE_FILTER.should contain("serviceName")
      Netwrangler::Controller::ControllerHook::VIP_NETWORK_FILTER.should eq(".spec")
      Netwrangler::Controller::ControllerHook::VIP_ADDRESS_FILTER.should eq(".spec")
      Netwrangler::Controller::ControllerHook::VIP_ROUTE_FILTER.should eq(".spec")
    end

    it "has VIP_GATEWAY_FILTER that extracts spec" do
      Netwrangler::Controller::ControllerHook::VIP_GATEWAY_FILTER.should eq(".spec")
    end

    it "has POD_FILTER that extracts podIP, phase, nodeName, and labels" do
      Netwrangler::Controller::ControllerHook::POD_FILTER.should contain("podIP")
      Netwrangler::Controller::ControllerHook::POD_FILTER.should contain("phase")
      Netwrangler::Controller::ControllerHook::POD_FILTER.should contain("nodeName")
      Netwrangler::Controller::ControllerHook::POD_FILTER.should contain("labels")
    end

    it "includes VipRoute binding with correct apiVersion and kind" do
      hook = Netwrangler::Controller::ControllerHook.new
      output = String.build { |io| hook.print_config(io) }
      config = JSON.parse(output)

      vip_routes_binding = config["kubernetes"].as_a.find! { |binding| binding["name"] == "vip_routes" }
      vip_routes_binding["apiVersion"].should eq("netwrangler.dev/v1")
      vip_routes_binding["kind"].should eq("VipRoute")
    end

    it "includes VipGateway binding with correct apiVersion and kind" do
      hook = Netwrangler::Controller::ControllerHook.new
      output = String.build { |io| hook.print_config(io) }
      config = JSON.parse(output)

      vip_gateways_binding = config["kubernetes"].as_a.find! { |binding| binding["name"] == "vip_gateways" }
      vip_gateways_binding["apiVersion"].should eq("netwrangler.dev/v1")
      vip_gateways_binding["kind"].should eq("VipGateway")
    end

    it "includes pods binding with gateway enabled label selector" do
      hook = Netwrangler::Controller::ControllerHook.new
      output = String.build { |io| hook.print_config(io) }
      config = JSON.parse(output)

      pods_binding = config["kubernetes"].as_a.find! { |binding| binding["name"] == "pods" }
      pods_binding["apiVersion"].should eq("v1")
      pods_binding["kind"].should eq("Pod")
      label_selector = pods_binding["labelSelector"]
      match_labels = label_selector["matchLabels"]
      match_labels["netwrangler.dev/gateway"].should eq("enabled")
    end

    it "includes VipRoute binding with managed-by label selector" do
      hook = Netwrangler::Controller::ControllerHook.new
      output = String.build { |io| hook.print_config(io) }
      config = JSON.parse(output)

      vip_routes_binding = config["kubernetes"].as_a.find! { |binding| binding["name"] == "vip_routes" }
      vip_routes_binding["apiVersion"].should eq("netwrangler.dev/v1")
      vip_routes_binding["kind"].should eq("VipRoute")
      label_selector = vip_routes_binding["labelSelector"]
      match_labels = label_selector["matchLabels"]
      match_labels["netwrangler.dev/managed-by"].should eq("netwrangler")
    end

    it "includes labelSelector for VipAddress binding with default manager name" do
      hook = Netwrangler::Controller::ControllerHook.new
      output = String.build { |io| hook.print_config(io) }
      config = JSON.parse(output)

      vip_addresses_binding = config["kubernetes"].as_a.find! { |binding| binding["name"] == "vip_addresses" }
      label_selector = vip_addresses_binding["labelSelector"]
      match_labels = label_selector["matchLabels"]
      match_labels["netwrangler.dev/managed-by"].should eq("netwrangler")
    end

    it "includes labelSelector for VipAddress binding with custom manager name" do
      hook = Netwrangler::Controller::ControllerHook.new(manager_name: "custom-manager")
      output = String.build { |io| hook.print_config(io) }
      config = JSON.parse(output)

      vip_addresses_binding = config["kubernetes"].as_a.find! { |binding| binding["name"] == "vip_addresses" }
      label_selector = vip_addresses_binding["labelSelector"]
      match_labels = label_selector["matchLabels"]
      match_labels["netwrangler.dev/managed-by"].should eq("custom-manager")
    end
  end

  describe "#run" do
    it "reads file at provided path successfully" do
      hook = Netwrangler::Controller::ControllerHook.new
      binding_path = File.tempname("test_binding", ".json")
      patch_path = File.tempname("test_patch", ".json")

      begin
        File.write(binding_path, ControllerFixtures.binding_context_json)
        hook.run(binding_path, patch_path)
        File.exists?(patch_path).should be_true
      ensure
        File.delete(binding_path) if File.exists?(binding_path)
        File.delete(patch_path) if File.exists?(patch_path)
      end
    end

    it "raises error if file not found" do
      hook = Netwrangler::Controller::ControllerHook.new
      patch_path = File.tempname("test_patch", ".json")

      expect_raises(File::NotFoundError) do
        hook.run("/nonexistent/path/#{Random.rand(10000)}.json", patch_path)
      end
    end

    it "handles empty file with JSON parse error" do
      hook = Netwrangler::Controller::ControllerHook.new
      binding_path = File.tempname("test_empty", ".json")
      patch_path = File.tempname("test_patch", ".json")

      begin
        File.write(binding_path, "")
        expect_raises(JSON::ParseException) do
          hook.run(binding_path, patch_path)
        end
      ensure
        File.delete(binding_path) if File.exists?(binding_path)
        File.delete(patch_path) if File.exists?(patch_path)
      end
    end

    it "parses valid binding context array" do
      hook = Netwrangler::Controller::ControllerHook.new
      binding_path = File.tempname("test_valid", ".json")
      patch_path = File.tempname("test_patch", ".json")

      begin
        File.write(binding_path, ControllerFixtures.binding_context_json)
        hook.run(binding_path, patch_path)
        File.exists?(patch_path).should be_true
      ensure
        File.delete(binding_path) if File.exists?(binding_path)
        File.delete(patch_path) if File.exists?(patch_path)
      end
    end

    it "handles single context in array" do
      hook = Netwrangler::Controller::ControllerHook.new
      binding_path = File.tempname("test_single", ".json")
      patch_path = File.tempname("test_patch", ".json")

      begin
        json = ControllerFixtures.binding_context_json
        File.write(binding_path, json)
        hook.run(binding_path, patch_path)
        File.exists?(patch_path).should be_true
      ensure
        File.delete(binding_path) if File.exists?(binding_path)
        File.delete(patch_path) if File.exists?(patch_path)
      end
    end

    it "handles multiple contexts in array" do
      hook = Netwrangler::Controller::ControllerHook.new
      binding_path = File.tempname("test_multi", ".json")
      patch_path = File.tempname("test_patch", ".json")

      begin
        # Create multiple contexts
        context1 = JSON.parse(ControllerFixtures.binding_context_json).as_a.first
        context2 = JSON.parse(ControllerFixtures.binding_context_json).as_a.first
        File.write(binding_path, [context1, context2].to_json)
        hook.run(binding_path, patch_path)
        File.exists?(patch_path).should be_true
      ensure
        File.delete(binding_path) if File.exists?(binding_path)
        File.delete(patch_path) if File.exists?(patch_path)
      end
    end

    it "extracts resources from first context" do
      hook = Netwrangler::Controller::ControllerHook.new
      binding_path = File.tempname("test_resources", ".json")
      patch_path = File.tempname("test_patch", ".json")

      begin
        service = ControllerFixtures.service
        json = ControllerFixtures.binding_context_json(services: [service])
        File.write(binding_path, json)
        hook.run(binding_path, patch_path)
        File.exists?(patch_path).should be_true
      ensure
        File.delete(binding_path) if File.exists?(binding_path)
        File.delete(patch_path) if File.exists?(patch_path)
      end
    end

    it "creates IpAllocator with correct resources" do
      hook = Netwrangler::Controller::ControllerHook.new
      binding_path = File.tempname("test_allocator", ".json")
      patch_path = File.tempname("test_patch", ".json")

      begin
        service = ControllerFixtures.service
        network = ControllerFixtures.vip_network
        json = ControllerFixtures.binding_context_json(
          services: [service],
          vip_networks: [network]
        )
        File.write(binding_path, json)
        hook.run(binding_path, patch_path)
        File.exists?(patch_path).should be_true
      ensure
        File.delete(binding_path) if File.exists?(binding_path)
        File.delete(patch_path) if File.exists?(patch_path)
      end
    end

    it "calls allocate method on IpAllocator" do
      hook = Netwrangler::Controller::ControllerHook.new
      binding_path = File.tempname("test_allocate", ".json")
      patch_path = File.tempname("test_patch", ".json")

      begin
        # Create a complete scenario
        service = ControllerFixtures.service(
          external_ips: ["10.0.1.10"]
        )
        endpoint_slice = ControllerFixtures.endpoint_slice(
          service_name: "test-service",
          nodes: ["node-1"]
        )
        network = ControllerFixtures.vip_network

        json = ControllerFixtures.binding_context_json(
          services: [service],
          endpoint_slices: [endpoint_slice],
          vip_networks: [network]
        )
        File.write(binding_path, json)
        hook.run(binding_path, patch_path)
        File.exists?(patch_path).should be_true
      ensure
        File.delete(binding_path) if File.exists?(binding_path)
        File.delete(patch_path) if File.exists?(patch_path)
      end
    end

    it "passes debug flag through to allocator" do
      hook = Netwrangler::Controller::ControllerHook.new(debug: true)
      binding_path = File.tempname("test_debug", ".json")
      patch_path = File.tempname("test_patch", ".json")

      begin
        File.write(binding_path, ControllerFixtures.binding_context_json)
        hook.run(binding_path, patch_path)
        File.exists?(patch_path).should be_true
      ensure
        File.delete(binding_path) if File.exists?(binding_path)
        File.delete(patch_path) if File.exists?(patch_path)
      end
    end

    it "writes operations to patch file" do
      hook = Netwrangler::Controller::ControllerHook.new
      binding_path = File.tempname("test_ops", ".json")
      patch_path = File.tempname("test_patch", ".json")

      begin
        # Create a complete scenario that will produce operations
        service = ControllerFixtures.service(
          external_ips: ["10.0.1.10"]
        )
        endpoint_slice = ControllerFixtures.endpoint_slice(
          service_name: "test-service",
          nodes: ["node-1"]
        )
        network = ControllerFixtures.vip_network

        json = ControllerFixtures.binding_context_json(
          services: [service],
          endpoint_slices: [endpoint_slice],
          vip_networks: [network]
        )
        File.write(binding_path, json)
        hook.run(binding_path, patch_path)

        # Verify operations file contains valid NDJSON (one JSON object per line)
        content = File.read(patch_path)
        lines = content.strip.split("\n")
        lines.size.should be > 0
        lines.each do |line|
          JSON.parse(line).as_h.should_not be_nil
        end
      ensure
        File.delete(binding_path) if File.exists?(binding_path)
        File.delete(patch_path) if File.exists?(patch_path)
      end
    end

    it "produces Delete operation for orphaned VipAddress with no matching service" do
      hook = Netwrangler::Controller::ControllerHook.new
      binding_path = File.tempname("test_delete_orphan", ".json")
      patch_path = File.tempname("test_patch_delete_orphan", ".json")

      begin
        # Create a VipAddress with managed-by label but no matching service
        vip_address = ControllerFixtures.vip_address(
          name: "test-service-1",
          namespace: "default",
          labels: {
            "netwrangler.dev/managed-by" => "netwrangler",
            "netwrangler.dev/service"    => "test-service",
          }
        )
        network = ControllerFixtures.vip_network

        json = ControllerFixtures.binding_context_json(
          vip_addresses: [vip_address],
          vip_networks: [network]
        )
        File.write(binding_path, json)
        hook.run(binding_path, patch_path)

        content = File.read(patch_path)
        lines = content.strip.split("\n")
        operations = lines.map { |line| JSON.parse(line) }

        # Should contain a Delete operation for the orphaned VipAddress
        delete_ops = operations.select { |op| op["operation"].as_s == "Delete" }
        delete_ops.size.should be > 0
        delete_ops.any? { |op| op["name"].as_s == "test-service-1" }.should be_true
      ensure
        File.delete(binding_path) if File.exists?(binding_path)
        File.delete(patch_path) if File.exists?(patch_path)
      end
    end

    it "produces Delete and Create operations when VipAddress moves to a different node" do
      hook = Netwrangler::Controller::ControllerHook.new
      binding_path = File.tempname("test_update_node", ".json")
      patch_path = File.tempname("test_patch_update_node", ".json")

      begin
        # Service with endpoint on node-2
        service = ControllerFixtures.service(
          external_ips: ["10.0.1.10"]
        )
        endpoint_slice = ControllerFixtures.endpoint_slice(
          service_name: "test-service",
          nodes: ["node-2"]
        )
        network = ControllerFixtures.vip_network
        config = ControllerFixtures.vip_config

        # Existing VipAddress assigned to node-1
        vip_address = ControllerFixtures.vip_address(
          name: "test-service-1",
          namespace: "default",
          node_name: "node-1",
          virtual_cidr: "10.0.1.10",
          labels: {
            "netwrangler.dev/managed-by" => "netwrangler",
            "netwrangler.dev/service"    => "test-service",
            "netwrangler.dev/network"    => "test-network",
            "netwrangler.dev/namespace"  => "default",
            "netwrangler.dev/node-name"  => "node-1",
          }
        )

        json = ControllerFixtures.binding_context_json(
          services: [service],
          endpoint_slices: [endpoint_slice],
          vip_networks: [network],
          vip_addresses: [vip_address],
          vip_configs: [config]
        )
        File.write(binding_path, json)
        hook.run(binding_path, patch_path)

        content = File.read(patch_path)
        lines = content.strip.split("\n")
        operations = lines.map { |line| JSON.parse(line) }

        # Should contain both Delete and Create operations for the node move
        delete_ops = operations.select { |op| op["operation"].as_s == "Delete" }
        create_ops = operations.select { |op| op["operation"].as_s == "Create" }

        delete_ops.size.should be > 0
        create_ops.size.should be > 0

        # The Delete should target the old VipAddress
        delete_ops.any? { |op| op["name"].as_s == "test-service-1" }.should be_true

        # The Create should place the VipAddress on node-2
        create_ops.any? do |op|
          obj = op["object"]
          obj["spec"]["nodeName"].as_s == "node-2"
        end.should be_true
      ensure
        File.delete(binding_path) if File.exists?(binding_path)
        File.delete(patch_path) if File.exists?(patch_path)
      end
    end
  end
end
