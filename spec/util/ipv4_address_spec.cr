require "./spec_helper"

describe Netwrangler::Util::IPv4Address do
  describe ".parse" do
    it "parses a valid IPv4 address" do
      addr = Netwrangler::Util::IPv4Address.parse("10.0.1.1")
      addr.value.should eq(0x0A000101_u32)
    end

    it "parses 0.0.0.0" do
      addr = Netwrangler::Util::IPv4Address.parse("0.0.0.0")
      addr.value.should eq(0_u32)
    end

    it "parses 255.255.255.255" do
      addr = Netwrangler::Util::IPv4Address.parse("255.255.255.255")
      addr.value.should eq(0xFFFFFFFF_u32)
    end

    it "accepts leading zeros in octets" do
      addr = Netwrangler::Util::IPv4Address.parse("010.000.001.001")
      addr.value.should eq(0x0A000101_u32)
    end

    it "rejects too few octets" do
      expect_raises(ArgumentError, /expected 4 octets/) do
        Netwrangler::Util::IPv4Address.parse("10.0.1")
      end
    end

    it "rejects too many octets" do
      expect_raises(ArgumentError, /expected 4 octets/) do
        Netwrangler::Util::IPv4Address.parse("10.0.1.1.1")
      end
    end

    it "rejects octet exceeding 255" do
      expect_raises(ArgumentError, /exceeds 255/) do
        Netwrangler::Util::IPv4Address.parse("10.0.1.256")
      end
    end

    it "rejects empty string" do
      expect_raises(ArgumentError, /expected 4 octets/) do
        Netwrangler::Util::IPv4Address.parse("")
      end
    end

    it "rejects non-numeric octets" do
      expect_raises(ArgumentError, /non-numeric/) do
        Netwrangler::Util::IPv4Address.parse("10.0.1.abc")
      end
    end

    it "rejects empty octet" do
      expect_raises(ArgumentError, /empty octet/) do
        Netwrangler::Util::IPv4Address.parse("10.0..1")
      end
    end
  end

  describe "#to_s" do
    it "roundtrips through parse and to_s" do
      Netwrangler::Util::IPv4Address.parse("10.0.1.1").to_s.should eq("10.0.1.1")
    end

    it "roundtrips 0.0.0.0" do
      Netwrangler::Util::IPv4Address.parse("0.0.0.0").to_s.should eq("0.0.0.0")
    end

    it "roundtrips 255.255.255.255" do
      Netwrangler::Util::IPv4Address.parse("255.255.255.255").to_s.should eq("255.255.255.255")
    end

    it "normalizes leading zeros" do
      Netwrangler::Util::IPv4Address.parse("010.000.001.001").to_s.should eq("10.0.1.1")
    end
  end

  describe "#<=>" do
    it "compares equal addresses" do
      a = Netwrangler::Util::IPv4Address.parse("10.0.1.1")
      b = Netwrangler::Util::IPv4Address.parse("10.0.1.1")
      (a <=> b).should eq(0)
    end

    it "orders lower address before higher" do
      a = Netwrangler::Util::IPv4Address.parse("10.0.1.1")
      b = Netwrangler::Util::IPv4Address.parse("10.0.1.2")
      (a < b).should be_true
    end

    it "orders higher address after lower" do
      a = Netwrangler::Util::IPv4Address.parse("192.168.1.1")
      b = Netwrangler::Util::IPv4Address.parse("10.0.1.1")
      (a > b).should be_true
    end
  end

  describe "ranges" do
    it "can be used in a range" do
      first = Netwrangler::Util::IPv4Address.parse("10.0.0.1")
      last = Netwrangler::Util::IPv4Address.parse("10.0.0.5")
      mid = Netwrangler::Util::IPv4Address.parse("10.0.0.3")
      outside = Netwrangler::Util::IPv4Address.parse("10.0.0.10")

      range = first..last
      range.includes?(mid).should be_true
      range.includes?(outside).should be_false
    end
  end
end
