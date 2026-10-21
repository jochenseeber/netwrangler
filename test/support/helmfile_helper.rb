# frozen_string_literal: true

module IntegrationTest
  # Helper methods for helmfile commands
  module HelmfileHelper
    # Execute a helmfile command and return a TestResult
    #
    # @param args [String] arguments to pass to helmfile
    # @param environment [String] helmfile environment (default: minikube)
    # @return [TestResult] result containing success status and output message
    def helmfile(args, environment: "kind")
      stdout, stderr, status = Open3.capture3(
        IntegrationTest::KUBE_ENV,
        "helmfile --environment=#{environment} --kube-context=#{IntegrationTest::KUBE_CONTEXT} #{args}",
        chdir: IntegrationTest::DEPLOY_DIR
      )

      TestResult.new(
        success: status.success?,
        message: status.success? ? stdout.strip : stderr.strip
      )
    end

    # Apply helmfile configuration (sync)
    #
    # @param environment [String] helmfile environment (default: minikube)
    # @return [TestResult] result of the sync operation
    def helmfile_apply(environment: "kind")
      helmfile("sync", environment: environment)
    end

    # Destroy helmfile releases
    #
    # @param environment [String] helmfile environment (default: minikube)
    # @return [TestResult] result of the destroy operation
    def helmfile_destroy(environment: "kind")
      helmfile("destroy --skip-deps", environment: environment)
    end
  end
end
