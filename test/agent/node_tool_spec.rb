# frozen_string_literal: true

require_relative "../spec_helper"

# The agent image has no network tools of its own: `ip`, `nft`, `wg` and
# `arping` are node-tool, which runs the node's tool of that name in the node's
# mount namespace, and only for the calls the agent makes.
RSpec.describe "Agent node-tool" do
  include IntegrationTest::KindHelper

  before(:all) do
    extend IntegrationTest::KubectlHelper
    extend IntegrationTest::KindHelper

    @nodes = node_names
    raise "No nodes found in cluster" if @nodes.empty?

    ready = wait_for_daemonset_ready(
      "netwrangler-agent",
      namespace: IntegrationTest::CONTROLLER_NAMESPACE,
      timeout: 120
    )
    raise "Agent DaemonSet not ready" unless ready
  end

  it "runs the node's ip" do
    @nodes.each do |node|
      expect_same_output(node, "ip -V")
    end
  end

  it "runs the node's nft" do
    @nodes.each do |node|
      expect_same_output(node, "nft --version")
    end
  end

  it "refuses calls outside the allowlist" do
    @nodes.each do |node|
      result = agent_exec(node, "ip netns list")

      expect(result).not_to be_success, "The agent on #{node} ran ip netns list: #{result.message}"
      expect(result.message).to include("ip:")
      expect(result.message).to include("exit code 126")
    end
  end

  # The Crystal runtime sets O_NONBLOCK on piped standard descriptors, and the
  # flag belongs to the pipe, not the process: left on, a tool writing more
  # than the pipe holds while the agent reads gets EAGAIN and loses output.
  # `grep` runs after `ip`, writing to the same pipe, so it sees the flags
  # node-tool left there; before node-tool cleared them they read 04001.
  it "leaves the tool's standard output blocking" do
    @nodes.each do |node|
      result = agent_script(node, "{ ip -V 2>&1; grep flags /proc/self/fdinfo/1; } | cat")
      expect(result).to be_success, "The pipeline failed in the agent on #{node}: #{result.message}"

      flags = result.message[%r{^flags:\s+([0-7]+)$}, 1]
      expect(flags).not_to be_nil, "No descriptor flags in the output on #{node}: #{result.message}"
      # O_NONBLOCK, in the octal notation of fdinfo
      expect(flags.to_i(8) & 0o4000).to eq(0), "ip left O_NONBLOCK (#{flags}) on its stdout on #{node}"
    end
  end

  it "passes the startup check" do
    @nodes.each do |node|
      pod = agent_pod_name(node)
      expect(pod).not_to be_empty, "No agent pod on #{node}"

      ready = kubectl_output("get pod #{pod} --namespace=#{IntegrationTest::CONTROLLER_NAMESPACE} " \
                             "--output=jsonpath='{.status.containerStatuses[0].ready}'").delete("'")
      expect(ready).to eq("true"), "The agent pod #{pod} on #{node} is not ready"

      # The log is the current container's only: a start that failed the check
      # and a restart that passed it show up as a restart
      restarts = kubectl_output("get pod #{pod} --namespace=#{IntegrationTest::CONTROLLER_NAMESPACE} " \
                                "--output=jsonpath='{.status.containerStatuses[0].restartCount}'").delete("'")
      expect(restarts).to eq("0"), "The agent pod #{pod} on #{node} restarted #{restarts} times"

      log = kubectl_output("logs #{pod} --namespace=#{IntegrationTest::CONTROLLER_NAMESPACE}")
      stops = log.lines.grep(%r{stopping the container})
      expect(stops).to be_empty, "The agent on #{node} logged #{stops.join}"
    end
  end

  def expect_same_output(node, command)
    agent = agent_exec(node, command)
    expect(agent).to be_success, "#{command} failed in the agent on #{node}: #{agent.message}"

    host = kind_exec(node, command)
    expect(host).to be_success, "#{command} failed on #{node}: #{host.message}"

    expect(agent.message).to eq(host.message)
  end
end
