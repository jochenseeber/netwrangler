require "./spec_helper"

describe Netwrangler::PrivilegedRunner::Refusal do
  describe ".open_failure" do
    it "hints at security modules on permission denied" do
      message = Netwrangler::PrivilegedRunner::Refusal.open_failure(Errno::EACCES).message.to_s

      message.should start_with("opening /hostfs/proc/1/ns/mnt failed: Permission denied")
      message.should end_with("(AppArmor or SELinux may deny ptrace of the node's init)")
    end

    it "has no hint for other errors" do
      message = Netwrangler::PrivilegedRunner::Refusal.open_failure(Errno::ENOENT).message.to_s

      message.should_not contain("AppArmor")
    end
  end

  describe ".failure" do
    it "reports the call and the error as Rust's io::Error prints it" do
      Netwrangler::PrivilegedRunner::Refusal.failure("capset", Errno::EPERM).message
        .should eq("capset failed: Operation not permitted (os error 1)")
    end
  end

  describe ".not_allowed" do
    it "names the argument" do
      Netwrangler::PrivilegedRunner::Refusal.not_allowed("netns").message.should eq("argument not allowed: netns")
    end
  end
end
