require "spec"

require "../../src/privileged_runner/address_syntax"
require "../../src/privileged_runner/arguments"
require "../../src/privileged_runner/json_check"
require "../../src/privileged_runner/refusal"
require "../../src/privileged_runner/tools"

# Helpers of the node-tool specs, in a module so that the specs of several
# components compile together without their helpers colliding
module PrivilegedRunnerSpecs
  # A call as the agent passes it, split at spaces; none of the arguments the
  # specs split this way contains one
  def self.call(line : String) : Array(String)
    arguments = line.split

    arguments
  end

  # The refusal message for +arguments+, or nil when the check accepts them
  def self.refusal_of(arguments : Array(String), & : Array(String) -> Nil) : String?
    yield arguments
    nil
  rescue error : Netwrangler::PrivilegedRunner::Refusal
    error.message
  end

  # Expects the check to accept every line; a failure names the line and why it
  # was refused
  def self.accepts_all(lines : Enumerable(String), &check : Array(String) -> Nil) : Nil
    lines.each do |line|
      {line, refusal_of(call(line), &check)}.should eq({line, nil})
    end
  end

  # Expects the check to refuse every line; a failure names the line
  def self.refuses_all(lines : Enumerable(String), &check : Array(String) -> Nil) : Nil
    lines.each do |line|
      {line, refusal_of(call(line), &check).nil?}.should eq({line, false})
    end
  end
end
