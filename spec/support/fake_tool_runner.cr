require "../../src/util/tool_runner"

# Answers each tool call from a table and records the calls. A call the table
# lacks exits 127, as a missing tool does.
class FakeToolRunner < Netwrangler::Util::ToolRunner
  getter calls = [] of {String, Array(String)}

  def initialize(@answers : Hash({String, Array(String)}, Netwrangler::Util::Result))
  end

  def run(path : String, args : Array(String)) : Netwrangler::Util::Result
    @calls << {path, args}

    @answers[{path, args}]? || Netwrangler::Util::Result.new(exit_code: 127, stdout: "", stderr: "unexpected call #{path} #{args.join(" ")}")
  end
end
