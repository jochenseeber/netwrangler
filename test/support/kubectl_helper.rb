# frozen_string_literal: true

module IntegrationTest
  # Helper methods for kubectl commands
  module KubectlHelper
    # Execute a kubectl command and return a TestResult
    #
    # Runs kubectl inside the kind control-plane container via docker exec
    # to avoid Docker Desktop port proxy issues on macOS.
    #
    # @param args [String] arguments to pass to kubectl
    # @return [TestResult] result containing success status and output message
    def kubectl(args)
      stdout, stderr, status = Open3.capture3(
        "docker", "exec", IntegrationTest::CONTROL_PLANE_CONTAINER,
        "kubectl", *args.split
      )

      TestResult.new(
        success: status.success?,
        message: status.success? ? stdout.strip : stderr.strip
      )
    end

    # Execute a kubectl command and return only the stdout
    #
    # @param args [String] arguments to pass to kubectl
    # @return [String] stdout output stripped of whitespace
    def kubectl_output(args)
      stdout, = Open3.capture3(
        "docker", "exec", IntegrationTest::CONTROL_PLANE_CONTAINER,
        "kubectl", *args.split
      )
      stdout.strip
    end

    # Apply a YAML manifest via kubectl
    #
    # @param yaml_content [String] YAML content to apply
    # @return [TestResult] result containing success status and output message
    def kubectl_apply(yaml_content)
      stdout, stderr, status = Open3.capture3(
        "docker", "exec", "--interactive", IntegrationTest::CONTROL_PLANE_CONTAINER,
        "kubectl", "apply", "--filename=-",
        stdin_data: yaml_content
      )

      TestResult.new(
        success: status.success?,
        message: status.success? ? stdout.strip : stderr.strip
      )
    end

    # Check if a command exists in the system PATH
    #
    # @param command [String] command name to check
    # @return [Boolean] true if command exists
    def command_exists?(command)
      system("which #{command} > /dev/null 2>&1")
    end

    # Create a namespace
    #
    # @param name [String] namespace name
    # @return [TestResult] result of the create operation
    def create_namespace(name)
      kubectl("create namespace #{name}")
    end

    # Delete a namespace
    #
    # @param name [String] namespace name
    # @return [TestResult] result of the delete operation
    def delete_namespace(name)
      kubectl("delete namespace #{name} --ignore-not-found")
    end

    # Get all node names in the cluster
    #
    # @return [Array<String>] list of node names
    def get_node_names
      output = kubectl_output("get nodes --output=jsonpath='{.items[*].metadata.name}'")
      output.gsub("'", "").split
    end

    # Wait for a pod to be ready
    #
    # @param name [String] pod name
    # @param namespace [String] namespace of the pod
    # @param timeout [Integer] maximum seconds to wait (default: 60)
    # @return [Boolean] true if pod is ready
    def wait_for_pod_ready(name, namespace:, timeout: 60)
      timeout.times do
        result = kubectl(
          "get pod #{name} " \
          "--namespace=#{namespace} " \
          "--output=jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}'"
        )

        return true if result.success? && result.message.gsub("'", "") == "True"

        sleep 3
      end

      false
    end

    # Wait for a pod to be running (scheduled and started, but not necessarily ready)
    #
    # @param name [String] pod name
    # @param namespace [String] namespace of the pod
    # @param timeout [Integer] maximum seconds to wait (default: 60)
    # @return [Boolean] true if pod is running
    def wait_for_pod_running(name, namespace:, timeout: 60)
      timeout.times do
        result = kubectl(
          "get pod #{name} " \
          "--namespace=#{namespace} " \
          "--output=jsonpath='{.status.phase}'"
        )

        return true if result.success? && result.message.gsub("'", "") == "Running"

        sleep 3
      end

      false
    end

    # Get the node name where a pod is scheduled
    #
    # @param name [String] pod name
    # @param namespace [String] namespace of the pod
    # @return [String, nil] node name or nil if not found
    def get_pod_node(name, namespace:)
      output = kubectl_output(
        "get pod #{name} " \
        "--namespace=#{namespace} " \
        "--output=jsonpath='{.spec.nodeName}'"
      )
      result = output.gsub("'", "")
      result.empty? ? nil : result
    end

    # Delete a pod
    #
    # @param name [String] pod name
    # @param namespace [String] namespace of the pod
    # @return [TestResult] result of the delete operation
    def delete_pod(name, namespace:)
      kubectl("delete pod #{name} --namespace=#{namespace} --ignore-not-found")
    end

    # Mark a pod as not ready by adding a failing readiness probe
    # This is done by patching the pod to update its readiness gate
    #
    # @param name [String] pod name
    # @param namespace [String] namespace of the pod
    # @return [TestResult] result of the patch operation
    def mark_pod_not_ready(name, namespace:)
      # Delete and recreate with ready: false would be complex
      # Instead, we'll delete the pod - caller should create with ready: false
      delete_pod(name, namespace: namespace)
    end

    # Wait for a CRD to become ready
    #
    # @param crd_name [String] name of the CRD to wait for
    # @param timeout [Integer] maximum seconds to wait (default: 30)
    # @return [Boolean] true if CRD is ready
    def wait_for_crd(crd_name, timeout: 30)
      timeout.times do
        result = kubectl("get crd #{crd_name}")
        return true if result.success?

        sleep 3
      end

      false
    end

    # Wait for a deployment to have ready replicas
    #
    # @param name [String] deployment name
    # @param namespace [String] namespace of the deployment
    # @param replicas [Integer] expected number of ready replicas (default: 1)
    # @param timeout [Integer] maximum seconds to wait (default: 60)
    # @return [Boolean] true if deployment is ready
    def wait_for_deployment_ready(name, namespace:, replicas: 1, timeout: 60)
      timeout.times do
        result = kubectl(
          "get deployment #{name} " \
          "--namespace=#{namespace} " \
          "--output=jsonpath='{.status.readyReplicas}'"
        )

        return true if result.success? && result.message.gsub("'", "") == replicas.to_s

        sleep 3
      end

      false
    end

    # Wait for VipAddress resources to appear
    #
    # @param namespace [String] namespace to check
    # @param count [Integer] minimum number of resources expected
    # @param timeout [Integer] maximum seconds to wait (default: 30)
    # @return [Array, nil] array of VipAddress items or nil if timeout
    def wait_for_vip_addresses(namespace:, count:, timeout: 30)
      timeout.times do
        output = kubectl_output(
          "get vipaddresses.#{IntegrationTest::API_GROUP} " \
          "--namespace=#{namespace} --output=json"
        )

        begin
          data = JSON.parse(output)
          items = data["items"] || []
          return items if items.length >= count
        rescue JSON::ParserError
          # Continue waiting
        end

        sleep 3
      end

      nil
    end

    # Wait for VipAddress resources to be cleaned up
    #
    # @param namespace [String] namespace to check
    # @param timeout [Integer] maximum seconds to wait (default: 30)
    # @return [Boolean] true if all resources are cleaned up
    def wait_for_vip_addresses_cleanup(namespace:, timeout: 30)
      timeout.times do
        output = kubectl_output(
          "get vipaddresses.#{IntegrationTest::API_GROUP} " \
          "--namespace=#{namespace} --output=json"
        )

        begin
          data = JSON.parse(output)
          items = data["items"] || []
          return true if items.empty?
        rescue JSON::ParserError
          # Continue waiting
        end

        sleep 3
      end

      false
    end

    # Verify a resource exists
    #
    # @param resource_type [String] type of resource
    # @param name [String] name of resource
    # @param namespace [String, nil] namespace (nil for cluster-scoped resources)
    # @return [Boolean] true if resource exists
    def resource_exists?(resource_type, name, namespace: nil)
      cmd = if namespace
        "get #{resource_type} #{name} --namespace=#{namespace}"
      else
        "get #{resource_type} #{name}"
      end

      kubectl(cmd).success?
    end

    # Scale a deployment to a specific number of replicas
    #
    # @param name [String] deployment name
    # @param namespace [String] namespace of the deployment
    # @param replicas [Integer] target number of replicas
    # @return [TestResult] result of the scale operation
    def scale_deployment(name, namespace:, replicas:)
      kubectl("scale deployment #{name} --namespace=#{namespace} --replicas=#{replicas}")
    end

    # Get the number of ready endpoints for a service
    #
    # @param service_name [String] service name
    # @param namespace [String] namespace of the service
    # @return [Integer] number of ready endpoints
    def get_ready_endpoint_count(service_name, namespace:)
      output = kubectl_output(
        "get endpointslices --namespace=#{namespace} " \
        "--selector=kubernetes.io/service-name=#{service_name} --output=json"
      )

      begin
        data = JSON.parse(output)
        items = data["items"] || []
        items.sum do |slice|
          endpoints = slice["endpoints"] || []
          endpoints.count { |ep| ep.dig("conditions", "ready") == true }
        end
      rescue JSON::ParserError
        0
      end
    end

    # Wait for a specific number of ready endpoints
    #
    # @param service_name [String] service name
    # @param namespace [String] namespace of the service
    # @param count [Integer] expected number of ready endpoints
    # @param timeout [Integer] maximum seconds to wait (default: 60)
    # @return [Boolean] true if endpoint count reached
    def ready_endpoints_reached?(service_name, namespace:, count:, timeout: 60)
      timeout.times do
        current_count = get_ready_endpoint_count(service_name, namespace: namespace)
        return true if current_count == count

        sleep 3
      end

      false
    end

    # Wait for VipAddress resources to reach an exact count
    #
    # @param namespace [String] namespace to check
    # @param count [Integer] exact number of resources expected
    # @param timeout [Integer] maximum seconds to wait (default: 30)
    # @return [Array, nil] array of VipAddress items or nil if timeout
    def wait_for_vip_address_count(namespace:, count:, timeout: 30)
      timeout.times do
        output = kubectl_output(
          "get vipaddresses.#{IntegrationTest::API_GROUP} " \
          "--namespace=#{namespace} --output=json"
        )

        begin
          data = JSON.parse(output)
          items = data["items"] || []
          return items if items.length == count
        rescue JSON::ParserError
          # Continue waiting
        end

        sleep 3
      end

      nil
    end

    # Get current VipAddress resources
    #
    # @param namespace [String] namespace to check
    # @return [Array] array of VipAddress items
    def get_vip_addresses(namespace:)
      output = kubectl_output(
        "get vipaddresses.#{IntegrationTest::API_GROUP} " \
        "--namespace=#{namespace} --output=json"
      )

      begin
        data = JSON.parse(output)
        data["items"] || []
      rescue JSON::ParserError
        []
      end
    end

    # Get service conditions
    #
    # @param name [String] service name
    # @param namespace [String] namespace
    # @return [Array, nil] array of condition hashes, or nil if not found
    def get_service_conditions(name, namespace:)
      output = kubectl_output(
        "get service #{name} --namespace=#{namespace} --output=json"
      )

      begin
        data = JSON.parse(output)
        data.dig("status", "conditions")
      rescue JSON::ParserError
        nil
      end
    end

    # Wait for a service condition to appear
    #
    # @param name [String] service name
    # @param namespace [String] namespace
    # @param type [String] condition type to wait for
    # @param timeout [Integer] timeout in seconds
    # @return [Hash, nil] the condition hash, or nil if timed out
    def wait_for_service_condition(name, namespace:, type:, timeout: 30)
      deadline = Time.now + timeout

      while Time.now < deadline
        conditions = get_service_conditions(name, namespace: namespace)
        if conditions
          condition = conditions.find { |c| c["type"] == type }
          return condition if condition
        end
        sleep 2
      end

      nil
    end

    # Wait for VipRoute resources to appear
    #
    # @param namespace [String] namespace to check
    # @param count [Integer] minimum number of resources expected
    # @param timeout [Integer] maximum seconds to wait (default: 30)
    # @return [Array, nil] array of VipRoute items or nil if timeout
    def wait_for_vip_routes(namespace:, count:, timeout: 30)
      timeout.times do
        output = kubectl_output(
          "get viproutes.#{IntegrationTest::API_GROUP} " \
          "--namespace=#{namespace} --output=json"
        )

        begin
          data = JSON.parse(output)
          items = data["items"] || []
          return items if items.length >= count
        rescue JSON::ParserError
          # Continue waiting
        end

        sleep 3
      end

      nil
    end

    # Wait for VipRoute resources to be cleaned up
    #
    # @param namespace [String] namespace to check
    # @param timeout [Integer] maximum seconds to wait (default: 30)
    # @return [Boolean] true if all resources are cleaned up
    def wait_for_vip_routes_cleanup(namespace:, timeout: 30)
      timeout.times do
        output = kubectl_output(
          "get viproutes.#{IntegrationTest::API_GROUP} " \
          "--namespace=#{namespace} --output=json"
        )

        begin
          data = JSON.parse(output)
          items = data["items"] || []
          return true if items.empty?
        rescue JSON::ParserError
          # Continue waiting
        end

        sleep 3
      end

      false
    end

    # Get current VipRoute resources
    #
    # @param namespace [String] namespace to check
    # @return [Array] array of VipRoute items
    def get_vip_routes(namespace:)
      output = kubectl_output(
        "get viproutes.#{IntegrationTest::API_GROUP} " \
        "--namespace=#{namespace} --output=json"
      )

      begin
        data = JSON.parse(output)
        data["items"] || []
      rescue JSON::ParserError
        []
      end
    end

    # Delete a resource
    #
    # @param resource_type [String] type of resource
    # @param name [String] name of resource
    # @param namespace [String, nil] namespace (nil for cluster-scoped resources)
    # @return [TestResult] result of the delete operation
    def kubectl_delete(resource_type, name, namespace: nil)
      cmd = if namespace
        "delete #{resource_type} #{name} --namespace=#{namespace}"
      else
        "delete #{resource_type} #{name}"
      end

      kubectl(cmd)
    end
  end
end
