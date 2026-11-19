require "../spec_helper"
require "../support/fake_tool_runner"

# `nft -j list ruleset` of the agent's table as nft 1.0.6 (Debian 12) lists it
private LISTING = File.read(Path[__DIR__, "fixtures", "nft-1.0.6.json"])

# The agent's table as nft 1.1.3 lists it, its sets and maps declared with
# plain types, which nft 1.0.6 crashes on, and with typeof
private PLAIN_TYPE_LISTING = File.read(Path[__DIR__, "fixtures", "nft-1.1.3.json"])
private TYPEOF_LISTING     = File.read(Path[__DIR__, "fixtures", "nft-1.1.3-typeof.json"])

# A map as nft 1.0.6 lists it with `nft -j list map`
private MARK_MAP_JSON = <<-JSON
  {"nftables": [{"metainfo": {"version": "1.0.6", "release_name": "Lester Gooch #5", "json_schema_version": 1}}, {"map": {"family": "ip", "name": "netwrangler-ingress-marks", "table": "netwrangler-ipv4", "type": ["ipv4_addr", "ipv4_addr"], "handle": 7, "map": "verdict", "flags": ["interval"], "elem": [[{"concat": ["10.0.1.10", {"prefix": {"addr": "10.0.1.0", "len": 24}}]}, {"goto": {"target": "netwrangler-mark-00040000"}}], [{"concat": ["10.0.1.10", "192.0.2.5"]}, {"goto": {"target": "netwrangler-mark-00040000"}}]]}}]}
  JSON

private DEFAULT_MAP_JSON = <<-JSON
  {"nftables": [{"metainfo": {"version": "1.1.3", "release_name": "Commodore Bullmoose #4", "json_schema_version": 1}}, {"map": {"family": "ip", "name": "netwrangler-egress-marks-default", "table": "netwrangler-ipv4", "type": "ipv4_addr", "handle": 10, "map": "verdict", "elem": [["10.244.0.1", {"goto": {"target": "netwrangler-mark-00040000"}}]]}}]}
  JSON

private EMPTY_MAP_JSON = <<-JSON
  {"nftables": [{"metainfo": {"version": "1.1.3", "release_name": "Commodore Bullmoose #4", "json_schema_version": 1}}, {"map": {"family": "ip", "name": "netwrangler-egress-marks", "table": "netwrangler-ipv4", "type": ["ipv4_addr", "ipv4_addr"], "handle": 8, "map": "verdict", "flags": ["interval"]}}]}
  JSON

# A mark map as the previous agent left it, mapping to marks instead of
# chains, as nft 1.0.9 lists it in a table whose mark rules it cannot list
private LEGACY_MAP_JSON = <<-JSON
  {"nftables": [{"metainfo": {"version": "1.0.9", "release_name": "Old Doc Yak #3", "json_schema_version": 1}}, {"map": {"family": "ip", "name": "netwrangler-ingress-marks", "table": "netwrangler-ipv4", "type": ["ipv4_addr", "ipv4_addr"], "handle": 2, "map": "mark", "flags": ["interval"], "elem": [[{"concat": ["10.0.1.10", {"prefix": {"addr": "10.0.1.0", "len": 24}}]}, 262144]]}}]}
  JSON

private SNAT_MAP_JSON = <<-JSON
  {"nftables": [{"metainfo": {"version": "1.1.7", "release_name": "Commodore Bullmoose #8", "json_schema_version": 1}}, {"map": {"family": "ip", "name": "netwrangler-snat-addresses", "table": "netwrangler-ipv4", "type": ["mark", "ifname"], "handle": 6, "comment": "Firewall mark + outgoing interface to SNAT address", "map": "ipv4_addr", "elem": [[{"concat": [262144, "eth0"]}, "172.18.0.200"]]}}]}
  JSON

# The fixture listing with more objects appended
private def listing_with(*objects : String) : String
  items = JSON.parse(LISTING)["nftables"].as_a + objects.to_a.map { |object| JSON.parse(object) }

  {nftables: items}.to_json
