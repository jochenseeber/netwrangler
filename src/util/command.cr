require "log"

require "./nft_builds"
require "./retry_policy"

module Netwrangler::Util
  # Absolute paths to external tool binaries
  IP     = "/usr/local/sbin/ip"
  WG     = "/usr/local/sbin/wg"
  ARPING = "/usr/local/sbin/arping"

  # The bundled nft build that NETWRANGLER_NFT_VERSION selects, the latest by
  # default. Resolved when a command first runs nft rather than at startup: a
  # missing build then fails that hook, where the agent's error handling
  # reports it.
  class_getter(nft : String) do
    path = NftBuilds.discover(NftBuilds::DIRECTORY).path(requested: ENV[NftBuilds::VERSION_ENVIRONMENT_VARIABLE]?)
    Command::Log.info { "Running nft as #{path}" }

    path.to_s
  end

  # Result of a command execution
  record Result,
    exit_code : Int32,
    stdout : String,
    stderr : String do
    def success? : Bool
      exit_code == 0
    end
  end

  # Exception raised when a command fails
  class CommandError < Exception
    getter result : Result

    def initialize(command : Command, @result : Result)
      super("Command failed: #{command}: #{result.stderr.strip}")
    end

    def message! : String
      message || raise NilAssertionError.new("CommandError#message is nil")
    end
  end

  # Utility class for executing shell commands
  class Command
    Log = ::Log.for("netwrangler.command")

    # The policy every command uses unless the caller supplies its own, read
    # from the process environment the first time a command is built.
    DEFAULT_RETRY_POLICY = RetryPolicy.from_env(
      count: ENV[RetryPolicy::COUNT_ENVIRONMENT_VARIABLE]?,
      delay: ENV[RetryPolicy::DELAY_ENVIRONMENT_VARIABLE]?
    )

    getter cmd : String
    getter args : Array(String)
    getter allowed_exit_codes : Array(Int32)
    getter retry_policy : RetryPolicy

    def initialize(
      @cmd : String,
      *,
      @args : Array(String) = [] of String,
      @allowed_exit_codes : Array(Int32) = [0],
      @retry_policy : RetryPolicy = DEFAULT_RETRY_POLICY,
    )
    end

    # Runs the command, retrying while it exits with a code the caller did not
    # allow. An allowed exit code is a normal outcome, never a retry: callers
    # use it to tolerate codes a tool reports for expected conditions.
    def run : Result
      attempt = 1

      loop do
        result = execute

        return result if @allowed_exit_codes.includes?(result.exit_code)

        error = CommandError.new(self, result)
        raise error if attempt >= @retry_policy.maximum_attempts

        Log.warn { "#{error.message} (attempt #{attempt} of #{@retry_policy.maximum_attempts}, retrying)" }

        sleep(@retry_policy.delay)
        attempt += 1
      end
    end

    private def execute : Result
      stdout = IO::Memory.new
      stderr = IO::Memory.new

      status = Process.run(@cmd, @args,
        output: stdout,
        error: stderr)

      result = Result.new(
        exit_code: status.exit_code,
        stdout: stdout.to_s,
        stderr: stderr.to_s
      )

      result
    end

    def to_s(io : IO) : Nil
      io << @cmd << " " << @args.join(" ")
    end
  end
end
