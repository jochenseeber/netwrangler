require "json"

require "../util/command"
require "../util/nft_version"
require "../util/tool_runner"
require "./nft_types"

module Netwrangler::Agent
  # A tool of the node that does not do what the agent needs
  record RequirementFailure, tool : String, reason : String

  # Probes the node's tools through the node-tool wrapper and reports every
  # one that is missing, refused or too old, so a node that cannot run the
  # agent says why at startup instead of failing on its first rule
  class NodeRequirements
    def initialize(@runner : Util::ToolRunner)
    end

    # Every failing check, in the order nft, ip, arping, wg
    def failures : Array(RequirementFailure)
      found = [] of RequirementFailure
      [check_nft, check_ip_rules, check_arping, check_wg].each do |failure|
        found << failure if failure
      end

      found
    end

    # The node's nft release, read with `nft --version`, retried under
    # +retry_policy+ as every tool call of a hook run is. A hook run needs it
    # to choose how to declare the sets and maps
    # (`NftObjectDescriptor.typeof?`), so it raises when nft fails on every
    # attempt or prints no version.
    def nft_version(retry_policy : Util::RetryPolicy = Util::Command::DEFAULT_RETRY_POLICY) : Util::NftVersion
      result = Util::Command.new(Util::NFT, args: ["--version"], retry_policy: retry_policy, runner: @runner).run
      version = Util::NftVersion.parse?(result.stdout)
      return version if version

      raise Exception.new(%(Cannot read the node's nft version: cannot read the version from "#{result.stdout.strip}"))
    rescue error : Util::CommandError
      raise Exception.new("Cannot read the node's nft version: #{failure("nft", error.result, "nft --version failed").reason}", cause: error)
    end

    private def check_nft_version : RequirementFailure?
      result = @runner.run(Util::NFT, ["--version"])
      return failure("nft", result, "nft --version failed") unless result.success?

      version = Util::NftVersion.parse?(result.stdout)
      return failure("nft", result, "cannot read the version from \"#{result.stdout.strip}\"") if version.nil?
      return if version >= MINIMUM_NFT

      RequirementFailure.new("nft", "nftables #{version} is too old, the agent needs #{MINIMUM_NFT} or newer")
    end

    # One failure per tool: an nft whose version probe fails is not listed
    private def check_nft : RequirementFailure?
      version_failure = check_nft_version
      return version_failure if version_failure

      check_nft_chains
    end

    # Chains list without their rules and without any map, so neither the
    # previous agent's table, whose rules nft 1.0.9 aborts on, nor another
    # tool's maps, on which nft 1.0.6 crashes, fail the check before the
    # first run can rebuild the table
    private def check_nft_chains : RequirementFailure?
      result = @runner.run(Util::NFT, ["-j", "list", "chains"])
      return if result.success?

      failure("nft", result, "nft -j list chains failed")
    end

    private def check_ip_rules : RequirementFailure?
      result = @runner.run(Util::IP, ["--json", "rule", "show"])
      return failure("ip", result, "ip --json rule show failed") unless result.success?
      return if json_array?(result.stdout)

      RequirementFailure.new("ip", "ip --json rule show printed no JSON array, the agent needs an iproute2 with JSON output")
    end

    private def check_arping : RequirementFailure?
      result = @runner.run(Util::ARPING, ["-V"])
      return failure("arping", result, "arping -V failed") unless result.success?
      return if result.stdout.includes?("iputils")

      RequirementFailure.new("arping", "arping is not the one from iputils: \"#{result.stdout.strip}\"")
    end

    # wg only matters on a node that has a WireGuard link. A listing that
    # fails or is no JSON array is an ip failure, never "no WireGuard", or the
    # wg check would be skipped silently.
    private def check_wg : RequirementFailure?
      links = @runner.run(Util::IP, ["--json", "link", "show", "type", "wireguard"])
      return failure("ip", links, "ip --json link show type wireguard failed") unless links.success?

      names = json_array(links.stdout)
      return RequirementFailure.new("ip", "ip --json link show type wireguard printed no JSON array") if names.nil?
      return if names.empty?

      result = @runner.run(Util::WG, ["--version"])
      return if result.success?

      failure("wg", result, "wg --version failed, the node has WireGuard links")
    end

    private def json_array?(text : String) : Bool
      !json_array(text).nil?
    end

    private def json_array(text : String) : Array(JSON::Any)?
      JSON.parse(text).as_a?
    rescue JSON::ParseException
      nil
    end

    # The tool's own message, or the expectation when it said nothing
    private def failure(tool : String, result : Util::Result, expected : String) : RequirementFailure
      message = result.stderr.strip.lchop("#{tool}: ")
      reason = message.empty? ? "#{expected} (exit code #{result.exit_code})" : message

      RequirementFailure.new(tool, reason)
    end
  end
end
