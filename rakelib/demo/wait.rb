# frozen_string_literal: true

module Demo
  # Polling for a condition that the cluster reaches on its own time.
  module Wait
    # Call the block every +interval+ seconds until it returns a truthy value or
    # +timeout+ seconds have passed. The block runs at least once, and once more
    # at the deadline.
    #
    # @return [Boolean] whether the block returned a truthy value in time
    def self.until(timeout:, interval: 3)
      deadline = now + timeout
      loop do
        return true if yield

        remaining = deadline - now
        return false if remaining <= 0

        sleep([interval, remaining].min)
      end
    end

    def self.now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    private_class_method :now
  end
end
