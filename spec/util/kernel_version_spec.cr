require "./spec_helper"

private def kernel(major : Int32, minor : Int32) : Netwrangler::Util::KernelVersion
  Netwrangler::Util::KernelVersion.new(major: major, minor: minor)
end

describe Netwrangler::Util::KernelVersion do
  describe ".parse?" do
    it "reads the major and minor number of a distribution release" do
      Netwrangler::Util::KernelVersion.parse?("7.0.0-29-generic").should eq(kernel(7, 0))
      Netwrangler::Util::KernelVersion.parse?("6.1.0-37-amd64").should eq(kernel(6, 1))
      Netwrangler::Util::KernelVersion.parse?("6.13.2-linuxkit\n").should eq(kernel(6, 13))
    end

    it "reads a release without a patch level" do
      Netwrangler::Util::KernelVersion.parse?("6.13").should eq(kernel(6, 13))
    end

    it "rejects text that does not start with a version" do
      Netwrangler::Util::KernelVersion.parse?("").should be_nil
      Netwrangler::Util::KernelVersion.parse?("7").should be_nil
      Netwrangler::Util::KernelVersion.parse?("linux-7.0").should be_nil
    end
  end

  describe ".running" do
    it "reads the release from a file" do
      path = Path.new(File.tempname("osrelease"))
      File.write(path, "6.12.48+deb13-amd64\n")

      begin
        Netwrangler::Util::KernelVersion.running(path).should eq(kernel(6, 12))
      ensure
        File.delete(path)
      end
    end

    it "reports a release it cannot parse" do
      path = Path.new(File.tempname("osrelease"))
      File.write(path, "unknown\n")

      begin
        expect_raises(ArgumentError, %(Cannot parse the kernel release "unknown")) do
          Netwrangler::Util::KernelVersion.running(path)
        end
      ensure
        File.delete(path)
      end
    end
  end

  describe "#<=>" do
    it "compares the minor number numerically" do
      (kernel(6, 9) < kernel(6, 13)).should be_true
      (kernel(6, 13) < kernel(7, 0)).should be_true
      (kernel(6, 13) >= kernel(6, 13)).should be_true
      (kernel(6, 12) >= kernel(6, 13)).should be_false
    end
  end

  describe "#to_s" do
    it "prints major and minor number" do
      kernel(6, 13).to_s.should eq("6.13")
    end
  end
end