end

private def address(text : String) : Netwrangler::Util::IPv4Address
  Netwrangler::Util::IPv4Address.parse(text)
end

private def nft_version(text : String) : Netwrangler::Util::NftVersion
  major, minor, patch = text.split('.').map(&.to_i)

  Netwrangler::Util::NftVersion.new(major: major, minor: minor, patch: patch)
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
    it "pairs the key with a goto to the mark chain" do
      entry = Netwrangler::Agent::NftablesUpdater::MarkMapEntry.default(address("10.244.0.1"), mark: 0x40000)

      entry.to_json_element.to_json.should eq(%(["10.244.0.1",{"goto":{"target":"netwrangler-mark-00040000"}}]))
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
    it "reads the marks of a map's elements from their chains" do
      Netwrangler::Agent::NftablesUpdater.parse_mark_map_entries(MARK_MAP_JSON).map(&.mark).should eq([0x40000, 0x40000])
    end

    it "reads a map without elements" do
      Netwrangler::Agent::NftablesUpdater.parse_mark_map_entries(EMPTY_MAP_JSON).should be_empty
    end

    it "skips the elements of a map the previous agent left" do
      Netwrangler::Agent::NftablesUpdater.parse_mark_map_entries(LEGACY_MAP_JSON).should be_empty
    end
  end

  describe ".mark_chain_name" do
    it "names a VIP's chain after its mark in eight lower-case hex digits" do
      Netwrangler::Agent::NftablesUpdater.mark_chain_name(0x40000).should eq("netwrangler-mark-00040000")
      Netwrangler::Agent::NftablesUpdater.mark_chain_name(0xabc0000).should eq("netwrangler-mark-0abc0000")
    end
  end

  describe ".unreferenced_mark_chains" do
    it "keeps a chain a map element points at" do
      Netwrangler::Agent::NftablesUpdater.unreferenced_mark_chains(LISTING).should be_empty
    end

    it "finds a mark chain no element points at, and no other chain" do
      listing = listing_with(
        %({"chain": {"family": "ip", "table": "netwrangler-ipv4", "name": "netwrangler-mark-00050000", "handle": 30}}),
        %({"chain": {"family": "ip", "table": "netwrangler-ipv4", "name": "netwrangler-other", "handle": 31}}))

      Netwrangler::Agent::NftablesUpdater.unreferenced_mark_chains(listing).should eq(["netwrangler-mark-00050000"])
    end

    it "keeps a chain a rule jumps to" do
      listing = listing_with(
        %({"chain": {"family": "ip", "table": "netwrangler-ipv4", "name": "netwrangler-mark-00050000", "handle": 30}}),
        %({"rule": {"family": "ip", "table": "netwrangler-ipv4", "chain": "netwrangler-filter-prerouting", "handle": 32, "expr": [{"jump": {"target": "netwrangler-mark-00050000"}}]}}))

      Netwrangler::Agent::NftablesUpdater.unreferenced_mark_chains(listing).should be_empty
    end

    it "finds none in a missing table" do
      Netwrangler::Agent::NftablesUpdater.unreferenced_mark_chains(%({"nftables": []})).should be_empty
    end
  end

  describe ".previous_agent_table?" do
    it "recognizes a mark map that maps to marks" do
      Netwrangler::Agent::NftablesUpdater.previous_agent_table?(LEGACY_MAP_JSON).should be_true
    end

    it "accepts a mark map that maps to verdicts" do
      Netwrangler::Agent::NftablesUpdater.previous_agent_table?(MARK_MAP_JSON).should be_false
      Netwrangler::Agent::NftablesUpdater.previous_agent_table?(EMPTY_MAP_JSON).should be_false
    end

    it "accepts a missing map" do
      Netwrangler::Agent::NftablesUpdater.previous_agent_table?(%({"nftables": []})).should be_false
    end

    # The previous agent declared plain types, which every release lists
    # plain; a later nft might list this agent's verdict value as typeof
    it "accepts a mark map whose value lists as a typeof declaration" do
      listing = MARK_MAP_JSON.sub(%("map": "verdict"), %("map": {"typeof": {"accept": null}}))

      Netwrangler::Agent::NftablesUpdater.previous_agent_table?(listing).should be_false
    end
  end

  describe ".plain_type_table?" do
    {"1.1.3", "1.1.7"}.each do |version|
      it "recreates a table of plain types through nft #{version}" do
        Netwrangler::Agent::NftablesUpdater.plain_type_table?(PLAIN_TYPE_LISTING, nft_version(version)).should be_true
        Netwrangler::Agent::NftablesUpdater.plain_type_table?(DEFAULT_MAP_JSON, nft_version(version)).should be_true
      end
    end

    # nft 1.1.2 declares typeof, but whether it lists a typeof declaration as
    # such is untested; if it listed it plain, every run would rebuild the
    # table
    it "keeps a table of plain types through nft 1.1.2" do
      Netwrangler::Agent::NftablesUpdater.plain_type_table?(PLAIN_TYPE_LISTING, nft_version("1.1.2")).should be_false
    end

    it "keeps a table declared with typeof" do
      Netwrangler::Agent::NftablesUpdater.plain_type_table?(TYPEOF_LISTING, nft_version("1.1.3")).should be_false
    end

    it "keeps any table through nft 1.1.1, which declares plain types itself" do
      Netwrangler::Agent::NftablesUpdater.plain_type_table?(PLAIN_TYPE_LISTING, nft_version("1.1.1")).should be_false
      Netwrangler::Agent::NftablesUpdater.plain_type_table?(TYPEOF_LISTING, nft_version("1.1.1")).should be_false
    end

    it "keeps a missing table" do
      Netwrangler::Agent::NftablesUpdater.plain_type_table?(%({"nftables": []}), nft_version("1.1.3")).should be_false
    end
  end

  describe "SETS_AND_MAPS" do
    it "holds every set and map the updater describes" do
      described = {% begin %}
        [{% for name in Netwrangler::Agent::NftablesUpdater.constants %}Netwrangler::Agent::NftablesUpdater::{{ name }}, {% end %}]
      {% end %}

      Netwrangler::Agent::NftablesUpdater::SETS_AND_MAPS.to_set.should eq(described.select(Netwrangler::Agent::NftObjectDescriptor).to_set)
    end

    # nft 1.1.1 and older reject `list maps table`, and a listing of the
    # table loads its rules; one set or map by name does neither
    it "holds every set and map of the table, each listed by name" do
      Netwrangler::Agent::NftablesUpdater::SETS_AND_MAPS.map(&.list_arguments(Netwrangler::Agent::NftablesUpdater::MANGLE_TABLE)).should eq([
        ["list", "map", "ip", "netwrangler-ipv4", "netwrangler-snat-addresses"],
        ["list", "set", "ip", "netwrangler-ipv4", "netwrangler-cluster-networks"],
        ["list", "set", "ip", "netwrangler-ipv4", "netwrangler-gateway-destinations"],
        ["list", "map", "ip", "netwrangler-ipv4", "netwrangler-ingress-marks"],
        ["list", "map", "ip", "netwrangler-ipv4", "netwrangler-egress-marks"],
        ["list", "map", "ip", "netwrangler-ipv4", "netwrangler-ingress-marks-default"],
        ["list", "map", "ip", "netwrangler-ipv4", "netwrangler-egress-marks-default"],
      ])
    end
  end

  describe "PREVIOUS_AGENT_TABLE_PROBE" do
    # nft 1.0.9 aborts listing the previous agent's rules, but lists a map
    it "lists only the ingress mark map, no rules" do
      Netwrangler::Agent::NftablesUpdater::PREVIOUS_AGENT_TABLE_PROBE.should eq(
        ["list", "map", "ip", "netwrangler-ipv4", "netwrangler-ingress-marks"])
    end
  end

  describe ".outermost_networks" do
    it "drops a network inside another" do
      networks = ["10.1.0.0/16", "10.0.0.0/8", "10.2.3.4/32"].map { |cidr| network(cidr) }

      Netwrangler::Agent::NftablesUpdater.outermost_networks(networks).should eq([network("10.0.0.0/8")])
    end

    it "keeps one of equal networks, without host bits" do
      networks = ["198.51.100.7/24", "198.51.100.0/24"].map { |cidr| network(cidr) }

      Netwrangler::Agent::NftablesUpdater.outermost_networks(networks).should eq([network("198.51.100.0/24")])
    end

    it "keeps disjoint networks in their order" do
      networks = ["198.51.100.0/24", "192.0.2.0/24", "10.0.0.0/8"].map { |cidr| network(cidr) }

      Netwrangler::Agent::NftablesUpdater.outermost_networks(networks).should eq(networks)
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

      commands.to_json.should eq(%([{"flush":{"set":{"family":"ip","table":"netwrangler-ipv4","name":"netwrangler-gateway-destinations"}}}]))
    end

    it "leaves out a network inside another, which an interval set without auto-merge rejects" do
      networks = ["198.51.100.0/24", "198.51.100.128/25"].map { |cidr| network(cidr) }
      commands = Netwrangler::Agent::NftablesUpdater.set_refill_commands(Netwrangler::Agent::NftablesUpdater::CLUSTER_NETWORKS_SET, networks)

      commands[1]["add"]["element"]["elem"].to_json.should eq(%([{"prefix":{"addr":"198.51.100.0","len":24}}]))
    end

    it "flushes and refills the set in one transaction, canonical and deduplicated" do
      networks = ["10.0.0.0/8", "198.51.100.7/24", "198.51.100.0/24", "192.0.2.7/32"].map { |cidr| network(cidr) }
      commands = Netwrangler::Agent::NftablesUpdater.set_refill_commands(Netwrangler::Agent::NftablesUpdater::GATEWAY_DESTINATIONS_SET, networks)

      commands[1].to_json.should eq(
        %({"add":{"element":{"family":"ip","table":"netwrangler-ipv4","name":"netwrangler-gateway-destinations","elem":[) +
        %({"prefix":{"addr":"10.0.0.0","len":8}},{"prefix":{"addr":"198.51.100.0","len":24}},"192.0.2.7"]}}}))
    end
  end
