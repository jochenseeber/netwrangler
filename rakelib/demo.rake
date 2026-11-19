# frozen_string_literal: true

require_relative "kind_cluster/wireguard_mesh"
require_relative "demo/cleanup"
require_relative "demo/deployment"
require_relative "demo/example"
require_relative "demo/manifests"
require_relative "demo/suite"

# The examples run on the kind cluster, each proven with real traffic. Rake loads
# this file before the facets have run, so `PROJECT`, through `kind_shell`, is
# only read in task bodies.
namespace :demo do
  desc "Install netwrangler on the kind cluster, building its images only when a node lacks one"
  task install: %w[kind:node_tools kind:networks kind:wireguard] do
    Demo::Deployment.new(shell: kind_shell).ensure
  end

  desc "Apply the demo's VipConfig and VipNetworks (examples/cluster)"
  task cluster: :install do
    kind_shell.kubectl!("apply", "--filename", "-", input: Demo::Manifests.stream("examples/cluster"))
    puts "examples/cluster applied"
  end

  desc "Apply every example and check each with real traffic; goes on after a failed example"
  task deploy: :cluster do
    abort "demo failed" unless Demo::Suite.new(shell: kind_shell).run
  end

  namespace :deploy do
    Demo::EXAMPLES.each do |example|
      desc "Apply #{example.directory} and check it with real traffic"
      task example.name => "demo:cluster" do
        abort "demo #{example.name} failed" unless Demo::Suite.new(shell: kind_shell, examples: [example]).run
      end
    end
  end

  desc "Remove the examples and the demo's cluster objects; the networks and the WireGuard mesh stay"
  task :clean do
    Demo::Cleanup.new(shell: kind_shell, mesh: KindCluster::WireguardMesh.new(shell: kind_shell)).run
  end
end
