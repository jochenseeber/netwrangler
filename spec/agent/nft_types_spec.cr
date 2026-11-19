require "../spec_helper"

# `nft -j list ruleset` after applying the table the agent builds, with one
# VIP of mark 0x00040000 under the mask 0x00ff0000, as each nft lists it:
# `nftables v1.0.6 (Lester Gooch #5)` (Debian 12),
# `nftables v1.0.9 (Old Doc Yak #3)` (Ubuntu 24.04) and
# `nftables v1.1.3 (Commodore Bullmoose #4)` (Alpine 3.22). `1.1.3` holds
# the sets and maps declared with plain types, `1.1.3-typeof` declared with
# typeof, as the agent declares them through nft 1.1.2 and newer.
private NFT_LISTINGS = {"1.0.6", "1.0.9", "1.1.3", "1.1.3-typeof"}.to_h do |version|
  {version, File.read(Path[__DIR__, "fixtures", "nft-#{version}.json"])}
end

private TYPEOF_LISTING = NFT_LISTINGS["1.1.3-typeof"]

private MASK = 0x00ff0000_u32
private MARK =     0x00040000

private def updater
  Netwrangler::Agent::NftablesUpdater
end

private def listed(listing : String, kind : String, name : String) : JSON::Any
  updater.json_objects(listing, kind).find! { |object| object["name"] == name }
end

private def listed_rule(listing : String, chain : String, comment : String) : JSON::Any
  updater.json_objects(listing, "rule").find! { |rule| rule["chain"] == chain && rule["comment"]? == comment }
end

private def nft_version(text : String) : Netwrangler::Util::NftVersion
  major, minor, patch = text.split('.').map(&.to_i)

  Netwrangler::Util::NftVersion.new(major: major, minor: minor, patch: patch)
end

private SETS_AND_MAPS = Netwrangler::Agent::NftablesUpdater::SETS_AND_MAPS

# A listed object with another value of one field
private def with_field(object : JSON::Any, field : String, value : String) : JSON::Any
  JSON::Any.new(object.as_h.merge({field => JSON.parse(value)}))
end

private def with_type(object : JSON::Any, type : String) : JSON::Any
  with_field(object, "type", type)
end

private def normalize(expr : JSON::Any) : JSON::Any
  Netwrangler::Agent::NftJson.normalize(expr)
end

private MARK_RULES = [
  Netwrangler::Agent::NftablesUpdater::INGRESS_MARK_RULE,
  Netwrangler::Agent::NftablesUpdater::INGRESS_OUTPUT_MARK_RULE,
  Netwrangler::Agent::NftablesUpdater::EGRESS_MARK_RULE,
  Netwrangler::Agent::NftablesUpdater::INGRESS_DEFAULT_MARK_RULE,
  Netwrangler::Agent::NftablesUpdater::INGRESS_DEFAULT_OUTPUT_MARK_RULE,
  Netwrangler::Agent::NftablesUpdater::EGRESS_DEFAULT_MARK_RULE,
]

private MARK_MAPS = [
  Netwrangler::Agent::NftablesUpdater::INGRESS_MAP,
  Netwrangler::Agent::NftablesUpdater::EGRESS_MAP,
  Netwrangler::Agent::NftablesUpdater::INGRESS_DEFAULT_MAP,
  Netwrangler::Agent::NftablesUpdater::EGRESS_DEFAULT_MAP,
]

# A mark map and a mark rule as the previous agent, with the patched nft
# builds, left them: the map holds marks, and the rule looks it up as the
# operand of a bitwise or
private LEGACY_MAP_JSON = <<-JSON
  {"family": "ip", "name": "netwrangler-ingress-marks", "table": "netwrangler-ipv4", "type": ["ipv4_addr", "ipv4_addr"], "handle": 5, "map": "mark", "flags": ["interval"], "elem": [[{"concat": ["10.0.1.10", {"prefix": {"addr": "10.0.1.0", "len": 24}}]}, 262144]]}
  JSON

private LEGACY_RULE_JSON = <<-JSON
  {"family": "ip", "table": "netwrangler-ipv4", "chain": "netwrangler-filter-prerouting", "handle": 8, "comment": "Ingress mark lookup", "expr": [{"mangle": {"key": {"meta": {"key": "mark"}}, "value": {"|": [{"&": [{"meta": {"key": "mark"}}, 4278255615]}, {"map": {"key": {"concat": [{"ct": {"key": "ip daddr", "dir": "original"}}, {"ct": {"key": "ip saddr", "dir": "original"}}]}, "data": "@netwrangler-ingress-marks"}}]}}}, {"accept": null}]}
  JSON