end

describe "Netwrangler::Agent::NftablesUpdater.listing_output" do
  command = Netwrangler::Util::Command.new("nft", args: ["-j", "list", "map"])

  it "returns the listing of an existing object" do
    result = Netwrangler::Util::Result.new(exit_code: 0, stdout: %({"nftables": [1]}), stderr: "")

    Netwrangler::Agent::NftablesUpdater.listing_output(command, result).should eq(%({"nftables": [1]}))
  end

  it "returns an empty listing for a missing object" do
    result = Netwrangler::Util::Result.new(exit_code: 1, stdout: "", stderr: "Error: No such file or directory\nlist map ip t m\n")

    Netwrangler::Agent::NftablesUpdater.listing_output(command, result).should eq(%({"nftables": []}))
  end

  it "raises on any other exit 1 error" do
    result = Netwrangler::Util::Result.new(exit_code: 1, stdout: "", stderr: "Error: syntax error\n")

    expect_raises(Netwrangler::Util::CommandError) do
      Netwrangler::Agent::NftablesUpdater.listing_output(command, result)
    end
  end

  it "raises when nft was killed by a signal" do
    result = Netwrangler::Util::Result.new(exit_code: 139, stdout: "", stderr: "terminated by signal SIGSEGV")

    expect_raises(Netwrangler::Util::CommandError) do
      Netwrangler::Agent::NftablesUpdater.listing_output(command, result)
    end
  end
