require "../spec_helper"

# Rules as nft 1.1.2 to 1.1.7 list them with `nft -j list chain`, for a mask of
# 0x00ff0000
private INGRESS_RULE_JSON = <<-JSON
  {"family": "ip", "table": "netwrangler", "chain": "filter-prerouting", "handle": 8, "comment": "Ingress mark lookup", "expr": [{"mangle": {"key": {"meta": {"key": "mark"}}, "value": {"|": [{"&": [{"meta": {"key": "mark"}}, 4278255615]}, {"map": {"key": {"concat": [{"ct": {"key": "ip daddr", "dir": "original"}}, {"ct": {"key": "ip saddr", "dir": "original"}}]}, "data": "@ingress-marks-ipv4"}}]}}}, {"accept": null}]}
  JSON

private EGRESS_DEFAULT_RULE_JSON = <<-JSON
  {"family": "ip", "table": "netwrangler", "chain": "filter-prerouting", "handle": 9, "comment": "Egress mark lookup for default route", "expr": [{"match": {"op": "!=", "left": {"ct": {"key": "ip daddr", "dir": "original"}}, "right": "@gateway-destinations"}}, {"mangle": {"key": {"meta": {"key": "mark"}}, "value": {"|": [{"&": [{"meta": {"key": "mark"}}, 4278255615]}, {"map": {"key": {"ct": {"key": "ip saddr", "dir": "original"}}, "data": "@egress-marks-default-ipv4"}}]}}}, {"accept": null}]}
  JSON

private OUTPUT_RULE_JSON = <<-JSON
  {"family": "ip", "table": "netwrangler", "chain": "mangle-output", "handle": 10, "comment": "Output mark lookup", "expr": [{"mangle": {"key": {"meta": {"key": "mark"}}, "value": {"|": [{"&": [{"meta": {"key": "mark"}}, 4278255615]}, {"map": {"key": {"concat": [{"payload": {"protocol": "ip", "field": "saddr"}}, {"payload": {"protocol": "ip", "field": "daddr"}}]}, "data": "@ingress-marks-ipv4"}}]}}}, {"accept": null}]}
  JSON

# A rule of the agent before mark maps, which dispatched to mark chains
private LEGACY_RULE_JSON = <<-JSON
  {"family": "ip", "table": "netwrangler", "chain": "filter-prerouting", "handle": 16, "comment": "Ingress mark lookup for default route", "expr": [{"vmap": {"key": {"ct": {"key": "ip daddr", "dir": "original"}}, "data": "@ingress-marks-default-ipv4"}}]}
  JSON

private MASK = 0x00ff0000_u32

describe Netwrangler::Agent::MarkRuleDescriptor do
  describe "#expr" do
    it "matches the statements nft lists for the ingress rule" do
      Netwrangler::Agent::NftablesUpdater::INGRESS_MARK_RULE.expr(MASK).should eq(JSON.parse(INGRESS_RULE_JSON)["expr"])
    end

    it "matches the statements nft lists for a rule guarded by the gateway destinations" do
      Netwrangler::Agent::NftablesUpdater::EGRESS_DEFAULT_MARK_RULE.expr(MASK).should eq(JSON.parse(EGRESS_DEFAULT_RULE_JSON)["expr"])
    end

    it "matches the statements nft lists for the output rule" do
      Netwrangler::Agent::NftablesUpdater::INGRESS_OUTPUT_MARK_RULE.expr(MASK).should eq(JSON.parse(OUTPUT_RULE_JSON)["expr"])
    end

    it "keeps the bits outside the mask" do
      Netwrangler::Agent::NftablesUpdater::INGRESS_MARK_RULE.expr(0x0000007f_u32).should_not eq(JSON.parse(INGRESS_RULE_JSON)["expr"])
    end

    it "guards both egress rules and neither ingress rule" do
      Netwrangler::Agent::NftablesUpdater::EGRESS_MARK_RULE.exclude_set.should eq("gateway-destinations")
      Netwrangler::Agent::NftablesUpdater::EGRESS_DEFAULT_MARK_RULE.exclude_set.should eq("gateway-destinations")
      Netwrangler::Agent::NftablesUpdater::INGRESS_MARK_RULE.exclude_set.should be_nil
      Netwrangler::Agent::NftablesUpdater::INGRESS_DEFAULT_MARK_RULE.exclude_set.should be_nil
    end
  end

  describe "#references?" do
    it "finds a listed rule that looks up its map" do
      Netwrangler::Agent::NftablesUpdater::INGRESS_MARK_RULE.references?(JSON.parse(INGRESS_RULE_JSON)).should be_true
      Netwrangler::Agent::NftablesUpdater::INGRESS_OUTPUT_MARK_RULE.references?(JSON.parse(OUTPUT_RULE_JSON)).should be_true
    end

    it "ignores a rule that looks up another map" do
      Netwrangler::Agent::NftablesUpdater::INGRESS_DEFAULT_MARK_RULE.references?(JSON.parse(INGRESS_RULE_JSON)).should be_false
    end

    it "does not take the guard's set for a map" do
      rule = Netwrangler::Agent::MarkRuleDescriptor.new(
        map_name: "gateway-destinations", chain_name: "filter-prerouting",
        match_fields: [Netwrangler::Agent::NftMatchField::CtOriginalIpSaddr], comment: "x")
      rule.references?(JSON.parse(EGRESS_DEFAULT_RULE_JSON)).should be_false
    end
  end

  describe "#legacy?" do
    it "finds the verdict map rule of its map" do
      Netwrangler::Agent::NftablesUpdater::INGRESS_DEFAULT_MARK_RULE.legacy?(JSON.parse(LEGACY_RULE_JSON)).should be_true
    end

    it "ignores a mark rule and the verdict map rule of another map" do
      Netwrangler::Agent::NftablesUpdater::INGRESS_DEFAULT_MARK_RULE.legacy?(JSON.parse(EGRESS_DEFAULT_RULE_JSON)).should be_false
      Netwrangler::Agent::NftablesUpdater::INGRESS_MARK_RULE.legacy?(JSON.parse(LEGACY_RULE_JSON)).should be_false
    end
  end
