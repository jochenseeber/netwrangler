# frozen_string_literal: true

require_relative "example"
require_relative "report"
require_relative "traffic"

module Demo
  # Runs every example in turn, goes on after one that fails, and prints a
  # summary line per example at the end. A failure outside the checks, such as
  # a failed apply, prints as a ✗ line for the example, so `rake demo:deploy`
  # and `rake demo:deploy:<example>` fail alike.
  class Suite
    # @param shell [KindCluster::NodeShell]
    # @param examples [Array<Example>] in the order they run
    # @param output [IO] where the check and summary lines go
    def initialize(shell:, examples: EXAMPLES, output: $stdout)
      @shell = shell
      @examples = examples
      @output = output
    end

    # Run the examples and print the summary. A single example gets none: its
    # check lines say it all, and its ✗ line would show twice.
    #
    # @return [Boolean] whether every example passed
    def run
      outcomes = @examples.map { |example| [example.name, *outcome(example)] }
      summarize(outcomes) if outcomes.size > 1
      outcomes.all? { |_name, passed, _detail| passed }
    end

    private

    def summarize(outcomes)
      @output.puts
      @output.puts "Summary:"
      outcomes.each { |name, passed, detail| @output.puts "#{passed ? "✓" : "✗"} #{name}: #{detail}" }
    end

    # Whether the example passed, and how its checks went or why it failed, on
    # one line. Applying the example, waiting for its rollout or starting what
    # its checks need can fail before any check runs; that fails the example,
    # not the run.
    #
    # @return [Array(Boolean, String)]
    def outcome(example)
      report = example.run(shell: @shell, traffic: Traffic.new(shell: @shell), output: @output)
      [!report.failed?, report.summary]
    rescue StandardError => e
      reason = Report.one_line("#{e.class}: #{e.message}")
      @output.puts "✗ #{example.name}: #{reason}"
      [false, reason]
    end
  end
end
