require "./command"

module Netwrangler::Util
  # Runs one tool once and returns what it did, so code that probes the node
  # can be tested with a fake instead of the real tools
  abstract class ToolRunner
    abstract def run(path : String, args : Array(String)) : Result
  end

  # Runs the tool as a process. Unlike `Command` it never retries and never
  # raises on an exit code: the caller decides what a code means.
  class CommandToolRunner < ToolRunner
    # A missing executable becomes exit code 127, the shell's code for it,
    # which is also what the node-tool wrapper reports for a tool the node
    # lacks.
    def run(path : String, args : Array(String)) : Result
      stdout = IO::Memory.new
      stderr = IO::Memory.new

      status = Process.run(path, args, output: stdout, error: stderr)
      result = Result.from_status(status, stdout.to_s, stderr.to_s)

      result
    rescue error : File::Error | IO::Error
      result = Result.new(exit_code: 127, stdout: "", stderr: "#{path}: #{error.message}")

      result
    end
  end
end
