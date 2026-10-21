require "../spec_helper"

# Keeps tests that assert on a failing command from paying the default policy's
# retries, which would otherwise add seconds of waiting per example.
SINGLE_ATTEMPT = Netwrangler::Util::RetryPolicy.new(maximum_attempts: 1, delay: Time::Span.zero)

# Builds a command that counts its own invocations by appending a line per
# attempt, so assertions can check how many times it actually ran.
private def counting_command(
  *,
  marker : String,
  script : String,
  policy : Netwrangler::Util::RetryPolicy,
  allowed_exit_codes : Array(Int32) = [0],
) : Netwrangler::Util::Command
  Netwrangler::Util::Command.new("sh",
    args: ["-c", "echo attempt >> #{marker}; #{script}"],
    allowed_exit_codes: allowed_exit_codes,
    retry_policy: policy)
end

private def attempt_count(marker : String) : Int32
  count = File.exists?(marker) ? File.read_lines(marker).size : 0

  count
end

describe Netwrangler::Util::Result do
  describe "#success?" do
    it "returns true when exit_code is 0" do
      result = Netwrangler::Util::Result.new(exit_code: 0, stdout: "", stderr: "")
      result.success?.should be_true
    end

    it "returns false when exit_code is non-zero" do
      result = Netwrangler::Util::Result.new(exit_code: 1, stdout: "", stderr: "")
      result.success?.should be_false
    end

    it "returns false when exit_code is negative" do
      result = Netwrangler::Util::Result.new(exit_code: -1, stdout: "", stderr: "")
      result.success?.should be_false
    end
  end

  describe "properties" do
    it "stores exit_code, stdout, and stderr" do
      result = Netwrangler::Util::Result.new(
        exit_code: 42,
        stdout: "output",
        stderr: "error"
      )
      result.exit_code.should eq(42)
      result.stdout.should eq("output")
      result.stderr.should eq("error")
    end
  end
end

describe Netwrangler::Util::CommandError do
  it "includes command and stderr in message" do
    command = Netwrangler::Util::Command.new("test-cmd", args: ["arg1", "arg2"])
    result = Netwrangler::Util::Result.new(exit_code: 1, stdout: "", stderr: "some error\n")
    error = Netwrangler::Util::CommandError.new(command, result)

    error.message!.should contain("test-cmd arg1 arg2")
    error.message!.should contain("some error")
  end

  it "exposes the result" do
    command = Netwrangler::Util::Command.new("cmd", args: [] of String)
    result = Netwrangler::Util::Result.new(exit_code: 127, stdout: "out", stderr: "err")
    error = Netwrangler::Util::CommandError.new(command, result)

    error.result.should eq(result)
    error.result.exit_code.should eq(127)
  end
end

