require "../spec_helper"

# Maps as nft 1.1.2 to 1.1.7 list them with `nft -j list map`
private MARK_MAP_JSON = <<-JSON
  {"nftables": [{"metainfo": {"version": "1.1.7", "release_name": "Commodore Bullmoose #8", "json_schema_version": 1}}, {"map": {"family": "ip", "name": "ingress-marks-ipv4", "table": "netwrangler", "type": ["ipv4_addr", "ipv4_addr"], "handle": 5, "map": "mark", "flags": ["interval"], "elem": [[{"concat": ["10.0.1.10", {"prefix": {"addr": "10.0.1.0", "len": 24}}]}, 262144], [{"concat": ["10.0.1.10", "192.0.2.5"]}, 262144]]}}]}
  JSON

private DEFAULT_MAP_JSON = <<-JSON
  {"nftables": [{"metainfo": {"version": "1.1.2", "release_name": "Commodore Bullmoose #3", "json_schema_version": 1}}, {"map": {"family": "ip", "name": "egress-marks-default-ipv4", "table": "netwrangler", "type": "ipv4_addr", "handle": 6, "map": "mark", "elem": [["10.244.0.1", 262144]]}}]}
  JSON

private EMPTY_MAP_JSON = <<-JSON
  {"nftables": [{"metainfo": {"version": "1.1.7", "release_name": "Commodore Bullmoose #8", "json_schema_version": 1}}, {"map": {"family": "ip", "name": "egress-marks-ipv4", "table": "netwrangler", "type": ["ipv4_addr", "ipv4_addr"], "handle": 7, "map": "mark", "flags": ["interval"]}}]}
  JSON

# The verdict map of the agent before mark maps
private VERDICT_MAP_JSON = <<-JSON
  {"nftables": [{"metainfo": {"version": "1.1.7", "release_name": "Commodore Bullmoose #8", "json_schema_version": 1}}, {"map": {"family": "ip", "name": "ingress-marks-ipv4", "table": "netwrangler", "type": ["ipv4_addr", "ipv4_addr"], "handle": 8, "comment": "VIP + source network to mark chain", "map": "verdict", "flags": ["interval"], "elem": [[{"concat": ["172.18.0.200", {"prefix": {"addr": "172.18.0.0", "len": 16}}]}, {"goto": {"target": "mark-00040000"}}]]}}]}
  JSON

private SNAT_MAP_JSON = <<-JSON
  {"nftables": [{"metainfo": {"version": "1.1.7", "release_name": "Commodore Bullmoose #8", "json_schema_version": 1}}, {"map": {"family": "ip", "name": "snat-addresses", "table": "netwrangler", "type": ["mark", "ifname"], "handle": 6, "comment": "Firewall mark + outgoing interface to SNAT address", "map": "ipv4_addr", "elem": [[{"concat": [262144, "eth0"]}, "172.18.0.200"]]}}]}
  JSON

private def address(text : String) : Netwrangler::Util::IPv4Address
  Netwrangler::Util::IPv4Address.parse(text)
end

private def network(text : String) : Netwrangler::Util::IPv4Network
  Netwrangler::Util::IPv4Network.parse(text)
end

describe Netwrangler::Agent::NftablesUpdater::MarkMapEntry do
  describe ".specific" do
    it "builds the key nft lists for a network" do
      entry = Netwrangler::Agent::NftablesUpdater::MarkMapEntry.specific(address("10.0.1.10"), network("10.0.1.0/24"), mark: 0x40000)

      entry.should eq(Netwrangler::Agent::NftablesUpdater.parse_mark_map_entries(MARK_MAP_JSON)[0])
    end

    it "builds the key nft lists for a single address" do
      entry = Netwrangler::Agent::NftablesUpdater::MarkMapEntry.specific(address("10.0.1.10"), network("192.0.2.5/32"), mark: 0x40000)

      entry.should eq(Netwrangler::Agent::NftablesUpdater.parse_mark_map_entries(MARK_MAP_JSON)[1])
    end

    it "drops host bits from the network, as nft does" do
      entry = Netwrangler::Agent::NftablesUpdater::MarkMapEntry.specific(address("10.0.1.10"), network("10.0.1.5/24"), mark: 0x40000)

      entry.key_text.should eq("10.0.1.10 . 10.0.1.0/24")
    end
  end

  describe ".default" do
    it "builds the key nft lists for an address" do
      entry = Netwrangler::Agent::NftablesUpdater::MarkMapEntry.default(address("10.244.0.1"), mark: 0x40000)

      entry.should eq(Netwrangler::Agent::NftablesUpdater.parse_mark_map_entries(DEFAULT_MAP_JSON)[0])
    end
  end

  describe "#to_json_element" do
    it "pairs the key with the mark" do
      entry = Netwrangler::Agent::NftablesUpdater::MarkMapEntry.default(address("10.244.0.1"), mark: 0x40000)

      entry.to_json_element.to_json.should eq(%(["10.244.0.1",262144]))
    end
  end

  describe "#key_text" do
    it "renders the key in nft's text syntax" do
      entries = Netwrangler::Agent::NftablesUpdater.parse_mark_map_entries(MARK_MAP_JSON)

      entries.map(&.key_text).should eq(["10.0.1.10 . 10.0.1.0/24", "10.0.1.10 . 192.0.2.5"])
    end
  end

  describe "#mark_hex" do
    it "prints the mark as nft does" do
      Netwrangler::Agent::NftablesUpdater::MarkMapEntry.default(address("10.0.1.10"), mark: 0x40000).mark_hex.should eq("0x00040000")
    end
  end