describe Netwrangler::Agent::MarkRuleDescriptor do
  describe "#expr" do
    NFT_LISTINGS.each do |version, listing|
      it "matches the vmap rules nft #{version} lists" do
        MARK_RULES.each do |rule|
          listed_expr = listed_rule(listing, rule.chain_name, rule.comment)["expr"]

          normalize(listed_expr).should eq(normalize(rule.expr))
        end
      end
    end

    it "looks up the map as a verdict map" do
      Netwrangler::Agent::NftablesUpdater::INGRESS_DEFAULT_MARK_RULE.expr.to_json.should eq(
        %([{"vmap":{"key":{"ct":{"key":"ip daddr","dir":"original"}},"data":"@netwrangler-ingress-marks-default"}}]))
    end

    it "guards both egress rules and neither ingress rule" do
      Netwrangler::Agent::NftablesUpdater::EGRESS_MARK_RULE.exclude_set.should eq("netwrangler-gateway-destinations")
      Netwrangler::Agent::NftablesUpdater::EGRESS_DEFAULT_MARK_RULE.exclude_set.should eq("netwrangler-gateway-destinations")
      Netwrangler::Agent::NftablesUpdater::INGRESS_MARK_RULE.exclude_set.should be_nil
      Netwrangler::Agent::NftablesUpdater::INGRESS_DEFAULT_MARK_RULE.exclude_set.should be_nil
    end
  end

  describe "#references?" do
    listing = NFT_LISTINGS["1.0.6"]

    it "finds a listed rule that looks up its map" do
      MARK_RULES.each do |rule|
        rule.references?(listed_rule(listing, rule.chain_name, rule.comment)).should be_true
      end
    end

    it "ignores a rule that looks up another map" do
      ingress = listed_rule(listing, "netwrangler-filter-prerouting", "Ingress mark lookup")

      Netwrangler::Agent::NftablesUpdater::INGRESS_DEFAULT_MARK_RULE.references?(ingress).should be_false
    end

    it "does not take the guard's set for a map" do
      rule = Netwrangler::Agent::MarkRuleDescriptor.new(
        map_name: "netwrangler-gateway-destinations", chain_name: "netwrangler-filter-prerouting",
        match_fields: [Netwrangler::Agent::NftMatchField::CtOriginalIpSaddr], comment: "x")

      rule.references?(listed_rule(listing, "netwrangler-filter-prerouting", "Egress mark lookup for default route")).should be_false
    end
  end
end

describe Netwrangler::Agent::MarkChainDescriptor do
  describe "#name" do
    it "names the chain after the mark in eight hex digits" do
      Netwrangler::Agent::MarkChainDescriptor.new(0x40000).name.should eq("netwrangler-mark-00040000")
      Netwrangler::Agent::NftablesUpdater.mark_chain_name(0x40000).should eq("netwrangler-mark-00040000")
      Netwrangler::Agent::NftablesUpdater.mark_chain_name(0x7f).should eq("netwrangler-mark-0000007f")
    end
  end

  describe ".hex_digits" do
    it "writes a mark as eight lower-case hex digits" do
      Netwrangler::Agent::MarkChainDescriptor.hex_digits(0xabc0000).should eq("0abc0000")
      Netwrangler::Agent::MarkChainDescriptor.new(0xabc0000).comment.should eq("Set firewall mark 0x0abc0000")
      Netwrangler::Agent::NftablesUpdater.mark_hex(0xabc0000).should eq("0x0abc0000")
    end
  end

  describe ".mark?" do
    it "reads the mark from a chain name" do
      Netwrangler::Agent::MarkChainDescriptor.mark?("netwrangler-mark-00040000").should eq(0x40000)
    end

    it "rejects other chains" do
      Netwrangler::Agent::MarkChainDescriptor.mark?("netwrangler-filter-prerouting").should be_nil
      Netwrangler::Agent::MarkChainDescriptor.mark?("netwrangler-mark-4000").should be_nil
      Netwrangler::Agent::MarkChainDescriptor.mark?("netwrangler-mark-0004000G").should be_nil
      Netwrangler::Agent::MarkChainDescriptor.mark?("netwrangler-mark-0004000A").should be_nil
    end
  end

  describe "#expr" do
    it "sets the mark bits from constants and accepts" do
      # meta mark set meta mark & 0xff00ffff | 0x00040000 accept
      Netwrangler::Agent::MarkChainDescriptor.new(MARK).expr(MASK).to_json.should eq(
        %([{"mangle":{"key":{"meta":{"key":"mark"}},"value":{"|":[{"&":[{"meta":{"key":"mark"}},4278255615]},262144]}}},{"accept":null}]))
    end

    NFT_LISTINGS.each do |version, listing|
      it "matches the rule nft #{version} lists" do
        chain = Netwrangler::Agent::MarkChainDescriptor.new(MARK)
        listed_expr = listed_rule(listing, chain.name, chain.comment)["expr"]

        normalize(listed_expr).should eq(normalize(chain.expr(MASK)))
      end
    end

    it "differs for another mask" do
      chain = Netwrangler::Agent::MarkChainDescriptor.new(MARK)
      listed_expr = listed_rule(NFT_LISTINGS["1.0.6"], chain.name, chain.comment)["expr"]

      normalize(listed_expr).should_not eq(normalize(chain.expr(0x00fe0000_u32)))
    end
  end