end

# The object listings of a fixture, each as `nft -j list map|set` prints it
private def object_answers(listing : String) : Hash({String, Array(String)}, Netwrangler::Util::Result)
  metainfo = JSON.parse(listing)["nftables"][0]

  Netwrangler::Agent::NftablesUpdater::SETS_AND_MAPS.to_h do |descriptor|
    object = Netwrangler::Agent::NftablesUpdater.json_objects(listing, descriptor.nft_kind).find! { |item| item["name"] == descriptor.name }
    output = {nftables: [metainfo, {descriptor.nft_kind => object}]}.to_json
    { {Netwrangler::Util::NFT, ["-j"] + descriptor.list_arguments("netwrangler-ipv4")}, Netwrangler::Util::Result.new(exit_code: 0, stdout: output, stderr: "") }
  end
end

private def missing_table_answers : Hash({String, Array(String)}, Netwrangler::Util::Result)
  Netwrangler::Agent::NftablesUpdater::SETS_AND_MAPS.to_h do |descriptor|
    { {Netwrangler::Util::NFT, ["-j"] + descriptor.list_arguments("netwrangler-ipv4")},
     Netwrangler::Util::Result.new(exit_code: 1, stdout: "", stderr: "Error: No such file or directory\n") }
  end
end

private DELETE_TABLE_CALL = {Netwrangler::Util::NFT, ["-j", %({"nftables":[{"delete":{"table":{"family":"ip","name":"netwrangler-ipv4"}}}]})]}

