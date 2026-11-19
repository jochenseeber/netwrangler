require "./spec_helper"

private alias Capability = Netwrangler::PrivilegedRunner::Capability

private NEEDED = [Capability::SysAdmin, Capability::SysChroot, Capability::SysPtrace, Capability::NetAdmin]

private def permitted(capabilities : Enumerable(Capability)) : UInt64
  set = capabilities.reduce(0_u64) { |bits, capability| bits | capability.mask }

  set
end

private def permitted_refusal(permitted : UInt64, needed : Enumerable(Capability)) : String?
  refusal = PrivilegedRunnerSpecs.refusal_of([] of String) { Netwrangler::PrivilegedRunner.check_permitted(permitted, needed) }

  refusal
end

describe Netwrangler::PrivilegedRunner::Tool do
  describe ".find?" do
    it "dispatches on the name" do
      %w[nft ip wg arping].each do |name|
        Netwrangler::PrivilegedRunner::Tool.find?(name).try(&.name).should eq(name)
      end
      Netwrangler::PrivilegedRunner::Tool.find?("sh").should be_nil
      Netwrangler::PrivilegedRunner::Tool.find?("Ip").should be_nil
      Netwrangler::PrivilegedRunner::Tool.find?("").should be_nil
    end
  end

  describe "#capabilities" do
    it "gives tools only their own capabilities" do
      Netwrangler::PrivilegedRunner::Tool::Ip.capabilities.should eq([Capability::NetAdmin])
      Netwrangler::PrivilegedRunner::Tool::Wg.capabilities.should eq([Capability::NetAdmin])
      Netwrangler::PrivilegedRunner::Tool::Nft.capabilities.should eq([Capability::NetAdmin])
      Netwrangler::PrivilegedRunner::Tool::Arping.capabilities.should eq([Capability::NetRaw])
    end
  end

  describe "#check" do
    it "checks the arguments against the tool's own allowlist" do
      PrivilegedRunnerSpecs.refusal_of(["netns", "list"]) { |arguments| Netwrangler::PrivilegedRunner::Tool::Ip.check(arguments) }
        .should eq("argument not allowed: netns")
      PrivilegedRunnerSpecs.refusal_of(["-V"]) { |arguments| Netwrangler::PrivilegedRunner::Tool::Nft.check(arguments) }
        .should_not be_nil
      PrivilegedRunnerSpecs.refusal_of(["--version"]) { |arguments| Netwrangler::PrivilegedRunner::Tool::Wg.check(arguments) }
        .should be_nil
    end
  end
end

describe "Netwrangler::PrivilegedRunner.check_permitted" do
  it "accepts every needed capability" do
    permitted_refusal(permitted(NEEDED), NEEDED).should be_nil
  end

  it "names the first missing capability" do
    permitted_refusal(permitted([Capability::NetAdmin, Capability::NetRaw]), NEEDED).should eq(
      "cap_sys_admin is not permitted: add it to the container's capabilities " \
      "and do not set allowPrivilegeEscalation: false"
    )
    permitted_refusal(
      permitted(Netwrangler::PrivilegedRunner::ENTRY_CAPABILITIES),
      [Capability::SysAdmin, Capability::NetRaw]
    ).should eq(
      "cap_net_raw is not permitted: add it to the container's capabilities " \
      "and do not set allowPrivilegeEscalation: false"
    )
  end
end

describe Netwrangler::PrivilegedRunner::Capability do
  describe "#to_s" do
    it "names capabilities in lower case" do
      names = [
        Capability::NetAdmin,
        Capability::NetRaw,
        Capability::SysChroot,
        Capability::SysPtrace,
        Capability::SysAdmin,
      ].map(&.to_s)

      names.should eq(%w[cap_net_admin cap_net_raw cap_sys_chroot cap_sys_ptrace cap_sys_admin])
    end

    it "numbers a capability it has no name for" do
      Capability.new(5_u32).to_s.should eq("capability 5")
    end
  end

  describe "#mask" do
    it "is the capability's bit in a 64-bit set" do
      Capability::NetAdmin.mask.should eq(1_u64 << 12)
      Capability::SysAdmin.mask.should eq(1_u64 << 21)
    end
  end
end