describe Netwrangler::Util::Command do
  describe "#initialize" do
    it "sets cmd and args" do
      command = Netwrangler::Util::Command.new("echo", args: ["hello", "world"])
      command.cmd.should eq("echo")
      command.args.should eq(["hello", "world"])
    end

    it "defaults args to empty array" do
      command = Netwrangler::Util::Command.new("pwd")
      command.args.should eq([] of String)
    end

    it "defaults allowed_exit_codes to [0]" do
      command = Netwrangler::Util::Command.new("test")
      command.allowed_exit_codes.should eq([0])
    end

    it "accepts custom allowed_exit_codes" do
      command = Netwrangler::Util::Command.new("test", allowed_exit_codes: [0, 1, 2])
      command.allowed_exit_codes.should eq([0, 1, 2])
    end
  end

  describe "#run" do
    it "executes a simple command and captures stdout" do
      command = Netwrangler::Util::Command.new("echo", args: ["hello"])
      result = command.run

      result.exit_code.should eq(0)
      result.stdout.strip.should eq("hello")
      result.stderr.should eq("")
    end

    it "captures stderr" do
      command = Netwrangler::Util::Command.new("sh", args: ["-c", "echo error >&2"])
      result = command.run

      result.exit_code.should eq(0)
      result.stderr.strip.should eq("error")
    end

    it "returns correct exit code" do
      command = Netwrangler::Util::Command.new("sh", args: ["-c", "exit 42"], allowed_exit_codes: [42])
      result = command.run

      result.exit_code.should eq(42)
    end

    it "raises CommandError when exit code is not allowed" do
      command = Netwrangler::Util::Command.new("sh", args: ["-c", "exit 1"], retry_policy: SINGLE_ATTEMPT)

      expect_raises(Netwrangler::Util::CommandError) do
        command.run
      end
    end

    it "does not raise when exit code is in allowed list" do
      command = Netwrangler::Util::Command.new("sh", args: ["-c", "exit 1"], allowed_exit_codes: [0, 1])
      result = command.run

      result.exit_code.should eq(1)
    end

    it "handles multiple allowed exit codes" do
      [0, 1, 2].each do |code|
        command = Netwrangler::Util::Command.new("sh", args: ["-c", "exit #{code}"], allowed_exit_codes: [0, 1, 2])
        result = command.run
        result.exit_code.should eq(code)
      end
    end

    it "raises CommandError with correct result for failed command" do
      command = Netwrangler::Util::Command.new("sh", args: ["-c", "echo fail >&2; exit 5"], retry_policy: SINGLE_ATTEMPT)

      begin
        command.run
        fail "Expected CommandError to be raised"
      rescue ex : Netwrangler::Util::CommandError
        ex.result.exit_code.should eq(5)
        ex.result.stderr.strip.should eq("fail")
      end
    end
  end

  describe "#run with retries" do
    it "retries a failing command until it succeeds" do
      marker = File.tempname("netwrangler-retry", ".attempts")
      policy = Netwrangler::Util::RetryPolicy.new(maximum_attempts: 3, delay: Time::Span.zero)
      command = counting_command(marker: marker,
        script: "test $(wc -l < #{marker}) -ge 2",
        policy: policy)

      result = command.run

      result.success?.should be_true
      attempt_count(marker).should eq(2)
    ensure
      File.delete?(marker) if marker
    end

    it "stops after the configured number of attempts and raises" do
      marker = File.tempname("netwrangler-retry", ".attempts")
      policy = Netwrangler::Util::RetryPolicy.new(maximum_attempts: 3, delay: Time::Span.zero)
      command = counting_command(marker: marker, script: "exit 7", policy: policy)

      expect_raises(Netwrangler::Util::CommandError) do
        command.run
      end

      attempt_count(marker).should eq(3)
    ensure
      File.delete?(marker) if marker
    end

    it "does not retry an exit code the caller allows" do
      marker = File.tempname("netwrangler-retry", ".attempts")
      policy = Netwrangler::Util::RetryPolicy.new(maximum_attempts: 3, delay: Time::Span.zero)
      command = counting_command(marker: marker,
        script: "exit 1",
        policy: policy,
        allowed_exit_codes: [0, 1])

      result = command.run

      result.exit_code.should eq(1)
      attempt_count(marker).should eq(1)
    ensure
      File.delete?(marker) if marker
    end

    it "runs a command exactly once when the policy allows a single attempt" do
      marker = File.tempname("netwrangler-retry", ".attempts")
      policy = Netwrangler::Util::RetryPolicy.new(maximum_attempts: 1, delay: Time::Span.zero)
      command = counting_command(marker: marker, script: "exit 7", policy: policy)

      expect_raises(Netwrangler::Util::CommandError) do
        command.run
      end

      attempt_count(marker).should eq(1)
    ensure
      File.delete?(marker) if marker
    end

    it "waits the configured delay between attempts" do
      marker = File.tempname("netwrangler-retry", ".attempts")
      policy = Netwrangler::Util::RetryPolicy.new(maximum_attempts: 3, delay: 50.milliseconds)
      command = counting_command(marker: marker, script: "exit 7", policy: policy)
      started = Time.instant

      expect_raises(Netwrangler::Util::CommandError) do
        command.run
      end

      # Three attempts means two waits, so at least 100ms must have elapsed.
      started.elapsed.should be >= 100.milliseconds
    ensure
      File.delete?(marker) if marker
    end
  end

  describe "#to_s" do
    it "returns command with arguments" do
      command = Netwrangler::Util::Command.new("nft", args: ["add", "element", "ip", "table", "set"])
      command.to_s.should eq("nft add element ip table set")
    end

    it "returns just command when no arguments" do
      command = Netwrangler::Util::Command.new("pwd")
      command.to_s.should eq("pwd ")
    end
  end
end
