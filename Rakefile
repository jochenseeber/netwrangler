# frozen_string_literal: true

require_relative "rakelib/project"
require_relative "rakelib/marked_versions"
require_relative "rakelib/kind_cluster/demo_networks"
require_relative "rakelib/kind_cluster/node_shell"
require_relative "rakelib/kind_cluster/wireguard_mesh"

# The commands in the nodes of the project's kind cluster, for the kind and demo
# tasks. `PROJECT` is only complete once the facets have run, so this is only
# called in task bodies.
#
# @return [KindCluster::NodeShell]
def kind_shell = @kind_shell ||= KindCluster::NodeShell.new(cluster: PROJECT[:kubernetes].cluster)

# Everything this project builds, tests, packages and deploys is defined by the
# facets in `rakelib/facets/`, each discovering what it acts on and configured by
# its own section of `.project.yaml`. All that is left here is what belongs to
# this project alone.

# The Markdown files mark where they name the latest release, so `rake release`
# writes the released version there and stages them with the manifests.
marked_versions = MarkedVersions.new
marked_versions.files.each { |file| PROJECT.add_version_file(file) }
PROJECT.add_version_writer { |version| marked_versions.write(version) }

# The integration tests run against the kind cluster, so every image has to be
# rebuilt and rolled out first — not just the one under test, since the agent and
# controller are tested as a pair, which is exactly what `kind:restart` does.
# The demo's objects go first: the tests bring their own VipConfig and
# VipNetworks, which the demo's would conflict with.
# Registered here and run once every facet has contributed, so it does not depend
# on the components being known while this file loads. Only a component with an
# image has a workload on kind: `node-tool` ships inside the agent image and is
# tested through the agent, so it gets no `node-tool:test` that restarts kind.
PROJECT.define do
  PROJECT.components.each_value do |component|
    next if component[:crystal].nil? || component[:crystal].virtual || component[:docker].nil?

    task "#{component.name}:test" => %w[demo:clean kind:restart]
  end

  # The agent runs the node's own `wg` and `arping`, and its startup check stops
  # the container on a node without iputils `arping`. The kind node image ships
  # neither, so they go in before the agents restart: first among the
  # prerequisites, or the agents would start, fail the check and back off.
  namespace :kind do
    desc "Install the node tools the agent runs (wireguard-tools, iputils-arping) in the kind nodes"
    task :node_tools do
      kind_shell.nodes.each do |node|
        next if kind_shell.run(node, "command -v wg && command -v arping").success?

        sh "docker", "exec", "--env=DEBIAN_FRONTEND=noninteractive", node, "sh", "-c",
           "apt-get update -qq && apt-get install --yes --quiet --no-install-recommends " \
           "wireguard-tools iputils-arping"
      end
    end

    desc "Attach the demo's public and private Docker networks to every kind node as eth1 and eth2"
    task :networks do
      KindCluster::DemoNetworks.new(shell: kind_shell).ensure
    end

    desc "Build the standing WireGuard mesh (wg-demo) between the kind nodes"
    task wireguard: "kind:node_tools" do
      KindCluster::WireguardMesh.new(shell: kind_shell).ensure
    end
  end

  Rake::Task["kind:restart"].prerequisites.unshift("kind:node_tools", "kind:networks", "kind:wireguard")
end