end

describe Netwrangler::Agent::NftablesUpdater::DesiredSnatEntry do
  it "stores mark, virtual_ip, and interface" do
    entry = Netwrangler::Agent::NftablesUpdater::DesiredSnatEntry.new(
      mark: 0x010000,
      virtual_ip: Netwrangler::Util::IPv4Address.parse("10.0.1.10"),
      interface: "eth0"
    )

    entry.mark.should eq(0x010000)
    entry.virtual_ip.to_s.should eq("10.0.1.10")
    entry.interface.should eq("eth0")
  end
end

describe Netwrangler::Agent::NftablesUpdater::ExistingSnatEntry do
  it "has the key of the desired entry for the same mark and interface" do
    existing = Netwrangler::Agent::NftablesUpdater::ExistingSnatEntry.new(mark: 0x040000, interface: "eth0", virtual_ip: "172.18.0.200")
    desired = Netwrangler::Agent::NftablesUpdater::DesiredSnatEntry.new(mark: 0x040000, virtual_ip: address("172.18.0.200"), interface: "eth0")

    existing.key.should eq(desired.key)
    desired.to_json_element.to_json.should eq(%([{"concat":[262144,"eth0"]},"172.18.0.200"]))
  end
end

describe Netwrangler::Agent::NftablesUpdater do
  describe ".parse_mark_map_entries" do
    it "reads the marks of a map's elements" do
      Netwrangler::Agent::NftablesUpdater.parse_mark_map_entries(MARK_MAP_JSON).map(&.mark).should eq([0x40000, 0x40000])
    end

    it "reads a map without elements" do
      Netwrangler::Agent::NftablesUpdater.parse_mark_map_entries(EMPTY_MAP_JSON).should be_empty
    end

    it "skips the elements of a verdict map" do
      Netwrangler::Agent::NftablesUpdater.parse_mark_map_entries(VERDICT_MAP_JSON).should be_empty
    end
  end

  describe ".network_json" do
    it "writes a network as a prefix and a single address as an address" do
      Netwrangler::Agent::NftablesUpdater.network_json(network("10.0.1.0/24")).to_json.should eq(%({"prefix":{"addr":"10.0.1.0","len":24}}))
      Netwrangler::Agent::NftablesUpdater.network_json(network("192.0.2.5/32")).to_json.should eq(%("192.0.2.5"))
    end
  end

  describe ".parse_snat_entries" do
    it "reads mark, interface and address of each element" do
      Netwrangler::Agent::NftablesUpdater.parse_snat_entries(SNAT_MAP_JSON).should eq([
        Netwrangler::Agent::NftablesUpdater::ExistingSnatEntry.new(mark: 0x040000, interface: "eth0", virtual_ip: "172.18.0.200"),
      ])
    end
  end

  describe ".set_refill_commands" do
    it "only flushes the set when there are no networks" do
      commands = Netwrangler::Agent::NftablesUpdater.set_refill_commands(
        Netwrangler::Agent::NftablesUpdater::GATEWAY_DESTINATIONS_SET, [] of Netwrangler::Util::IPv4Network)

      commands.to_json.should eq(%([{"flush":{"set":{"family":"ip","table":"netwrangler","name":"gateway-destinations"}}}]))
    end

    it "flushes and refills the set in one transaction, canonical and deduplicated" do
      networks = ["10.0.0.0/8", "198.51.100.7/24", "198.51.100.0/24", "192.0.2.7/32"].map { |cidr| network(cidr) }
      commands = Netwrangler::Agent::NftablesUpdater.set_refill_commands(Netwrangler::Agent::NftablesUpdater::GATEWAY_DESTINATIONS_SET, networks)

      commands[1].to_json.should eq(
        %({"add":{"element":{"family":"ip","table":"netwrangler","name":"gateway-destinations","elem":[) +
        %({"prefix":{"addr":"10.0.0.0","len":8}},{"prefix":{"addr":"198.51.100.0","len":24}},"192.0.2.7"]}}}))
    end
  end
end