end

# Objects and rules as nft 1.1.2 to 1.1.7 list them with `nft -j list table`
private GATEWAY_SET_JSON = <<-JSON
  {"family": "ip", "name": "gateway-destinations", "table": "netwrangler", "type": "ipv4_addr", "handle": 5, "comment": "VipGateway destinations excluded from egress marking", "flags": ["interval"], "auto-merge": true}
  JSON

private SNAT_MAP_JSON = <<-JSON
  {"family": "ip", "name": "snat-addresses", "table": "netwrangler", "type": ["mark", "ifname"], "handle": 6, "comment": "Firewall mark + outgoing interface to SNAT address", "map": "ipv4_addr", "elem": [[{"concat": [262144, "eth0"]}, "172.18.0.200"]]}
  JSON

private LEGACY_MAP_JSON = <<-JSON
  {"family": "ip", "name": "ingress-marks-ipv4", "table": "netwrangler", "type": ["ipv4_addr", "ipv4_addr"], "handle": 8, "comment": "VIP + source network to mark chain", "map": "verdict", "flags": ["interval"]}
  JSON

private CLUSTER_RULE_JSON = <<-JSON
  {"family": "ip", "table": "netwrangler", "chain": "filter-prerouting", "handle": 7, "comment": "Skip marking for cluster-internal traffic", "expr": [{"match": {"op": "==", "left": {"ct": {"key": "ip saddr", "dir": "original"}}, "right": "@cluster-networks"}}, {"match": {"op": "==", "left": {"ct": {"key": "ip daddr", "dir": "original"}}, "right": "@cluster-networks"}}, {"return": null}]}
  JSON

private CLUSTER_OUTPUT_RULE_JSON = <<-JSON
  {"family": "ip", "table": "netwrangler", "chain": "mangle-output", "handle": 8, "comment": "Skip marking for cluster-internal traffic", "expr": [{"match": {"op": "==", "left": {"payload": {"protocol": "ip", "field": "saddr"}}, "right": "@cluster-networks"}}, {"match": {"op": "==", "left": {"payload": {"protocol": "ip", "field": "daddr"}}, "right": "@cluster-networks"}}, {"return": null}]}
  JSON

# The SNAT rule as nft 1.1.2 lists it, with a single flag as a string; 1.1.7
# lists it as a list
private SNAT_RULE_1_1_2_JSON = <<-JSON
  {"family": "ip", "table": "netwrangler", "chain": "nat-postrouting", "handle": 9, "comment": "SNAT to VIP address by mark and interface", "expr": [{"snat": {"addr": {"map": {"key": {"concat": [{"&": [{"meta": {"key": "mark"}}, 16711680]}, {"meta": {"key": "oifname"}}]}, "data": "@snat-addresses"}}, "flags": "fully-random"}}]}
  JSON

