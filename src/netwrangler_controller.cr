require "json"
require "log"
require "option_parser"
require "socket"

require "./version"
require "./util/command"
require "./util/binding_context"
require "./controller/ip_allocator"
require "./controller/controller_hook"

module Netwrangler::Controller
  # Configure log level from LOG_LEVEL environment variable
  log_level = Log::Severity.parse?(ENV["LOG_LEVEL"]? || "info") || Log::Severity::Info
  Log.setup(log_level)

  # Parse DEBUG environment variable (accepts "1" or "true")
  debug = ENV["DEBUG"]?.try(&.matches?(/^(1|true)$/i)) || false

  # Parse NETWRANGLER_MANAGER_NAME environment variable (default: "netwrangler")
  manager_name = ENV["NETWRANGLER_MANAGER_NAME"]? || "netwrangler"
  print_config = false

  OptionParser.parse do |parser|
    parser.banner = "Usage: netwrangler-controller [options]"

    parser.on("--config", "Print shell-operator configuration and exit") do
      print_config = true
    end

    parser.on("--version", "Show version and exit") do
      puts "netwrangler-controller #{VERSION}"
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

  begin
    controller_hook = Controller::ControllerHook.new(manager_name: manager_name, debug: debug)

    if print_config
      controller_hook.print_config
      exit 0
    end

    binding_context_path = ENV["BINDING_CONTEXT_PATH"]? || abort("BINDING_CONTEXT_PATH environment variable is required")
    kubernetes_patch_path = ENV["KUBERNETES_PATCH_PATH"]? || abort("KUBERNETES_PATCH_PATH environment variable is required")

    controller_hook.run(binding_context_path: binding_context_path, kubernetes_patch_path: kubernetes_patch_path)
  rescue ex : Exception
    Log.for("netwrangler.controller").error(exception: ex) { "Hook failed: #{ex.message}" }
    exit 1
  end
end
