require "../spec_helper"
require "../../src/util/tool_runner"
require "../../src/agent/node_requirements"
require "../support/fake_tool_runner"

private alias Result = Netwrangler::Util::Result

private NO_DELAY = Netwrangler::Util::RetryPolicy.new(maximum_attempts: 3, delay: Time::Span.zero)

# Fails a number of calls with exit 126, then answers every call alike
private class FlakyRunner < Netwrangler::Util::ToolRunner
  getter calls = 0

  def initialize(*, @failures : Int32, @answer : Result)
  end

  def run(path : String, args : Array(String)) : Result
    @calls += 1
    return @answer if @calls > @failures

    Result.new(exit_code: 126, stdout: "", stderr: "nft: node-tool busy\n")
  end
end

private def ok(stdout : String = "") : Result
  Result.new(exit_code: 0, stdout: stdout, stderr: "")
end

private def failed(code : Int32, stderr : String) : Result
  Result.new(exit_code: code, stdout: "", stderr: stderr)
end

private def healthy : Hash({String, Array(String)}, Result)
  {
    {Netwrangler::Util::NFT, ["--version"]}                                  => ok("nftables v1.0.6 (Lester Gooch #5)\n"),
    {Netwrangler::Util::NFT, ["-j", "list", "chains"]}                       => ok(%({"nftables": []})),
    {Netwrangler::Util::IP, ["--json", "rule", "show"]}                      => ok("[]"),
    {Netwrangler::Util::ARPING, ["-V"]}                                      => ok("arping from iputils 20250605\n"),
    {Netwrangler::Util::IP, ["--json", "link", "show", "type", "wireguard"]} => ok("[]"),
  }
end

private def failures_for(answers : Hash({String, Array(String)}, Result)) : Array(Netwrangler::Agent::RequirementFailure)
  Netwrangler::Agent::NodeRequirements.new(FakeToolRunner.new(answers)).failures
end

