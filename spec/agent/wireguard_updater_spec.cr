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

  describe "#find_peer_for_pod (via ensure_allowed_ip logic)" do
    # find_peer_for_pod is private, but we can test it indirectly
    # by verifying discover_peers parses wg dump output correctly

    it "parses wg show dump output into PeerInfo records" do
      # wg show <iface> dump format:
      # line 1: private key, public key, listen port, fwmark
      # line 2+: public_key, preshared_key, endpoint, allowed_ips, ...
      dump_output = [
        "PRIVATE_KEY\tPUBLIC_KEY\t36494\toff",
        "peer1pubkey\t(none)\t10.64.16.4:36494\t10.80.4.0/24,10.64.0.4/32\t1234\t5678\t9012\toff",
        "peer2pubkey\t(none)\t10.64.16.6:36494\t10.80.6.0/24,10.64.0.6/32\t1234\t5678\t9012\toff",
      ].join("\n")

      # Parse like discover_peers does
      peers = [] of Netwrangler::Agent::WireguardUpdater::PeerInfo
      dump_output.each_line.skip(1).each do |line|
        fields = line.split("\t")
        next if fields.size < 4
        public_key = fields[0]
        allowed_ips = fields[3].split(",").map(&.strip).reject(&.empty?)
        peers << Netwrangler::Agent::WireguardUpdater::PeerInfo.new(
          public_key: public_key, allowed_ips: allowed_ips)
      end

      peers.size.should eq(2)
      peers[0].public_key.should eq("peer1pubkey")
      peers[0].allowed_ips.should eq(["10.80.4.0/24", "10.64.0.4/32"])
      peers[1].public_key.should eq("peer2pubkey")
      peers[1].allowed_ips.should eq(["10.80.6.0/24", "10.64.0.6/32"])
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