private SNAT_RULE_1_1_7_JSON = <<-JSON
  {"family": "ip", "table": "netwrangler", "chain": "nat-postrouting", "handle": 9, "comment": "SNAT to VIP address by mark and interface", "expr": [{"snat": {"addr": {"map": {"key": {"concat": [{"&": [{"meta": {"key": "mark"}}, 16711680]}, {"meta": {"key": "oifname"}}]}, "data": "@snat-addresses"}}, "flags": ["fully-random"]}}]}
  JSON

describe Netwrangler::Agent::NftObjectDescriptor do
  describe "#to_json_object" do
    it "describes a concatenated mark map with an interval flag" do
      Netwrangler::Agent::NftablesUpdater::EGRESS_MAP.to_json_object(table: "netwrangler").to_json.should eq(
        %({"family":"ip","table":"netwrangler","name":"egress-marks-ipv4","type":["ipv4_addr","ipv4_addr"],) +
        %("map":"mark","flags":["interval"],"comment":"Endpoint + dest network to firewall mark"}))
    end

    it "describes a set with auto-merge" do
      Netwrangler::Agent::NftablesUpdater::GATEWAY_DESTINATIONS_SET.to_json_object(table: "netwrangler").to_json.should eq(
        %({"family":"ip","table":"netwrangler","name":"gateway-destinations","type":"ipv4_addr",) +
        %("flags":["interval"],"auto-merge":true,"comment":"VipGateway destinations excluded from egress marking"}))
    end
  end

  describe "#matches?" do
    it "accepts the listed objects it describes" do
      Netwrangler::Agent::NftablesUpdater::GATEWAY_DESTINATIONS_SET.matches?(JSON.parse(GATEWAY_SET_JSON)).should be_true
      Netwrangler::Agent::NftablesUpdater::SNAT_MAP.matches?(JSON.parse(SNAT_MAP_JSON)).should be_true
    end

    it "rejects the verdict map a mark map replaced" do
      Netwrangler::Agent::NftablesUpdater::INGRESS_MAP.matches?(JSON.parse(LEGACY_MAP_JSON)).should be_false
    end

    it "rejects an object whose flags differ" do
      Netwrangler::Agent::NftablesUpdater::CLUSTER_NETWORKS_SET.matches?(JSON.parse(GATEWAY_SET_JSON)).should be_false
    end
  end
end

describe Netwrangler::Agent::ClusterNetworksRuleDescriptor do
  describe "#expr" do
    it "matches the statements nft lists for both chains" do
      Netwrangler::Agent::NftablesUpdater::CLUSTER_PREROUTING_RULE.expr.should eq(JSON.parse(CLUSTER_RULE_JSON)["expr"])
      Netwrangler::Agent::NftablesUpdater::CLUSTER_OUTPUT_RULE.expr.should eq(JSON.parse(CLUSTER_OUTPUT_RULE_JSON)["expr"])
    end
  end

  describe "#references?" do
    it "finds the rule that matches against its set, not the egress guard" do
      Netwrangler::Agent::NftablesUpdater::CLUSTER_PREROUTING_RULE.references?(JSON.parse(CLUSTER_RULE_JSON)).should be_true
      Netwrangler::Agent::NftablesUpdater::CLUSTER_PREROUTING_RULE.references?(JSON.parse(EGRESS_DEFAULT_RULE_JSON)).should be_false
    end
  end
end

describe Netwrangler::Agent::SnatRuleDescriptor do
  describe "#expr" do
    it "matches the statements nft lists, whichever form the flag takes" do
      expected = Netwrangler::Agent::NftJson.normalize(Netwrangler::Agent::NftablesUpdater::SNAT_RULE.expr(MASK))

      Netwrangler::Agent::NftJson.normalize(JSON.parse(SNAT_RULE_1_1_2_JSON)["expr"]).should eq(expected)
      Netwrangler::Agent::NftJson.normalize(JSON.parse(SNAT_RULE_1_1_7_JSON)["expr"]).should eq(expected)
    end
  end

  describe "#references?" do
    it "finds the rule that looks up the SNAT map" do
      Netwrangler::Agent::NftablesUpdater::SNAT_RULE.references?(JSON.parse(SNAT_RULE_1_1_7_JSON)).should be_true
      Netwrangler::Agent::NftablesUpdater::SNAT_RULE.references?(JSON.parse(INGRESS_RULE_JSON)).should be_false
    end
  end
end

describe Netwrangler::Agent::NftJson do
  describe ".normalize" do
    it "writes a single flag as a list and leaves the rest alone" do
      Netwrangler::Agent::NftJson.normalize(JSON.parse(%({"snat": {"flags": "fully-random", "addr": "x"}}))).to_json
        .should eq(%({"snat":{"flags":["fully-random"],"addr":"x"}}))
    end
  end
end
