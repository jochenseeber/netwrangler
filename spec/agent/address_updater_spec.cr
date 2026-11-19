require "../spec_helper"

describe Netwrangler::Agent::AddressUpdater::IpAddrOutput do
  describe "JSON deserialization" do
    it "deserializes valid JSON with addresses" do
      json = <<-JSON
        {
          "addr_info": [
            {"family": "inet", "local": "10.0.0.1", "prefixlen": 32},
            {"family": "inet", "local": "10.0.0.2", "prefixlen": 24},
            {"family": "inet6", "local": "::1", "prefixlen": 128}
          ]
        }
        JSON

      output = Netwrangler::Agent::AddressUpdater::IpAddrOutput.from_json(json)
      output.addr_info.size.should eq(3)
    end

    it "deserializes JSON with empty addr_info" do
      json = %({"addr_info": []})
      output = Netwrangler::Agent::AddressUpdater::IpAddrOutput.from_json(json)
      output.addr_info.should be_empty
    end
  end

  describe "VIP address filtering" do
    it "filters VIP addresses from a mixed set" do
      json = <<-JSON
        {
          "addr_info": [
            {"family": "inet", "local": "192.168.1.100", "prefixlen": 24, "label": "eth0"},
            {"family": "inet", "local": "10.0.0.1", "prefixlen": 32, "label": "vip:public"},
            {"family": "inet", "local": "10.0.0.2", "prefixlen": 32, "label": "vip:dmz"},
            {"family": "inet6", "local": "fe80::1", "prefixlen": 64},
            {"family": "inet", "local": "10.0.0.3", "prefixlen": 32},
            {"family": "inet", "local": "10.0.0.4", "prefixlen": 32, "label": "secondary"}
          ]
        }
        JSON

      output = Netwrangler::Agent::AddressUpdater::IpAddrOutput.from_json(json)
      vip_ips = output.addr_info
        .select { |addr| addr.family == "inet" && addr.label.try(&.starts_with?("vip:")) }
        .map(&.local)
        .to_set

      vip_ips.should eq(Set{"10.0.0.1", "10.0.0.2"})
    end

    it "returns empty set when no VIP addresses exist" do
      json = <<-JSON
        {
          "addr_info": [
            {"family": "inet", "local": "192.168.1.100", "prefixlen": 24, "label": "eth0"},
            {"family": "inet6", "local": "fe80::1", "prefixlen": 64}
          ]
        }
        JSON

      output = Netwrangler::Agent::AddressUpdater::IpAddrOutput.from_json(json)
      vip_ips = output.addr_info
        .select { |addr| addr.family == "inet" && addr.label.try(&.starts_with?("vip:")) }
        .map(&.local)
        .to_set

      vip_ips.should be_empty
    end
  end
end

describe Netwrangler::Agent::AddressUpdater::AddrInfo do
  describe "JSON deserialization" do
    it "deserializes valid JSON" do
      json = %({"family": "inet", "local": "192.168.1.100", "prefixlen": 32})
      addr = Netwrangler::Agent::AddressUpdater::AddrInfo.from_json(json)

      addr.family.should eq("inet")
      addr.local.should eq("192.168.1.100")
      addr.prefixlen.should eq(32)
    end

    it "deserializes IPv6 address" do
      json = %({"family": "inet6", "local": "fe80::1", "prefixlen": 64})
      addr = Netwrangler::Agent::AddressUpdater::AddrInfo.from_json(json)

      addr.family.should eq("inet6")
      addr.local.should eq("fe80::1")
      addr.prefixlen.should eq(64)
    end

    it "deserializes address with label" do
      json = %({"family": "inet", "local": "10.0.0.1", "prefixlen": 32, "label": "vip:eth0"})
      addr = Netwrangler::Agent::AddressUpdater::AddrInfo.from_json(json)

      addr.family.should eq("inet")
      addr.local.should eq("10.0.0.1")
      addr.prefixlen.should eq(32)
      addr.label.should eq("vip:eth0")
    end

    it "handles missing label" do
      json = %({"family": "inet", "local": "10.0.0.1", "prefixlen": 32})
      addr = Netwrangler::Agent::AddressUpdater::AddrInfo.from_json(json)

      addr.label.should be_nil
    end

    it "handles null label" do
      json = %({"family": "inet", "local": "10.0.0.1", "prefixlen": 32, "label": null})
      addr = Netwrangler::Agent::AddressUpdater::AddrInfo.from_json(json)

      addr.label.should be_nil
    end
  end

  describe "VIP filtering criteria" do
    it "matches IPv4 VIP address with family=inet and vip: label" do
      json = %({"family": "inet", "local": "10.0.0.1", "prefixlen": 32, "label": "vip:public"})
      addr = Netwrangler::Agent::AddressUpdater::AddrInfo.from_json(json)

      is_vip = addr.family == "inet" &&
               addr.label.try(&.starts_with?(Netwrangler::Agent::AddressUpdater::VIP_LABEL_PREFIX))
      is_vip.should be_truthy
    end

    it "matches IPv4 VIP address with non-/32 prefix length" do
      json = %({"family": "inet", "local": "10.0.0.1", "prefixlen": 24, "label": "vip:public"})
      addr = Netwrangler::Agent::AddressUpdater::AddrInfo.from_json(json)

      is_vip = addr.family == "inet" &&
               addr.label.try(&.starts_with?(Netwrangler::Agent::AddressUpdater::VIP_LABEL_PREFIX))
      is_vip.should be_truthy
    end

    it "rejects IPv6 address" do
      json = %({"family": "inet6", "local": "::1", "prefixlen": 128, "label": "vip:public"})
      addr = Netwrangler::Agent::AddressUpdater::AddrInfo.from_json(json)

      is_vip = addr.family == "inet" &&
               addr.label.try(&.starts_with?(Netwrangler::Agent::AddressUpdater::VIP_LABEL_PREFIX))
      is_vip.should be_falsey
    end

    it "rejects address without label" do
      json = %({"family": "inet", "local": "10.0.0.1", "prefixlen": 32})
      addr = Netwrangler::Agent::AddressUpdater::AddrInfo.from_json(json)

      is_vip = addr.family == "inet" &&
               addr.label.try(&.starts_with?(Netwrangler::Agent::AddressUpdater::VIP_LABEL_PREFIX))
      is_vip.should be_falsey
    end

    it "rejects address with non-VIP label" do
      json = %({"family": "inet", "local": "10.0.0.1", "prefixlen": 32, "label": "eth0"})
      addr = Netwrangler::Agent::AddressUpdater::AddrInfo.from_json(json)

      is_vip = addr.family == "inet" &&
               addr.label.try(&.starts_with?(Netwrangler::Agent::AddressUpdater::VIP_LABEL_PREFIX))
      is_vip.should be_falsey
    end

    it "accepts address with VIP label containing network name" do
      json = %({"family": "inet", "local": "10.0.0.1", "prefixlen": 32, "label": "vip:my-network"})
      addr = Netwrangler::Agent::AddressUpdater::AddrInfo.from_json(json)

      is_vip = addr.family == "inet" &&
               addr.label.try(&.starts_with?(Netwrangler::Agent::AddressUpdater::VIP_LABEL_PREFIX))
      is_vip.should be_truthy
    end
  end
end
