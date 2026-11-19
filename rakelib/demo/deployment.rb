# frozen_string_literal: true

require "fileutils"
require "json"
require "rake"
require_relative "../kind_cluster/node_shell"

module Demo
  # Puts netwrangler on the kind cluster from the images already loaded into its
  # nodes. Unlike `kind:sync`, which always rebuilds and reloads both images, it
  # builds only when a node lacks one.
  class Deployment
    include FileUtils

    # @param shell [KindCluster::NodeShell]
    # @param kubernetes [Object] the kind facet's settings, `PROJECT[:kubernetes]`
    # @param output [IO] where progress goes
    def initialize(shell:, kubernetes: PROJECT[:kubernetes], output: $stdout)
      @shell = shell
      @kubernetes = kubernetes
      @output = output
    end

    # Load the images when a node lacks one, apply the CRDs, sync the helmfile's
    # kind environment and wait until every workload of the release has rolled out.
    def ensure
      missing = missing_images
      if missing.empty?
        @output.puts "netwrangler images present on every node"
      else
        @output.puts "missing on the nodes: #{missing.join(", ")}"
        Rake::Task["kind:upload"].invoke
      end
      Rake::Task["kind:kubeconfig"].invoke
      Rake::Task["kind:crds"].invoke
      sync
      self.class.wait_for_rollouts(@shell, @kubernetes.namespace,
                                   kinds: %w[deployment daemonset], timeout: @kubernetes.timeout)
    end

    # Wait for `kubectl rollout status` of every workload of +kinds+ in +namespace+.
    #
    # @param timeout [String] how long to wait for each, as kubectl takes it (`120s`)
    def self.wait_for_rollouts(shell, namespace, kinds:, timeout:)
      names = shell.kubectl!("get", kinds.join(","), "--namespace", namespace, "--output", "name").split
      names.each do |name|
        shell.kubectl!("rollout", "status", name, "--namespace", namespace, "--timeout", timeout)
      end
    end

    # A reference as the container runtime lists it: `jochen/netwrangler-agent:1.0.0`
    # is `docker.io/jochen/netwrangler-agent:1.0.0` there, and an image without a
    # repository is under `docker.io/library/`.
    def self.qualified_reference(reference)
      first, rest = reference.split("/", 2)
      return "docker.io/library/#{reference}" if rest.nil?
      return reference if first.include?(".") || first.include?(":") || first == "localhost"

      "docker.io/#{reference}"
    end

    private

    # The references of the project's images that at least one node lacks.
    def missing_images
      wanted = @kubernetes.components.map do |component|
        self.class.qualified_reference(Docker.reference_for(@kubernetes.project, component.name))
      end
      @shell.nodes.flat_map { |node| wanted - node_images(node) }.uniq
    end

    def node_images(node)
      JSON.parse(@shell.run!(node, "crictl images -o json")).fetch("images").flat_map { |image| image["repoTags"] || [] }
    end

    def sync
      helmfile = @kubernetes.helmfile or raise "the project has no helmfile"
      sh(@kubernetes.kube_env, "helmfile", "--environment=#{@kubernetes.environment}",
         "--kube-context=#{@kubernetes.kube_context}", "sync", chdir: File.dirname(helmfile))
    end
  end
end