private def probe_call(name : String, kind : String = "map") : {String, Array(String)}
  {Netwrangler::Util::NFT, ["-j", "list", kind, "ip", "netwrangler-ipv4", name]}
end

private def remove_outdated_table(answers : Hash({String, Array(String)}, Netwrangler::Util::Result), version : String) : Array({String, Array(String)})
  answers[DELETE_TABLE_CALL] = Netwrangler::Util::Result.new(exit_code: 0, stdout: "", stderr: "")
  runner = FakeToolRunner.new(answers)

  Netwrangler::Agent::NftablesUpdater.new(nft_version: nft_version(version), runner: runner).remove_outdated_table

  runner.calls
end

describe "Netwrangler::Agent::NftablesUpdater#remove_outdated_table" do
  {"1.1.1", "1.1.2"}.each do |version|
    it "lists only the ingress mark map through nft #{version}, and keeps a table of plain types" do
      calls = remove_outdated_table(object_answers(PLAIN_TYPE_LISTING), version)

      calls.should eq([probe_call("netwrangler-ingress-marks")])
    end
  end

  it "lists every set and map once by name through nft 1.1.3, and keeps a table declared with typeof" do
    calls = remove_outdated_table(object_answers(TYPEOF_LISTING), "1.1.3")

    calls.should eq([
      probe_call("netwrangler-ingress-marks"),
      probe_call("netwrangler-snat-addresses"),
      probe_call("netwrangler-cluster-networks", "set"),
      probe_call("netwrangler-gateway-destinations", "set"),
      probe_call("netwrangler-egress-marks"),
      probe_call("netwrangler-ingress-marks-default"),
      probe_call("netwrangler-egress-marks-default"),
    ])
  end

  it "deletes a table of plain types through nft 1.1.3 in one transaction, at the first plain object" do
    calls = remove_outdated_table(object_answers(PLAIN_TYPE_LISTING), "1.1.3")

    calls.should eq([probe_call("netwrangler-ingress-marks"), probe_call("netwrangler-snat-addresses"), DELETE_TABLE_CALL])
  end

  it "deletes the previous agent's table through any nft, before any other listing" do
    answers = object_answers(PLAIN_TYPE_LISTING)
    answers[probe_call("netwrangler-ingress-marks")] = Netwrangler::Util::Result.new(exit_code: 0, stdout: LEGACY_MAP_JSON, stderr: "")

    remove_outdated_table(answers, "1.0.9").should eq([probe_call("netwrangler-ingress-marks"), DELETE_TABLE_CALL])
  end

  it "keeps a missing table" do
    remove_outdated_table(missing_table_answers, "1.1.3").should_not contain(DELETE_TABLE_CALL)
  end
end
