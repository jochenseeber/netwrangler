require "json"
require "log"
require "option_parser"
require "socket"

require "./version"
require "./util/command"
require "./util/container_terminator"
require "./util/binding_context"
require "./util/kernel_version"
require "./util/tool_runner"
require "./agent/address_updater"
require "./agent/nft_types"
require "./agent/node_requirements"
require "./agent/nftables_updater"
require "./agent/routes_updater"
require "./agent/wireguard_updater"
require "./agent/agent_hook"

module Netwrangler::Agent
  # The oldest kernel with every nftables feature the agent uses: the
  # specific mark maps have concatenated interval keys, which need the
  # pipapo set type of Linux 5.6
  MINIMUM_KERNEL = Util::KernelVersion.new(major: 5, minor: 6)

  LOG = ::Log.for("netwrangler.agent")

  # Passes of a reconciliation before a failure stops the container: the
  # second repairs what changed under the first
  RECONCILE_ATTEMPTS = 2

  # A hook exiting only ends this child process, so the container keeps
  # running with its state half-applied. Signalling the supervisor stops the
  # container instead, letting the kubelet restart the pod and surface the
  # failure as a restart.
  def self.stop_container : NoReturn
    begin
      Util::ContainerTerminator.new.terminate
    rescue error
      LOG.error(exception: error) { "Could not stop the container: #{error.message}" }
    end

    exit 1
  end

  # Runs before every hook, --config included, so an unsupported node stops
  # the container at startup rather than failing on its first rule
  def self.check_kernel : Nil
    kernel = Util::KernelVersion.running
    return if kernel >= MINIMUM_KERNEL

    LOG.error { "Linux #{kernel} is not supported: the agent needs Linux #{MINIMUM_KERNEL} or newer, stopping the container" }
    stop_container
  rescue ex : File::Error | ArgumentError
    LOG.error { "Cannot determine the kernel version, stopping the container: #{ex.message}" }
    stop_container
  end

  # Runs on --config only, which shell-operator runs once at startup, so a node
  # whose tools do not work stops the container there with every reason
  # logged, instead of failing hook after hook
  def self.check_node_tools : Nil
    failures = NodeRequirements.new(Util::CommandToolRunner.new).failures
    return if failures.empty?

    failures.each { |failure| LOG.error { "#{failure.tool}: #{failure.reason}" } }
    LOG.error { "The agent cannot run its tools on this node, stopping the container" }
    stop_container
  end

  # The node's nft release, read once per hook run; a node whose nft cannot
  # say stops the container, as the run cannot choose how to declare its
  # sets and maps
  def self.node_nft_version : Util::NftVersion
    NodeRequirements.new(Util::CommandToolRunner.new).nft_version
  rescue ex
    LOG.error { "#{ex.message}, stopping the container" }
    stop_container
  end

  # Parse DEBUG environment variable (accepts "1" or "true")
  debug = ENV["DEBUG"]?.try(&.matches?(/^(1|true)$/i)) || false
  print_config = false

  OptionParser.parse do |parser|
    parser.banner = "Usage: netwrangler-agent [options]"

    parser.on("--config", "Print shell-operator configuration and exit") do
      print_config = true
    end

    parser.on("--version", "Show version and exit") do
      puts "netwrangler-agent #{VERSION}"
      exit 0
    end

    parser.on("--help", "Show this help message") do
      puts parser
      exit 0
    end

    parser.invalid_option do |flag|
      STDERR.puts "ERROR: Unknown option: #{flag}"
      STDERR.puts parser
      exit 1
    end
  end

  check_kernel
  check_node_tools if print_config

  node_name = ENV["NODE_NAME"]? || abort("NODE_NAME environment variable is required")

  if print_config
    AgentHook.print_config(node_name)
    exit 0
  end

  monitor = AgentHook.new(node_name: node_name, nft_version: node_nft_version, debug: debug)

  binding_context_path = ENV["BINDING_CONTEXT_PATH"]? || abort("BINDING_CONTEXT_PATH environment variable is required")

  begin
    AgentHook.with_attempts(RECONCILE_ATTEMPTS) { monitor.run(binding_context_path) }
  rescue ex
    LOG.error(exception: ex) { "Hook failed, stopping the container: #{ex.message}" }
    stop_container
  end
end