end

describe Netwrangler::Agent::NftObjectDescriptor do
  describe ".typeof?" do
    it "declares plain types through nft 1.1.1 and older, which reject JSON typeof" do
      Netwrangler::Agent::NftObjectDescriptor.typeof?(nft_version("1.0.6")).should be_false
      Netwrangler::Agent::NftObjectDescriptor.typeof?(nft_version("1.1.1")).should be_false
    end

    it "declares typeof through nft 1.1.2 and newer, whose plain types crash older nft" do
      Netwrangler::Agent::NftObjectDescriptor.typeof?(nft_version("1.1.2")).should be_true
      Netwrangler::Agent::NftObjectDescriptor.typeof?(nft_version("1.1.3")).should be_true
      Netwrangler::Agent::NftObjectDescriptor.typeof?(nft_version("1.1.7")).should be_true
    end
  end

  describe "#to_json_object" do
    it "describes a concatenated verdict map with an interval flag by plain types through nft 1.1.1" do
      Netwrangler::Agent::NftablesUpdater::EGRESS_MAP.to_json_object(table: "netwrangler-ipv4", nft_version: nft_version("1.1.1")).to_json.should eq(
        %({"family":"ip","table":"netwrangler-ipv4","name":"netwrangler-egress-marks","type":["ipv4_addr","ipv4_addr"],) +
        %("map":"verdict","flags":["interval"],"comment":"Endpoint + dest network to firewall mark chain"}))
    end

    it "describes a set with auto-merge by a plain type through nft 1.1.1" do
      Netwrangler::Agent::NftablesUpdater::GATEWAY_DESTINATIONS_SET.to_json_object(table: "netwrangler-ipv4", nft_version: nft_version("1.1.1")).to_json.should eq(
        %({"family":"ip","table":"netwrangler-ipv4","name":"netwrangler-gateway-destinations","type":"ipv4_addr",) +
        %("flags":["interval"],"auto-merge":true,"comment":"VipGateway destinations excluded from egress marking"}))
    end

    {"1.1.2", "1.1.3"}.each do |version|
      it "declares a verdict map's key and value by typeof through nft #{version}" do
        Netwrangler::Agent::NftablesUpdater::EGRESS_MAP.to_json_object(table: "netwrangler-ipv4", nft_version: nft_version(version)).to_json.should eq(
          %({"family":"ip","table":"netwrangler-ipv4","name":"netwrangler-egress-marks",) +
          %("type":{"typeof":{"concat":[{"payload":{"protocol":"ip","field":"daddr"}},{"payload":{"protocol":"ip","field":"saddr"}}]}},) +
          %("map":{"typeof":{"accept":null}},"flags":["interval"],"comment":"Endpoint + dest network to firewall mark chain"}))
      end

      it "declares the SNAT map's key and value by typeof through nft #{version}" do
        object = Netwrangler::Agent::NftablesUpdater::SNAT_MAP.to_json_object(table: "netwrangler-ipv4", nft_version: nft_version(version))

        object["type"].to_json.should eq(%({"typeof":{"concat":[{"meta":{"key":"mark"}},{"meta":{"key":"oifname"}}]}}))
        object["map"].to_json.should eq(%({"typeof":{"payload":{"protocol":"ip","field":"saddr"}}}))
      end

      it "declares a set's key by typeof through nft #{version}" do
        object = Netwrangler::Agent::NftablesUpdater::CLUSTER_NETWORKS_SET.to_json_object(table: "netwrangler-ipv4", nft_version: nft_version(version))

        object["type"].to_json.should eq(%({"typeof":{"payload":{"protocol":"ip","field":"daddr"}}}))
        object.has_key?("map").should be_false
      end
    end

    it "declares every key as nft 1.1.3 lists the typeof declaration" do
      SETS_AND_MAPS.each do |descriptor|
        object = descriptor.to_json_object(table: "netwrangler-ipv4", nft_version: nft_version("1.1.3"))

        object["type"].should eq(listed(TYPEOF_LISTING, descriptor.nft_kind, descriptor.name)["type"])
      end
    end
  end

  describe "#list_arguments" do
    it "lists one set or map by name, without rules" do
      Netwrangler::Agent::NftablesUpdater::SNAT_MAP.list_arguments("netwrangler-ipv4").should eq(
        ["list", "map", "ip", "netwrangler-ipv4", "netwrangler-snat-addresses"])
      Netwrangler::Agent::NftablesUpdater::CLUSTER_NETWORKS_SET.list_arguments("netwrangler-ipv4").should eq(
        ["list", "set", "ip", "netwrangler-ipv4", "netwrangler-cluster-networks"])
    end
  end

  describe "#matches?" do
    it "maps every mark map to verdicts" do
      MARK_MAPS.each { |map| map.value_type.should eq(Netwrangler::Agent::NftDataType::Verdict) }
    end

    NFT_LISTINGS.each do |version, listing|
      it "accepts every object as nft #{version} lists it" do
        SETS_AND_MAPS.each do |descriptor|
          descriptor.matches?(listed(listing, descriptor.nft_kind, descriptor.name)).should be_true
        end
      end
    end

    it "rejects a mark map left by the previous agent" do
      Netwrangler::Agent::NftablesUpdater::INGRESS_MAP.matches?(JSON.parse(LEGACY_MAP_JSON)).should be_false
    end

    it "rejects an object whose flags differ" do
      gateway_set = listed(NFT_LISTINGS["1.1.3"], "set", "netwrangler-gateway-destinations")

      Netwrangler::Agent::NftablesUpdater::CLUSTER_NETWORKS_SET.matches?(gateway_set).should be_false
      Netwrangler::Agent::NftablesUpdater::INGRESS_DEFAULT_MAP.matches?(listed(NFT_LISTINGS["1.1.3"], "map", "netwrangler-ingress-marks")).should be_false
    end

    it "rejects a typeof declaration of another key expression" do
      ingress = listed(TYPEOF_LISTING, "map", "netwrangler-ingress-marks")
      swapped = with_type(ingress, %({"typeof": {"concat": [{"payload": {"protocol": "ip", "field": "saddr"}}, {"payload": {"protocol": "ip", "field": "daddr"}}]}}))
      default_map = listed(TYPEOF_LISTING, "map", "netwrangler-ingress-marks-default")
      source = with_type(default_map, %({"typeof": {"payload": {"protocol": "ip", "field": "saddr"}}}))

      Netwrangler::Agent::NftablesUpdater::INGRESS_MAP.matches?(swapped).should be_false
      Netwrangler::Agent::NftablesUpdater::INGRESS_DEFAULT_MAP.matches?(source).should be_false
      Netwrangler::Agent::NftablesUpdater::INGRESS_DEFAULT_MAP.matches?(ingress).should be_false
    end

    # Every release so far lists the value type plain; a later one might list
    # the typeof declaration, as it does for the key
    it "accepts a value listed as its typeof declaration" do
      ingress = listed(TYPEOF_LISTING, "map", "netwrangler-ingress-marks")
      snat = listed(TYPEOF_LISTING, "map", "netwrangler-snat-addresses")

      Netwrangler::Agent::NftablesUpdater::INGRESS_MAP.matches?(with_field(ingress, "map", %({"typeof": {"accept": null}}))).should be_true
      Netwrangler::Agent::NftablesUpdater::SNAT_MAP.matches?(
        with_field(snat, "map", %({"typeof": {"payload": {"protocol": "ip", "field": "saddr"}}}))).should be_true
    end

    it "rejects a value listed as the typeof declaration of another value" do
      ingress = listed(TYPEOF_LISTING, "map", "netwrangler-ingress-marks")
      snat = listed(TYPEOF_LISTING, "map", "netwrangler-snat-addresses")

      Netwrangler::Agent::NftablesUpdater::INGRESS_MAP.matches?(
        with_field(ingress, "map", %({"typeof": {"payload": {"protocol": "ip", "field": "saddr"}}}))).should be_false
      Netwrangler::Agent::NftablesUpdater::SNAT_MAP.matches?(
        with_field(snat, "map", %({"typeof": {"payload": {"protocol": "ip", "field": "daddr"}}}))).should be_false
    end

    it "rejects a set listed with a value, and a map without" do
      cluster = listed(TYPEOF_LISTING, "set", "netwrangler-cluster-networks")
      default_map = listed(TYPEOF_LISTING, "map", "netwrangler-ingress-marks-default")

      Netwrangler::Agent::NftablesUpdater::CLUSTER_NETWORKS_SET.matches?(with_field(cluster, "map", %("verdict"))).should be_false
      Netwrangler::Agent::NftablesUpdater::INGRESS_DEFAULT_MAP.matches?(JSON::Any.new(default_map.as_h.reject("map"))).should be_false
    end

    it "rejects a plain type of another key" do
      default_map = listed(NFT_LISTINGS["1.0.6"], "map", "netwrangler-ingress-marks-default")

      Netwrangler::Agent::NftablesUpdater::INGRESS_DEFAULT_MAP.matches?(with_type(default_map, %("mark"))).should be_false
    end
  end
