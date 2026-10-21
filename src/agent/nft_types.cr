require "json"

module Netwrangler::Agent
  # Helpers for nft's JSON format, which the agent uses for every nft command
  # and listing
  module NftJson
    # A Crystal literal (hashes, named tuples, arrays, strings, numbers, nil)
    # as JSON::Any
    def self.any(value) : JSON::Any
      JSON.parse(value.to_json)
    end

    # An expression with every single flag written as a list. nft 1.1.2 lists
    # one statement flag as a string ("fully-random"), later releases as a
    # list (["fully-random"]); both take the list as input.
    def self.normalize(node : JSON::Any) : JSON::Any
      if array = node.as_a?
        return JSON::Any.new(array.map { |element| normalize(element) })
      end

      hash = node.as_h?
      return node if hash.nil?

      normalized = hash.to_h do |name, value|
        flag = value.as_s? if name == "flags"
        {name, flag ? JSON::Any.new([value]) : normalize(value)}
      end

      JSON::Any.new(normalized)
    end

    # The maps that `map` or `vmap` lookups anywhere in an expression name
    def self.map_references(node : JSON::Any, *, kind : String) : Array(String)
      if array = node.as_a?
        return array.flat_map { |element| map_references(element, kind: kind) }
      end

      hash = node.as_h?
      return [] of String if hash.nil?

      hash.flat_map do |name, value|
        nested = map_references(value, kind: kind)
        data = value.as_h?.try(&.["data"]?).try(&.as_s?) if name == kind
        data ? [data] + nested : nested
      end
    end

    # The sets that the matches of a rule's statements look up
    def self.matched_sets(statements : JSON::Any) : Array(String)
      statements.as_a.compact_map do |statement|
        statement["match"]?.try(&.["right"]?).try(&.as_s?).try { |right| right if right.starts_with?("@") }
      end
    end
  end

  # Kind of nftables object (map or set)
  enum NftObjectKind
    Map
    Set
  end

  # nftables key/value type identifiers
  enum NftDataType
    Ipv4Addr
    Mark
    Ifname

    # Converts to the nftables type name
    def to_nft : String
      case self
      when Ipv4Addr then "ipv4_addr"
      when Mark     then "mark"
      when Ifname   then "ifname"
      else               raise "Unknown NftDataType: #{self}"
      end
    end
  end

  # nftables match field identifiers for rule expressions
  enum NftMatchField
    CtOriginalIpDaddr
    CtOriginalIpSaddr
    IpSaddr
    IpDaddr

    # Converts to the expression in nft's JSON format
    def to_json_expr : JSON::Any
      expr = case self
             when CtOriginalIpDaddr then {ct: {key: "ip daddr", dir: "original"}}
             when CtOriginalIpSaddr then {ct: {key: "ip saddr", dir: "original"}}
             when IpSaddr           then {payload: {protocol: "ip", field: "saddr"}}
             when IpDaddr           then {payload: {protocol: "ip", field: "daddr"}}
             else                        raise "Unknown NftMatchField: #{self}"
             end

      NftJson.any(expr)
    end
  end

  # Describes a map or set managed by the agent
  class NftObjectDescriptor
    getter name : String
    getter kind : NftObjectKind
    getter key_types : Array(NftDataType)
    getter value_type : NftDataType?
    getter? interval : Bool
    getter? auto_merge : Bool
    getter comment : String

    def initialize(*, @name : String, @kind : NftObjectKind,
                   @key_types : Array(NftDataType),
                   @value_type : NftDataType? = nil,
                   @interval : Bool = false, @auto_merge : Bool = false,
                   @comment : String)
    end

    def nft_kind : String
      kind.map? ? "map" : "set"
    end

    # The object in nft's JSON format, as `nft -j add` takes it
    def to_json_object(*, table : String) : Hash(String, JSON::Any)
      object = {"family" => JSON::Any.new("ip"), "table" => JSON::Any.new(table), "name" => JSON::Any.new(name)}
      object["type"] = json_type
      value_type.try { |value| object["map"] = JSON::Any.new(value.to_nft) }
      object["flags"] = NftJson.any(["interval"]) if interval?
      object["auto-merge"] = JSON::Any.new(true) if auto_merge?
      object["comment"] = JSON::Any.new(comment)

      object
    end

    # Whether a listed object has this descriptor's type, value type and
    # flags. nftables cannot change those in place, so an object that differs
    # must be recreated. The comment does not count.
    def matches?(listed : JSON::Any) : Bool
      listed_flags = listed["flags"]?.try { |flags| flags.as_a? || [flags] } || [] of JSON::Any
      expected_flags = interval? ? ["interval"] : [] of String

      listed["type"]? == json_type &&
        listed["map"]?.try(&.as_s?) == value_type.try(&.to_nft) &&
        listed_flags.compact_map(&.as_s?).sort! == expected_flags &&
        (listed["auto-merge"]?.try(&.as_bool?) || false) == auto_merge?
    end

    # A single type as a string, a concatenation as a list, as nft lists them
    private def json_type : JSON::Any
      types = key_types.map(&.to_nft)
      types.size == 1 ? JSON::Any.new(types.first) : NftJson.any(types)
    end
  end

  # Describes a rule that sets the firewall mark bits to the value a mark map
  # holds for the packet's key and accepts the packet, so the first matching
  # map wins. A key the map lacks skips the rule, accept included. With
  # `exclude_set`, the rule skips packets whose original destination is in
  # that set.
  record MarkRuleDescriptor,
    map_name : String,
    chain_name : String,
    match_fields : Array(NftMatchField),
    comment : String,
    exclude_set : String? = nil do
    # The rule's statements in nft's JSON format, as `nft -j list` prints them:
    # meta mark set meta mark & ~mask | (<fields> map @map) accept
    def expr(mask : UInt32) : JSON::Any
      fields = match_fields.map(&.to_json_expr)
      key = fields.size == 1 ? fields.first : NftJson.any({concat: fields})
      mark = {meta: {key: "mark"}}
      value = {"|": [{"&": [mark, ~mask]}, {map: {key: key, data: "@#{map_name}"}}]}

      statements = [] of JSON::Any
      exclude_set.try do |set|
        statements << NftJson.any({match: {op: "!=", left: NftMatchField::CtOriginalIpDaddr.to_json_expr, right: "@#{set}"}})
      end
      statements << NftJson.any({mangle: {key: mark, value: value}})
      statements << NftJson.any({accept: nil})

      JSON::Any.new(statements)
    end

    # Whether a listed rule looks up this rule's map
    def references?(rule : JSON::Any) : Bool
      NftJson.map_references(rule["expr"], kind: "map").includes?("@#{map_name}")
    end

    # Whether a listed rule is the verdict map rule this rule replaced
    def legacy?(rule : JSON::Any) : Bool
      NftJson.map_references(rule["expr"], kind: "vmap").includes?("@#{map_name}")
    end
  end

  # Describes a rule that ends the chain for packets whose fields all lie in
  # a set, so the mark rules after it skip them
  record ClusterNetworksRuleDescriptor,
    set_name : String,
    chain_name : String,
    match_fields : Array(NftMatchField),
    comment : String do
    # The rule's statements in nft's JSON format, as `nft -j list` prints them:
    # <field> @set <field> @set return
    def expr : JSON::Any
      matches = match_fields.map do |field|
        NftJson.any({match: {op: "==", left: field.to_json_expr, right: "@#{set_name}"}})
      end

      JSON::Any.new(matches + [NftJson.any({return: nil})])
    end

    # Whether a listed rule matches against this rule's set
    def references?(rule : JSON::Any) : Bool
      NftJson.matched_sets(rule["expr"]).includes?("@#{set_name}")
    end
  end

  # Describes the rule that source-NATs a new connection to the VIP whose mark
  # and outgoing interface the map pairs it with
  record SnatRuleDescriptor,
    map_name : String,
    chain_name : String,
    comment : String do
    # The rule's statements in nft's JSON format, as `nft -j list` prints them:
    # snat to meta mark & mask . oifname map @map fully-random
    def expr(mask : UInt32) : JSON::Any
      key = {concat: [{"&": [{meta: {key: "mark"}}, mask]}, {meta: {key: "oifname"}}]}

      NftJson.any([{snat: {addr: {map: {key: key, data: "@#{map_name}"}}, flags: ["fully-random"]}}])
    end

    def references?(rule : JSON::Any) : Bool
      NftJson.map_references(rule["expr"], kind: "map").includes?("@#{map_name}")
    end
  end
end
