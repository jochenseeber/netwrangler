require "./spec_helper"

describe Netwrangler::Util::ContainerTerminator do
  describe "#terminate" do
    it "signals the supervising process to stop" do
      supervisor = Process.new("sleep", ["30"])
      terminator = Netwrangler::Util::ContainerTerminator.new(process_id: supervisor.pid)

      terminator.terminate
      status = supervisor.wait

      status.exit_signal?.should eq(Signal::TERM)
    end

    it "targets the init process by default, which owns the container lifetime" do
      terminator = Netwrangler::Util::ContainerTerminator.new

      terminator.process_id.should eq(1)
    end
  end
end