end

describe Netwrangler::Agent::ClusterNetworksRuleDescriptor do
  describe "#expr" do
    NFT_LISTINGS.each do |version, listing|
      it "matches the statements nft #{version} lists for both chains" do
        [Netwrangler::Agent::NftablesUpdater::CLUSTER_PREROUTING_RULE, Netwrangler::Agent::NftablesUpdater::CLUSTER_OUTPUT_RULE].each do |rule|
          listed_rule(listing, rule.chain_name, rule.comment)["expr"].should eq(rule.expr)
        end
      end
    end
  end

  describe "#references?" do
    it "finds the rule that matches against its set, not the egress guard" do
      listing = NFT_LISTINGS["1.0.6"]
      rule = Netwrangler::Agent::NftablesUpdater::CLUSTER_PREROUTING_RULE

      rule.references?(listed_rule(listing, rule.chain_name, rule.comment)).should be_true
      rule.references?(listed_rule(listing, rule.chain_name, "Egress mark lookup for default route")).should be_false
    end
  end
end

describe Netwrangler::Agent::SnatRuleDescriptor do
  describe "#expr" do
    NFT_LISTINGS.each do |version, listing|
      it "matches the statements nft #{version} lists, whichever form the flag takes" do
        rule = Netwrangler::Agent::NftablesUpdater::SNAT_RULE

        normalize(listed_rule(listing, rule.chain_name, rule.comment)["expr"]).should eq(normalize(rule.expr(MASK)))
      end
    end
  end

  describe "#references?" do
    it "finds the rule that looks up the SNAT map" do
      listing = NFT_LISTINGS["1.0.6"]
      rule = Netwrangler::Agent::NftablesUpdater::SNAT_RULE

      rule.references?(listed_rule(listing, rule.chain_name, rule.comment)).should be_true
      rule.references?(listed_rule(listing, "netwrangler-filter-prerouting", "Ingress mark lookup")).should be_false
    end
  end