describe Netwrangler::Agent::NodeRequirements do
  it "has no failures when every tool works" do
    runner = FakeToolRunner.new(healthy)

    Netwrangler::Agent::NodeRequirements.new(runner).failures.should be_empty
    runner.calls.map(&.[0]).should_not contain(Netwrangler::Util::WG)
  end

  it "runs only nft calls that read no rules and no maps" do
    runner = FakeToolRunner.new(healthy)

    Netwrangler::Agent::NodeRequirements.new(runner).failures

    nft_calls = runner.calls.select { |path, _| path == Netwrangler::Util::NFT }.map(&.[1])
    nft_calls.should eq([["--version"], ["-j", "list", "chains"]])
  end

  it "reports an nft older than the floor" do
    answers = healthy
    answers[{Netwrangler::Util::NFT, ["--version"]}] = ok("nftables v0.9.8 (E.D.S.)\n")

    failures = failures_for(answers)

    failures.map(&.tool).should eq(["nft"])
    failures.first.reason.should contain("1.0.6")
  end

  it "reports one failure for an nft whose version probe fails" do
    answers = healthy
    answers[{Netwrangler::Util::NFT, ["--version"]}] = failed(126, "nft: capset failed\n")
    answers[{Netwrangler::Util::NFT, ["-j", "list", "chains"]}] = failed(126, "nft: capset failed\n")
    runner = FakeToolRunner.new(answers)

    failures = Netwrangler::Agent::NodeRequirements.new(runner).failures

    failures.map(&.tool).should eq(["nft"])
    runner.calls.should_not contain({Netwrangler::Util::NFT, ["-j", "list", "chains"]})
  end

  it "reports a failing nft" do
    answers = healthy
    answers[{Netwrangler::Util::NFT, ["-j", "list", "chains"]}] = failed(126, "nft: capset failed\n")

    failures = failures_for(answers)

    failures.map(&.tool).should eq(["nft"])
    failures.first.reason.should contain("capset failed")
  end

  it "reports a failing ip rule listing" do
    answers = healthy
    answers[{Netwrangler::Util::IP, ["--json", "rule", "show"]}] = failed(126, "ip: mount the node's /proc at /hostfs/proc\n")

    failures = failures_for(answers)

    failures.map(&.tool).should eq(["ip"])
    failures.first.reason.should eq("mount the node's /proc at /hostfs/proc")
  end

  it "reports ip output that is no JSON array" do
    answers = healthy
    answers[{Netwrangler::Util::IP, ["--json", "rule", "show"]}] = ok("garbage")

    failures_for(answers).map(&.tool).should eq(["ip"])
  end

  it "reports a failing WireGuard link listing" do
    answers = healthy
    answers[{Netwrangler::Util::IP, ["--json", "link", "show", "type", "wireguard"]}] = failed(1, "ip: link listing failed\n")
    runner = FakeToolRunner.new(answers)

    failures = Netwrangler::Agent::NodeRequirements.new(runner).failures

    failures.map(&.tool).should eq(["ip"])
    failures.first.reason.should eq("link listing failed")
    runner.calls.map(&.[0]).should_not contain(Netwrangler::Util::WG)
  end

  it "reports a WireGuard link listing that is no JSON array" do
    answers = healthy
    answers[{Netwrangler::Util::IP, ["--json", "link", "show", "type", "wireguard"]}] = ok("garbage")

    failures_for(answers).map(&.tool).should eq(["ip"])
  end

  it "reports an arping that is not iputils" do
    answers = healthy
    answers[{Netwrangler::Util::ARPING, ["-V"]}] = ok("ARPing 2.21, by Thomas Habets\n")

    failures_for(answers).map(&.tool).should eq(["arping"])
  end

  it "requires wg on a node with a WireGuard link" do
    answers = healthy
    answers[{Netwrangler::Util::IP, ["--json", "link", "show", "type", "wireguard"]}] = ok(%([{"ifname":"wg0"}]))
    answers[{Netwrangler::Util::WG, ["--version"]}] = failed(127, "wg: the node has no wg\n")

    failures = failures_for(answers)

    failures.map(&.tool).should eq(["wg"])
    failures.first.reason.should contain("the node has no wg")
  end

  it "accepts wg on a node with a WireGuard link" do
    answers = healthy
    answers[{Netwrangler::Util::IP, ["--json", "link", "show", "type", "wireguard"]}] = ok(%([{"ifname":"wg0"}]))
    answers[{Netwrangler::Util::WG, ["--version"]}] = ok("wireguard-tools v1.0.20210914\n")

    failures_for(answers).should be_empty
  end

  it "reports every failure at once" do
    answers = healthy
    answers[{Netwrangler::Util::NFT, ["--version"]}] = failed(127, "nft: the node has no nft\n")
    answers[{Netwrangler::Util::ARPING, ["-V"]}] = ok("ARPing 2.21\n")

    failures_for(answers).map(&.tool).should eq(["nft", "arping"])
  end

  describe "#nft_version" do
    it "reads the node's nft release with one nft --version" do
      runner = FakeToolRunner.new(healthy)

      Netwrangler::Agent::NodeRequirements.new(runner).nft_version(NO_DELAY).should eq(Netwrangler::Util::NftVersion.new(major: 1, minor: 0, patch: 6))
      runner.calls.should eq([{Netwrangler::Util::NFT, ["--version"]}])
    end

    it "retries a failing nft as every tool call does" do
      runner = FlakyRunner.new(failures: 2, answer: ok("nftables v1.1.3 (Commodore Bullmoose #4)\n"))

      Netwrangler::Agent::NodeRequirements.new(runner).nft_version(NO_DELAY).should eq(Netwrangler::Util::NftVersion.new(major: 1, minor: 1, patch: 3))
      runner.calls.should eq(3)
    end

    it "raises with nft's message when nft fails on every attempt" do
      answers = healthy
      answers[{Netwrangler::Util::NFT, ["--version"]}] = failed(126, "nft: capset failed\n")
      runner = FakeToolRunner.new(answers)

      expect_raises(Exception, "Cannot read the node's nft version: capset failed") do
        Netwrangler::Agent::NodeRequirements.new(runner).nft_version(NO_DELAY)
      end
      runner.calls.size.should eq(3)
    end

    it "raises when nft prints no version" do
      answers = healthy
      answers[{Netwrangler::Util::NFT, ["--version"]}] = ok("nftables\n")

      expect_raises(Exception, %(Cannot read the node's nft version: cannot read the version from "nftables")) do
        Netwrangler::Agent::NodeRequirements.new(FakeToolRunner.new(answers)).nft_version(NO_DELAY)
      end
    end
  end
end
