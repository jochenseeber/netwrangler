require "./spec_helper"
require "./fixtures"
require "json"

describe Netwrangler::Controller::ControllerHook do
  describe "VipGateway resolution via Pods" do
    it "creates VipRoutes for matching Running Pods with podIP" do
      hook = Netwrangler::Controller::ControllerHook.new
      binding_path = File.tempname("test_vip_gw_create", ".json")
      patch_path = File.tempname("test_patch_vip_gw_create", ".json")

      begin
        gateway = ControllerFixtures.vip_gateway(
          name: "my-gateway",
          route_table: 200,
          routing_priority: 200,
          pod_selector_labels: {"app" => "gateway"}
        )
        pod1 = ControllerFixtures.pod(
          name: "gw-pod-1",
          namespace: "default",
          uid: "pod-uid-1",
          labels: {"app" => "gateway", "netwrangler.dev/gateway" => "enabled"},
          pod_ip: "10.244.1.1",
          phase: "Running",
          node_name: "node-1"
        )
        pod2 = ControllerFixtures.pod(
          name: "gw-pod-2",
          namespace: "default",
          uid: "pod-uid-2",
          labels: {"app" => "gateway", "netwrangler.dev/gateway" => "enabled"},
          pod_ip: "10.244.1.2",
          phase: "Running",
          node_name: "node-2"
        )

        json = ControllerFixtures.binding_context_json(
          vip_gateways: [gateway],
          pods: [pod1, pod2]
        )
        File.write(binding_path, json)
        hook.run(binding_path, patch_path)

        content = File.read(patch_path)
        lines = content.strip.split("\n")
        operations = lines.map { |line| JSON.parse(line) }

        create_ops = operations.select { |op| op["operation"].as_s == "Create" }
        create_ops.size.should eq(2)

        route_1 = create_ops.find! do |op|
          op["object"]["metadata"]["name"].as_s == "gw-pod-1-my-gateway"
        end
        route_1["object"]["spec"]["podIP"].as_s.should eq("10.244.1.1")
        route_1["object"]["spec"]["destinationCIDR"].as_s.should eq("10.0.0.0/8")
        route_1["object"]["spec"]["routeTable"].as_i.should eq(200)
        route_1["object"]["spec"]["routingPriority"].as_i.should eq(200)
        route_1["object"]["metadata"]["namespace"].as_s.should eq("default")

        route_2 = create_ops.find! do |op|
          op["object"]["metadata"]["name"].as_s == "gw-pod-2-my-gateway"
        end
        route_2["object"]["spec"]["podIP"].as_s.should eq("10.244.1.2")
      ensure
        File.delete(binding_path) if File.exists?(binding_path)
        File.delete(patch_path) if File.exists?(patch_path)
      end
    end

    it "excludes Pods with non-matching labels" do
      hook = Netwrangler::Controller::ControllerHook.new
      binding_path = File.tempname("test_vip_gw_nomatch", ".json")
      patch_path = File.tempname("test_patch_vip_gw_nomatch", ".json")

      begin
        gateway = ControllerFixtures.vip_gateway(
          name: "my-gateway",
          pod_selector_labels: {"app" => "gateway"}
        )
        # Pod has wrong label value
        pod = ControllerFixtures.pod(
          name: "other-pod",
          namespace: "default",
          uid: "pod-uid-other",
          labels: {"app" => "other", "netwrangler.dev/gateway" => "enabled"},
          pod_ip: "10.244.1.5",
          phase: "Running",
          node_name: "node-1"
        )

        json = ControllerFixtures.binding_context_json(
          vip_gateways: [gateway],
          pods: [pod]
        )
        File.write(binding_path, json)
        hook.run(binding_path, patch_path)

        content = File.read(patch_path)
        if content.strip.empty?
          true.should be_true
        else
          lines = content.strip.split("\n")
          operations = lines.map { |line| JSON.parse(line) }

          vip_route_ops = operations.select do |op|
            kind = op["object"]?.try(&.["kind"]?.try(&.as_s)) || op["kind"]?.try(&.as_s)
            kind == "VipRoute"
          end
          vip_route_ops.should be_empty
        end
      ensure
        File.delete(binding_path) if File.exists?(binding_path)
        File.delete(patch_path) if File.exists?(patch_path)
      end
    end

    it "excludes non-Running Pods" do
      hook = Netwrangler::Controller::ControllerHook.new
      binding_path = File.tempname("test_vip_gw_notrunning", ".json")
      patch_path = File.tempname("test_patch_vip_gw_notrunning", ".json")

      begin
        gateway = ControllerFixtures.vip_gateway(
          name: "my-gateway",
          pod_selector_labels: {"app" => "gateway"}
        )
        pod = ControllerFixtures.pod(
          name: "pending-pod",
          namespace: "default",
          uid: "pod-uid-pending",
          labels: {"app" => "gateway", "netwrangler.dev/gateway" => "enabled"},
          pod_ip: "10.244.1.3",
          phase: "Pending",
          node_name: "node-1"
        )

        json = ControllerFixtures.binding_context_json(
          vip_gateways: [gateway],
          pods: [pod]
        )
        File.write(binding_path, json)
        hook.run(binding_path, patch_path)

        content = File.read(patch_path)
        if content.strip.empty?
          true.should be_true
        else
          lines = content.strip.split("\n")
          operations = lines.map { |line| JSON.parse(line) }

          vip_route_ops = operations.select do |op|
            kind = op["object"]?.try(&.["kind"]?.try(&.as_s)) || op["kind"]?.try(&.as_s)
            kind == "VipRoute"
          end
          vip_route_ops.should be_empty
        end
      ensure
        File.delete(binding_path) if File.exists?(binding_path)
        File.delete(patch_path) if File.exists?(patch_path)
      end
    end

    it "excludes Pods without podIP" do
      hook = Netwrangler::Controller::ControllerHook.new
      binding_path = File.tempname("test_vip_gw_noip", ".json")
      patch_path = File.tempname("test_patch_vip_gw_noip", ".json")

      begin
        gateway = ControllerFixtures.vip_gateway(
          name: "my-gateway",
          pod_selector_labels: {"app" => "gateway"}
        )
        pod = ControllerFixtures.pod(
          name: "no-ip-pod",
          namespace: "default",
          uid: "pod-uid-noip",
          labels: {"app" => "gateway", "netwrangler.dev/gateway" => "enabled"},
          pod_ip: nil,
          phase: "Running",
          node_name: "node-1"
        )

        json = ControllerFixtures.binding_context_json(
          vip_gateways: [gateway],
          pods: [pod]
        )
        File.write(binding_path, json)
        hook.run(binding_path, patch_path)

        content = File.read(patch_path)
        if content.strip.empty?
          true.should be_true
        else
          lines = content.strip.split("\n")
          operations = lines.map { |line| JSON.parse(line) }

          vip_route_ops = operations.select do |op|
            kind = op["object"]?.try(&.["kind"]?.try(&.as_s)) || op["kind"]?.try(&.as_s)
            kind == "VipRoute"
          end
          vip_route_ops.should be_empty
        end
      ensure
        File.delete(binding_path) if File.exists?(binding_path)
        File.delete(patch_path) if File.exists?(patch_path)
      end
    end

    it "deletes VipRoutes when Pods disappear" do
      hook = Netwrangler::Controller::ControllerHook.new
      binding_path = File.tempname("test_vip_gw_delete", ".json")
      patch_path = File.tempname("test_patch_vip_gw_delete", ".json")

      begin
        gateway = ControllerFixtures.vip_gateway(
          name: "my-gateway",
          pod_selector_labels: {"app" => "gateway"}
        )
        # No matching pods — existing VipRoute should be deleted
        existing_route = ControllerFixtures.vip_route(
          name: "gw-pod-1-my-gateway",
          namespace: "default",
          labels: {"netwrangler.dev/managed-by" => "netwrangler"}
        )

        json = ControllerFixtures.binding_context_json(
          vip_gateways: [gateway],
          vip_routes: [existing_route]
        )
        File.write(binding_path, json)
        hook.run(binding_path, patch_path)

        content = File.read(patch_path)
        lines = content.strip.split("\n")
        operations = lines.map { |line| JSON.parse(line) }

        delete_ops = operations.select { |op| op["operation"].as_s == "Delete" }
        delete_ops.any? { |op| op["name"].as_s == "gw-pod-1-my-gateway" }.should be_true
      ensure
        File.delete(binding_path) if File.exists?(binding_path)
        File.delete(patch_path) if File.exists?(patch_path)
      end
    end

    it "does not produce operations when existing VipRoutes match desired state" do
      hook = Netwrangler::Controller::ControllerHook.new
      binding_path = File.tempname("test_vip_gw_noop", ".json")
      patch_path = File.tempname("test_patch_vip_gw_noop", ".json")

      begin
        gateway = ControllerFixtures.vip_gateway(
          name: "my-gateway",
          route_table: 200,
          routing_priority: 200,
          pod_selector_labels: {"app" => "gateway"}
        )
        pod = ControllerFixtures.pod(
          name: "gw-pod-1",
          namespace: "default",
          uid: "pod-uid-1",
          labels: {"app" => "gateway", "netwrangler.dev/gateway" => "enabled"},
          pod_ip: "10.244.1.1",
          phase: "Running",
          node_name: "node-1"
        )
        # Existing VipRoute matches desired state exactly
        existing_route = ControllerFixtures.vip_route(
          name: "gw-pod-1-my-gateway",
          namespace: "default",
          destination_cidr: "10.0.0.0/8",
          pod_ip: "10.244.1.1",
          route_table: 200,
          routing_priority: 200,
          labels: {"netwrangler.dev/managed-by" => "netwrangler"}
        )

        json = ControllerFixtures.binding_context_json(
          vip_gateways: [gateway],
          pods: [pod],
          vip_routes: [existing_route]
        )
        File.write(binding_path, json)
        hook.run(binding_path, patch_path)

        content = File.read(patch_path)
        if content.strip.empty?
          true.should be_true
        else
          lines = content.strip.split("\n")
          operations = lines.map { |line| JSON.parse(line) }

          vip_route_ops = operations.select do |op|
            kind = op["object"]?.try(&.["kind"]?.try(&.as_s)) || op["kind"]?.try(&.as_s)
            kind == "VipRoute"
          end
          vip_route_ops.should be_empty
        end
      ensure
        File.delete(binding_path) if File.exists?(binding_path)
        File.delete(patch_path) if File.exists?(patch_path)
      end
    end

    it "uses pod name and gateway name for VipRoute naming" do
      hook = Netwrangler::Controller::ControllerHook.new
      binding_path = File.tempname("test_vip_gw_naming", ".json")
      patch_path = File.tempname("test_patch_vip_gw_naming", ".json")

      begin
        gateway = ControllerFixtures.vip_gateway(
          name: "my-gateway",
          pod_selector_labels: {"app" => "gateway"}
        )
        pod = ControllerFixtures.pod(
          name: "my-pod",
          namespace: "default",
          uid: "pod-uid-naming",
          labels: {"app" => "gateway", "netwrangler.dev/gateway" => "enabled"},
          pod_ip: "10.244.1.1",
          phase: "Running",
          node_name: "node-1"
        )

        json = ControllerFixtures.binding_context_json(
          vip_gateways: [gateway],
          pods: [pod]
        )
        File.write(binding_path, json)
        hook.run(binding_path, patch_path)

        content = File.read(patch_path)
        lines = content.strip.split("\n")
        operations = lines.map { |line| JSON.parse(line) }

        create_ops = operations.select { |op| op["operation"].as_s == "Create" }
        create_ops.size.should eq(1)
        create_ops.first["object"]["metadata"]["name"].as_s.should eq("my-pod-my-gateway")
      ensure
        File.delete(binding_path) if File.exists?(binding_path)
        File.delete(patch_path) if File.exists?(patch_path)
      end
    end

    it "creates VipRoutes in the Pod's namespace" do
      hook = Netwrangler::Controller::ControllerHook.new
      binding_path = File.tempname("test_vip_gw_ns", ".json")
      patch_path = File.tempname("test_patch_vip_gw_ns", ".json")

      begin
        gateway = ControllerFixtures.vip_gateway(
          name: "my-gateway",
          pod_selector_labels: {"app" => "gateway"}
        )
        pod = ControllerFixtures.pod(
          name: "gw-pod-1",
          namespace: "gateway-ns",
          uid: "pod-uid-ns",
          labels: {"app" => "gateway", "netwrangler.dev/gateway" => "enabled"},
          pod_ip: "10.244.1.1",
          phase: "Running",
          node_name: "node-1"
        )

        json = ControllerFixtures.binding_context_json(
          vip_gateways: [gateway],
          pods: [pod]
        )
        File.write(binding_path, json)
        hook.run(binding_path, patch_path)

        content = File.read(patch_path)
        lines = content.strip.split("\n")
        operations = lines.map { |line| JSON.parse(line) }

        create_ops = operations.select { |op| op["operation"].as_s == "Create" }
        create_ops.size.should eq(1)
        create_ops.first["object"]["metadata"]["namespace"].as_s.should eq("gateway-ns")
      ensure
        File.delete(binding_path) if File.exists?(binding_path)
        File.delete(patch_path) if File.exists?(patch_path)
      end
    end

    it "sets correct labels on created VipRoutes" do
      hook = Netwrangler::Controller::ControllerHook.new
      binding_path = File.tempname("test_vip_gw_labels", ".json")
      patch_path = File.tempname("test_patch_vip_gw_labels", ".json")

      begin
        gateway = ControllerFixtures.vip_gateway(
          name: "my-gateway",
          pod_selector_labels: {"app" => "gateway"}
        )
        pod = ControllerFixtures.pod(
          name: "gw-pod-1",
          namespace: "default",
          uid: "pod-uid-labels",
          labels: {"app" => "gateway", "netwrangler.dev/gateway" => "enabled"},
          pod_ip: "10.244.1.1",
          phase: "Running",
          node_name: "node-1"
        )

        json = ControllerFixtures.binding_context_json(
          vip_gateways: [gateway],
          pods: [pod]
        )
        File.write(binding_path, json)
        hook.run(binding_path, patch_path)

        content = File.read(patch_path)
        lines = content.strip.split("\n")
        operations = lines.map { |line| JSON.parse(line) }

        create_ops = operations.select { |op| op["operation"].as_s == "Create" }
        create_ops.size.should eq(1)

        labels = create_ops.first["object"]["metadata"]["labels"]
        labels["netwrangler.dev/managed-by"].as_s.should eq("netwrangler")
        labels["netwrangler.dev/gateway"].as_s.should eq("my-gateway")
      ensure
        File.delete(binding_path) if File.exists?(binding_path)
        File.delete(patch_path) if File.exists?(patch_path)
      end
    end
  end
end