end

describe Netwrangler::Agent::NftJson do
  describe ".normalize" do
    it "writes a single flag as a list and leaves the rest alone" do
      Netwrangler::Agent::NftJson.normalize(JSON.parse(%({"snat": {"flags": "fully-random", "addr": "x"}}))).to_json
        .should eq(%({"snat":{"flags":["fully-random"],"addr":"x"}}))
    end

    it "clears the bits a constant or sets from the and mask before it" do
      # nft lists `meta mark & 0xff00ffff | 0x00040000` as `& 0xff04ffff | 0x00040000`
      listed = JSON.parse(%({"|": [{"&": [{"meta": {"key": "mark"}}, 4278517759]}, 262144]}))

      Netwrangler::Agent::NftJson.normalize(listed).to_json.should eq(%({"|":[{"&":[{"meta":{"key":"mark"}},4278255615]},262144]}))
    end

    it "leaves a bitwise or with a lookup alone" do
      expr = JSON.parse(LEGACY_RULE_JSON)["expr"]

      Netwrangler::Agent::NftJson.normalize(expr).should eq(expr)
    end
  end
end

describe "Netwrangler::Agent::TYPEOF_NFT" do
  it "is nft 1.1.2, the first release the agent declares typeof through" do
    Netwrangler::Agent::TYPEOF_NFT.should eq(Netwrangler::Util::NftVersion.new(major: 1, minor: 1, patch: 2))
  end
end

describe "Netwrangler::Agent::MINIMUM_NFT" do
  it "is nft 1.0.6, the oldest release the agent's JSON round trip was verified against" do
    Netwrangler::Agent::MINIMUM_NFT.should eq(Netwrangler::Util::NftVersion.new(major: 1, minor: 0, patch: 6))
  end
end
