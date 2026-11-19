# frozen_string_literal: true

require "open3"

# Helpers for the demo's tasks that talk to the nodes of the kind cluster.
module KindCluster
  # What a finished command printed and how it exited.
  CommandResult = Data.define(:stdout, :stderr, :exit_code) do
    # Whether the command exited with 0.
    def success? = exit_code.zero?
  end

  # Runs commands in the kind cluster's nodes, which are Docker containers, and
  # `kubectl` in its control plane, so nothing depends on the host's kubeconfig
  # or on Docker Desktop's port proxy to the API server.
  class NodeShell
    # @param cluster [String] the kind cluster's name
    def initialize(cluster:)
      @cluster = cluster
    end

    # All nodes of the cluster, which are also the names of their containers.
    def nodes
      @nodes ||= begin
        output, status = Open3.capture2("kind", "get", "nodes", "--name=#{@cluster}", err: File::NULL)
        raise "cannot list the nodes of kind cluster #{@cluster}" unless status.success?

        output.lines.map(&:strip).reject(&:empty?).sort
      end
    end

    # The nodes that run workloads.
    def workers = nodes - [control_plane]

    # The control plane node.
    def control_plane
      nodes.find { |node| node.end_with?("-control-plane") } or raise "kind cluster #{@cluster} has no control plane"
    end

    # Run a shell script on a node with `sh -c`.
    #
    # @return [CommandResult]
    def run(node, script) = execute("docker", "exec", node, "sh", "-c", script)

    # Like {#run}, but raises when the script fails.
    #
    # @return [String] what the script printed
    def run!(node, script)
      result = run(node, script)
      return result.stdout if result.success?

      raise "#{node}: `#{script}` failed with #{result.exit_code}: #{result.stderr.strip}"
    end

    # Run `docker` on the host.
    #
    # @return [CommandResult]
    def docker(*) = execute("docker", *)

    # Run `kubectl` in the control plane, feeding it +input+ when given.
    #
    # @return [CommandResult]
    def kubectl(*, input: nil)
      flags = input.nil? ? [] : ["--interactive"]
      execute("docker", "exec", *flags, control_plane, "kubectl", *, input: input)
    end

    # Like {#kubectl}, but raises when it fails.
    #
    # @return [String] what kubectl printed
    def kubectl!(*args, input: nil)
      result = kubectl(*args, input: input)
      return result.stdout if result.success?

      raise "kubectl #{args.join(" ")} failed with #{result.exit_code}: #{result.stderr.strip}"
    end

    private

    def execute(*command, input: nil)
      stdout, stderr, status = Open3.capture3(*command, stdin_data: input.to_s)
      CommandResult.new(stdout: stdout, stderr: stderr, exit_code: status.exitstatus || 128)
    end
  end
end
