require "./spec_helper"

describe Netwrangler::Util::IPv4Network do
  describe ".parse" do
    it "parses a valid network" do
      net = Netwrangler::Util::IPv4Network.parse("10.0.1.0/24")
      net.address.should eq(Netwrangler::Util::IPv4Address.parse("10.0.1.0"))
      net.prefix.should eq(24)
    end

    it "rejects prefix below 0" do
      expect_raises(ArgumentError, /must be 0-32/) do
        Netwrangler::Util::IPv4Network.parse("10.0.0.0/-1")
      end
    end

    it "rejects missing prefix" do
      expect_raises(ArgumentError, /expected format/) do
        Netwrangler::Util::IPv4Network.parse("10.0.0.0")
      end
    end

    it "rejects prefix above 32" do
      expect_raises(ArgumentError, /must be 0-32/) do
        Netwrangler::Util::IPv4Network.parse("10.0.0.0/33")
      end
    end

    it "accepts prefix 0" do
      net = Netwrangler::Util::IPv4Network.parse("0.0.0.0/0")
      net.prefix.should eq(0)
    end

    it "accepts prefix 32" do
      net = Netwrangler::Util::IPv4Network.parse("10.0.1.1/32")
      net.prefix.should eq(32)
    end
  end

  describe "#mask" do
    it "returns correct mask for /24" do
      net = Netwrangler::Util::IPv4Network.parse("10.0.1.0/24")
      net.mask.should eq(0xFFFFFF00_u32)
    end

    it "returns correct mask for /16" do
      net = Netwrangler::Util::IPv4Network.parse("10.0.0.0/16")
      net.mask.should eq(0xFFFF0000_u32)
    end

    it "returns correct mask for /32" do
      net = Netwrangler::Util::IPv4Network.parse("10.0.1.1/32")
      net.mask.should eq(0xFFFFFFFF_u32)
    end

    it "returns correct mask for /0" do
      net = Netwrangler::Util::IPv4Network.parse("0.0.0.0/0")
      net.mask.should eq(0_u32)
    end
  end

  describe "#contains?" do
    it "contains an IP within the /24 network" do
      net = Netwrangler::Util::IPv4Network.parse("10.0.1.0/24")
      ip = Netwrangler::Util::IPv4Address.parse("10.0.1.100")
      net.contains?(ip).should be_true
    end

    it "does not contain an IP outside the /24 network" do
      net = Netwrangler::Util::IPv4Network.parse("10.0.1.0/24")
      ip = Netwrangler::Util::IPv4Address.parse("10.0.2.1")
      net.contains?(ip).should be_false
    end

    it "contains the first address of the network" do
      net = Netwrangler::Util::IPv4Network.parse("10.0.1.0/24")
      ip = Netwrangler::Util::IPv4Address.parse("10.0.1.0")
      net.contains?(ip).should be_true
    end

    it "contains the last address of the network" do
      net = Netwrangler::Util::IPv4Network.parse("10.0.1.0/24")
      ip = Netwrangler::Util::IPv4Address.parse("10.0.1.255")
      net.contains?(ip).should be_true
    end

    it "contains an IP within a /16 network" do
      net = Netwrangler::Util::IPv4Network.parse("10.0.0.0/16")
      ip = Netwrangler::Util::IPv4Address.parse("10.0.99.1")
      net.contains?(ip).should be_true
    end

    it "/32 contains only the exact address" do
      net = Netwrangler::Util::IPv4Network.parse("10.0.1.1/32")
      net.contains?(Netwrangler::Util::IPv4Address.parse("10.0.1.1")).should be_true
      net.contains?(Netwrangler::Util::IPv4Address.parse("10.0.1.2")).should be_false
    end

    it "/0 contains every address" do
      net = Netwrangler::Util::IPv4Network.parse("0.0.0.0/0")
      net.contains?(Netwrangler::Util::IPv4Address.parse("0.0.0.0")).should be_true
      net.contains?(Netwrangler::Util::IPv4Address.parse("255.255.255.255")).should be_true
      net.contains?(Netwrangler::Util::IPv4Address.parse("192.168.1.1")).should be_true
    end
  end

  describe "#first_address" do
    it "returns network address for /24" do
      net = Netwrangler::Util::IPv4Network.parse("10.0.1.100/24")
      net.first_address.should eq(Netwrangler::Util::IPv4Address.parse("10.0.1.0"))
    end

    it "returns same address for /32" do
      net = Netwrangler::Util::IPv4Network.parse("10.0.1.1/32")
      net.first_address.should eq(Netwrangler::Util::IPv4Address.parse("10.0.1.1"))
    end

    it "returns 0.0.0.0 for /0" do
      net = Netwrangler::Util::IPv4Network.parse("10.0.1.1/0")
      net.first_address.should eq(Netwrangler::Util::IPv4Address.parse("0.0.0.0"))
    end
  end

  describe "#last_address" do
    it "returns broadcast address for /24" do
      net = Netwrangler::Util::IPv4Network.parse("10.0.1.0/24")
      net.last_address.should eq(Netwrangler::Util::IPv4Address.parse("10.0.1.255"))
    end

    it "returns same address for /32" do
      net = Netwrangler::Util::IPv4Network.parse("10.0.1.1/32")
      net.last_address.should eq(Netwrangler::Util::IPv4Address.parse("10.0.1.1"))
    end

    it "returns 255.255.255.255 for /0" do
      net = Netwrangler::Util::IPv4Network.parse("0.0.0.0/0")
      net.last_address.should eq(Netwrangler::Util::IPv4Address.parse("255.255.255.255"))
    end
  end

  describe "#address_range" do
    it "returns correct range for /24" do
      net = Netwrangler::Util::IPv4Network.parse("10.0.1.0/24")
      range = net.address_range
      range.begin.should eq(Netwrangler::Util::IPv4Address.parse("10.0.1.0"))
      range.end.should eq(Netwrangler::Util::IPv4Address.parse("10.0.1.255"))
    end

    it "range includes IPs within the network" do
      net = Netwrangler::Util::IPv4Network.parse("10.0.1.0/24")
      range = net.address_range
      range.includes?(Netwrangler::Util::IPv4Address.parse("10.0.1.50")).should be_true
    end

    it "range excludes IPs outside the network" do
      net = Netwrangler::Util::IPv4Network.parse("10.0.1.0/24")
      range = net.address_range
      range.includes?(Netwrangler::Util::IPv4Address.parse("10.0.2.1")).should be_false
    end
  end

  describe "#to_s" do
    it "formats as CIDR notation" do
      net = Netwrangler::Util::IPv4Network.parse("10.0.1.0/24")
      net.to_s.should eq("10.0.1.0/24")
    end
  end

  describe "#canonical" do
    it "clears host bits" do
      Netwrangler::Util::IPv4Network.parse("198.51.100.7/24").canonical.to_s.should eq("198.51.100.0/24")
    end

    it "keeps a network that has no host bits" do
      Netwrangler::Util::IPv4Network.parse("10.0.0.0/8").canonical.to_s.should eq("10.0.0.0/8")
    end

    it "maps any /0 to 0.0.0.0/0" do
      Netwrangler::Util::IPv4Network.parse("10.1.2.3/0").canonical.to_s.should eq("0.0.0.0/0")
    end
  end

  describe "#overlaps?" do
    it "is true when this network contains the other" do
      outer = Netwrangler::Util::IPv4Network.parse("10.0.0.0/8")
      inner = Netwrangler::Util::IPv4Network.parse("10.20.0.0/16")
      outer.overlaps?(inner).should be_true
    end

    it "is true when the other network contains this one" do
      outer = Netwrangler::Util::IPv4Network.parse("10.0.0.0/8")
      inner = Netwrangler::Util::IPv4Network.parse("10.20.0.0/16")
      inner.overlaps?(outer).should be_true
    end

    it "is false for adjacent networks" do
      first = Netwrangler::Util::IPv4Network.parse("10.0.0.0/24")
      second = Netwrangler::Util::IPv4Network.parse("10.0.1.0/24")
      first.overlaps?(second).should be_false
    end

    it "is true for 0.0.0.0/0 against any network" do
      all = Netwrangler::Util::IPv4Network.parse("0.0.0.0/0")
      all.overlaps?(Netwrangler::Util::IPv4Network.parse("192.0.2.0/24")).should be_true
    end
  end
end
