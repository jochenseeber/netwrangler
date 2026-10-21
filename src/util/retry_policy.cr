module Netwrangler::Util
  # How often an external tool invocation is retried before it is treated as a
  # failure, and how long to wait between those attempts.
  record RetryPolicy,
    maximum_attempts : Int32,
    delay : Time::Span do
    DEFAULT_MAXIMUM_ATTEMPTS = 3
    DEFAULT_DELAY            = 2.seconds

    COUNT_ENVIRONMENT_VARIABLE = "NETWRANGLER_RETRY_COUNT"
    DELAY_ENVIRONMENT_VARIABLE = "NETWRANGLER_RETRY_DELAY"

    # Builds a policy from the raw environment values, each nil when the
    # variable is unset. Parsing lives here rather than at the entry point so
    # the conversion from string to typed value happens once, at the boundary.
    def self.from_env(*, count : String?, delay : String?) : RetryPolicy
      policy = RetryPolicy.new(
        maximum_attempts: parse_maximum_attempts(count),
        delay: parse_delay(delay)
      )

      policy
    end

    private def self.parse_maximum_attempts(count : String?) : Int32
      return DEFAULT_MAXIMUM_ATTEMPTS if count.nil?

      maximum_attempts = count.to_i?

      if maximum_attempts.nil?
        raise ArgumentError.new("#{COUNT_ENVIRONMENT_VARIABLE} must be a whole number, got #{count.inspect}")
      end

      if maximum_attempts < 1
        raise ArgumentError.new("#{COUNT_ENVIRONMENT_VARIABLE} must be at least 1, got #{maximum_attempts}")
      end

      maximum_attempts
    end

    private def self.parse_delay(delay : String?) : Time::Span
      return DEFAULT_DELAY if delay.nil?

      seconds = delay.to_f?

      if seconds.nil?
        raise ArgumentError.new("#{DELAY_ENVIRONMENT_VARIABLE} must be a number of seconds, got #{delay.inspect}")
      end

      if seconds < 0
        raise ArgumentError.new("#{DELAY_ENVIRONMENT_VARIABLE} must not be negative, got #{seconds}")
      end

      wait = seconds.seconds

      wait
    end
  end
end
