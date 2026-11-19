require "../spec_helper"

describe Netwrangler::Agent::WireguardUpdater do
  describe Netwrangler::Agent::WireguardUpdater::PeerInfo do
    it "stores public key and allowed IPs" do
      peer = Netwrangler::Agent::WireguardUpdater::PeerInfo.new(
        public_key: "abc123",
        allowed_ips: ["10.80.4.0/24", "10.64.0.4/32"]
      )

      peer.public_key.should eq("abc123")
      peer.allowed_ips.should eq(["10.80.4.0/24", "10.64.0.4/32"])
    end
  end

  describe ".parse_wireguard_interfaces" do
    it "names the interfaces in ip --json link show type wireguard output" do
      json = %([{"ifindex":5,"ifname":"wg0","flags":["POINTOPOINT","UP"]},{"ifindex":6,"ifname":"wg1","flags":[]}])

      Netwrangler::Agent::WireguardUpdater.parse_wireguard_interfaces(json).should eq(Set{"wg0", "wg1"})
    end

    it "finds no interface in an empty list or empty output" do
      Netwrangler::Agent::WireguardUpdater.parse_wireguard_interfaces("[]").should be_empty
      Netwrangler::Agent::WireguardUpdater.parse_wireguard_interfaces("").should be_empty
    end
  end

  describe "#find_peer_for_pod (via ensure_allowed_ip logic)" do
    # find_peer_for_pod is private, but we can test it indirectly
    # by verifying parse_allowed_ips parses wg show allowed-ips output correctly

    it "parses wg show allowed-ips output into PeerInfo records" do
      output = "xTIBA5rboUvnH4htodjb6e697QjLERt1NAB4mZqp8Dg=\t10.0.0.0/8 198.51.100.0/24\n" \
               "HIgo9xNzJMWLKASShiTqIybxZ0U3wGLiUeJ1PKf8ykw=\t(none)\n"

      peers = Netwrangler::Agent::WireguardUpdater.parse_allowed_ips(output)

      peers.size.should eq(2)
      peers[0].public_key.should eq("xTIBA5rboUvnH4htodjb6e697QjLERt1NAB4mZqp8Dg=")
      peers[0].allowed_ips.should eq(["10.0.0.0/8", "198.51.100.0/24"])
      peers[1].public_key.should eq("HIgo9xNzJMWLKASShiTqIybxZ0U3wGLiUeJ1PKf8ykw=")
      peers[1].allowed_ips.should eq([] of String)
    end

    it "parses empty allowed-ips output into no peers" do
      Netwrangler::Agent::WireguardUpdater.parse_allowed_ips("").should be_empty
    end

    it "finds the correct peer by matching pod IP against allowed IP networks" do
      peers = [
        Netwrangler::Agent::WireguardUpdater::PeerInfo.new(
          public_key: "peer1", allowed_ips: ["10.80.4.0/24", "10.64.0.4/32"]),
        Netwrangler::Agent::WireguardUpdater::PeerInfo.new(
          public_key: "peer2", allowed_ips: ["10.80.6.0/24", "10.64.0.6/32"]),
      ]

      # Pod IP 10.80.4.175 is in 10.80.4.0/24 -> peer1
      parsed_pod_ip = Netwrangler::Util::IPv4Address.parse("10.80.4.175")
      match = peers.find do |peer|
        peer.allowed_ips.any? do |allowed_ip|
          network = Netwrangler::Util::IPv4Network.parse(allowed_ip)
          network.contains?(parsed_pod_ip)
        rescue ArgumentError
          false
        end
      end

      match.should_not be_nil
      match.try(&.public_key).should eq("peer1")

      # Pod IP 10.80.6.191 is in 10.80.6.0/24 -> peer2
      parsed_pod_ip2 = Netwrangler::Util::IPv4Address.parse("10.80.6.191")
      match2 = peers.find do |peer|
        peer.allowed_ips.any? do |allowed_ip|
          network = Netwrangler::Util::IPv4Network.parse(allowed_ip)
          network.contains?(parsed_pod_ip2)
        rescue ArgumentError
          false
        end
      end

      match2.should_not be_nil
      match2.try(&.public_key).should eq("peer2")
    end

    it "returns nil when no peer matches the pod IP" do
      peers = [
        Netwrangler::Agent::WireguardUpdater::PeerInfo.new(
          public_key: "peer1", allowed_ips: ["10.80.4.0/24"]),
      ]

      parsed_pod_ip = Netwrangler::Util::IPv4Address.parse("10.80.99.1")
      match = peers.find do |peer|
        peer.allowed_ips.any? do |allowed_ip|
          network = Netwrangler::Util::IPv4Network.parse(allowed_ip)
          network.contains?(parsed_pod_ip)
        rescue ArgumentError
          false
        end
      end

      match.should be_nil
    end
  end
end
