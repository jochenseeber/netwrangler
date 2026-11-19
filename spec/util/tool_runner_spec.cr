require "./spec_helper"
require "../../src/util/tool_runner"

describe Netwrangler::Util::CommandToolRunner do
  it "turns a missing executable into exit code 127" do
    result = Netwrangler::Util::CommandToolRunner.new.run("/nonexistent/tool", [] of String)

    result.exit_code.should eq(127)
    result.stderr.should_not be_empty
  end

  it "returns a failing exit code as a result" do
    result = Netwrangler::Util::CommandToolRunner.new.run("sh", ["-c", "echo out; echo err >&2; exit 3"])

    result.exit_code.should eq(3)
    result.stdout.should eq("out\n")
    result.stderr.should eq("err\n")
  end

  it "maps a process killed by a signal to 128 plus the signal" do
    result = Netwrangler::Util::CommandToolRunner.new.run("sh", ["-c", "kill -SEGV $$"])

    result.exit_code.should eq(139)
    result.stderr.should contain("SIGSEGV")
  end
end
