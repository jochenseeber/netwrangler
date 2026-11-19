# frozen_string_literal: true

module Demo
  # The outcome of an example's checks, printed one line per check as each one
  # completes: `✓ <description>` or `✗ <description>: <reason>`.
  class Report
    # @param output [IO] where the lines go
    def initialize(output: $stdout)
      @output = output
      @count = 0
      @failures = 0
    end

    # Run one check. The block returns true when the check passed, or a String
    # that says why it failed. An exception fails the check with its message.
    #
    # @param description [String] what the check proves
    # @return [Boolean] whether the check passed
    def check(description)
      outcome = begin
        yield
      rescue StandardError => e
        "#{e.class}: #{e.message}"
      end
      passed = outcome == true
      @count += 1
      @failures += 1 unless passed
      @output.puts(passed ? "✓ #{description}" : "✗ #{description}: #{reason(outcome)}")
      @output.flush
      passed
    end

    # Whether any check failed.
    def failed? = @failures.positive?

    # How the checks went, such as `2 of 3 checks failed`.
    def summary = failed? ? "#{@failures} of #{@count} checks failed" : "#{@count} checks passed"

    # +text+ on one line: a multi-line message, such as kubectl's stderr in an
    # exception, has its non-empty lines joined.
    def self.one_line(text)
      lines = text.lines.map(&:strip).reject(&:empty?)
      lines.empty? ? "failed" : lines.join(" / ")
    end

    private

    def reason(outcome)
      return "the check returned #{outcome.inspect}" unless outcome.is_a?(String)

      self.class.one_line(outcome)
    end
  end
end
