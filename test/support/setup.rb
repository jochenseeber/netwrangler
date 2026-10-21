# frozen_string_literal: true

module IntegrationTest
  # Setup module for deploying the controller before tests
  module Setup
    extend KubectlHelper
    extend HelmfileHelper

    class << self
      # Deploy the controller (CRDs are included in the Helm chart)
      #
      # This method is called once before all tests run. It:
      # 1. Deploys the netwrangler-controller via helmfile (includes CRDs)
      # 2. Waits for the controller deployment to be ready
      def install_crds_and_deploy_controller
        log "Setting up integration test environment..."

        deploy_controller
        wait_for_crds

        log "Setup complete!"
      end

      private

      def deploy_controller
        log "Deploying controller via helmfile (includes CRDs)..."

        result = helmfile_apply
        raise "Failed to deploy controller: #{result.message}" unless result.success?

        log "  Waiting for controller deployment to be ready..."

        ready = wait_for_deployment_ready(
          "netwrangler-controller",
          namespace: IntegrationTest::CONTROLLER_NAMESPACE,
          timeout: 120
        )

        raise "Controller deployment not ready within timeout" unless ready

        log "  Controller deployed and ready."
      end

      def wait_for_crds
        log "Waiting for CRDs to be established..."

        wait_for_crd("vipnetworks.#{IntegrationTest::API_GROUP}", timeout: 30) ||
          raise("VipNetwork CRD not ready within timeout")

        wait_for_crd("vipaddresses.#{IntegrationTest::API_GROUP}", timeout: 30) ||
          raise("VipAddress CRD not ready within timeout")

        log "  CRDs ready."
      end

      def log(message)
        puts IntegrationTest::PASTEL.cyan("[Setup] #{message}")
      end
    end
  end
end
