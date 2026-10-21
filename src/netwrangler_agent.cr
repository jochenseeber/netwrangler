require "json"
require "log"
require "option_parser"
require "socket"

require "./version"
require "./util/command"
require "./util/container_terminator"
require "./util/binding_context"
require "./util/kernel_version"
require "./agent/address_updater"
require "./agent/nft_types"
require "./agent/nftables_updater"
require "./agent/routes_updater"
require "./agent/wireguard_updater"
require "./agent/agent_hook"

module Netwrangler::Agent
  # The oldest kernel the bundled nft builds support: from 1.1.2 on, nft
  # performs bitwise operations on two registers, which Linux 6.13 added
  MINIMUM_KERNEL = Util::KernelVersion.new(major: 6, minor: 13)

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

  node_name = ENV["NODE_NAME"]? || abort("NODE_NAME environment variable is required")
  monitor = AgentHook.new(node_name: node_name, debug: debug)

  if print_config
    monitor.print_config
    exit 0
  end

  binding_context_path = ENV["BINDING_CONTEXT_PATH"]? || abort("BINDING_CONTEXT_PATH environment variable is required")

  begin
    AgentHook.with_attempts(RECONCILE_ATTEMPTS) { monitor.run(binding_context_path) }
  rescue ex
    LOG.error(exception: ex) { "Hook failed, stopping the container: #{ex.message}" }
    stop_container
  end
end
