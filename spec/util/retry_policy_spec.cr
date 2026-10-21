require "./spec_helper"

describe Netwrangler::Util::RetryPolicy do
  describe ".from_env" do
    it "attempts a command three times when the count is unset" do
      policy = Netwrangler::Util::RetryPolicy.from_env(count: nil, delay: nil)

      policy.maximum_attempts.should eq(3)
    end

    it "waits two seconds between attempts when the delay is unset" do
      policy = Netwrangler::Util::RetryPolicy.from_env(count: nil, delay: nil)

      policy.delay.should eq(2.seconds)
    end

    it "reads the attempt count from the environment" do
      policy = Netwrangler::Util::RetryPolicy.from_env(count: "5", delay: nil)

      policy.maximum_attempts.should eq(5)
    end

    it "reads a fractional delay from the environment as seconds" do
      policy = Netwrangler::Util::RetryPolicy.from_env(count: nil, delay: "0.5")

      policy.delay.should eq(500.milliseconds)
    end

    it "rejects an attempt count below one" do
      expect_raises(ArgumentError, /NETWRANGLER_RETRY_COUNT/) do
        Netwrangler::Util::RetryPolicy.from_env(count: "0", delay: nil)
      end
    end

    it "rejects an attempt count that is not a number" do
      expect_raises(ArgumentError, /NETWRANGLER_RETRY_COUNT/) do
        Netwrangler::Util::RetryPolicy.from_env(count: "often", delay: nil)
      end
    end

    it "rejects a negative delay" do
      expect_raises(ArgumentError, /NETWRANGLER_RETRY_DELAY/) do
        Netwrangler::Util::RetryPolicy.from_env(count: nil, delay: "-1")
      end
    end

    it "rejects a delay that is not a number" do
      expect_raises(ArgumentError, /NETWRANGLER_RETRY_DELAY/) do
        Netwrangler::Util::RetryPolicy.from_env(count: nil, delay: "soon")
      end
    end
  end
end
