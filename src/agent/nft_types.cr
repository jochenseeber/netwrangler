require "json"

require "../util/nft_version"

module Netwrangler::Agent
  # The oldest nft the agent's JSON round trip was verified against: the
  # verdict maps with concatenated interval keys, the per-VIP chains and
  # every other object and rule of its table load and list back the same
  # from 1.0.6 (Debian 12) on
  MINIMUM_NFT = Util::NftVersion.new(major: 1, minor: 0, patch: 6)

  # The first nft the agent declares its sets and maps through with typeof.
  # nft 1.1.3 and newer store a plain `type` in the set's userdata as an
  # expression that nft 1.0.6 has no parser for, so every nft 1.0.6 command
  # that loads sets crashes, kube-proxy's included; a typeof declaration of
  # real expressions stores what 1.0.6 itself writes. nft 1.1.1 and older
  # store a plain type safely and reject JSON typeof. 1.1.2 is untested and
  # gets typeof: should it reject it, the hook fails loudly instead of
  # breaking kube-proxy silently.
  TYPEOF_NFT = Util::NftVersion.new(major: 1, minor: 1, patch: 2)

  # The first nft verified to list a set or map declared with typeof by its
  # typeof declaration, which the migration of a table of plain types
  # relies on (`NftablesUpdater.plain_type_table?`). Should the untested
  # 1.1.2 list such an object plain, a migration from 1.1.2 on would delete
  # and rebuild the table on every run.
  TYPEOF_LISTED_NFT = Util::NftVersion.new(major: 1, minor: 1, patch: 3)

  # Helpers for nft's JSON format, which the agent uses for every nft command
  # and listing
  module NftJson
    # A Crystal literal (hashes, named tuples, arrays, strings, numbers, nil)
    # as JSON::Any
    def self.any(value) : JSON::Any
      JSON.parse(value.to_json)
    end

    # An expression in one spelling of the forms nft lists it in, for
    # comparing a listed rule with the agent's. Every single flag becomes a
    # list: nft 1.0.6 to 1.1.3 list one statement flag as a string
    # ("fully-random"), 1.1.7 as a list (["fully-random"]); both take the list
    # as input. Every `x & a | b` of constants a and b loses b's bits
    # from a, which does not change its value: the kernel keeps the mask
    # a & ~b and nft lists it with b's bits set again, so nft 1.0.6 to 1.1.3
    # list `meta mark & 0xff00ffff | 0x00040000` as
    # `meta mark & 0xff04ffff | 0x00040000`.
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

      canonical_bitwise(normalized)
    end

    private def self.canonical_bitwise(hash : Hash(String, JSON::Any)) : JSON::Any
      node = JSON::Any.new(hash)
      operands = hash["|"]?.try(&.as_a?) if hash.size == 1
      return node if operands.nil? || operands.size != 2

      conjunction = operands[0].as_h?.try(&.["&"]?).try(&.as_a?)
      return node if conjunction.nil? || conjunction.size != 2

      mask = conjunction[1].as_i64?
      bits = operands[1].as_i64?
      return node if mask.nil? || bits.nil?

      canonical = NftJson.any({"|": [{"&": [conjunction[0], mask & ~bits]}, bits]})

      canonical
    end

    # The chains that `goto` and `jump` verdicts anywhere in a node name, such
    # as the elements of a verdict map or the statements of a rule
    def self.chain_targets(node : JSON::Any) : Array(String)
      if array = node.as_a?
        return array.flat_map { |element| chain_targets(element) }
      end

      hash = node.as_h?
      return [] of String if hash.nil?

      hash.flat_map do |name, value|
        target = value.as_h?.try(&.["target"]?).try(&.as_s?) if name.in?("goto", "jump")
        target ? [target] : chain_targets(value)
      end
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
    Verdict

    # Converts to the nftables type name
    def to_nft : String
      case self
      when Ipv4Addr then "ipv4_addr"
      when Mark     then "mark"
      when Ifname   then "ifname"
      when Verdict  then "verdict"
      else               raise "Unknown NftDataType: #{self}"
      end
    end
  end

  # The expressions a set's or map's typeof declaration names for its key
  # and value, each standing for its plain type
  enum NftTypeofExpr
    IpDaddr
    IpSaddr
    MetaMark
    MetaOifname
    Verdict

    # The expression in nft's JSON format. A verdict value takes any verdict
    # expression; nft rejects `{"typeof": "verdict"}`.
    def to_json_expr : JSON::Any
      expr = case self
             when IpDaddr     then {payload: {protocol: "ip", field: "daddr"}}
             when IpSaddr     then {payload: {protocol: "ip", field: "saddr"}}
             when MetaMark    then {meta: {key: "mark"}}
             when MetaOifname then {meta: {key: "oifname"}}
             when Verdict     then {accept: nil}
             else                  raise "Unknown NftTypeofExpr: #{self}"
             end

      NftJson.any(expr)
    end

    # The plain type of the expression's value
    def data_type : NftDataType
      case self
      when IpDaddr, IpSaddr then NftDataType::Ipv4Addr
      when MetaMark         then NftDataType::Mark
      when MetaOifname      then NftDataType::Ifname
      when Verdict          then NftDataType::Verdict
      else                       raise "Unknown NftTypeofExpr: #{self}"
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

  # Describes a map or set managed by the agent. Its key and value are the
  # expressions of a typeof declaration, whose types make the plain one.
  class NftObjectDescriptor
    getter name : String
    getter kind : NftObjectKind
    getter key_exprs : Array(NftTypeofExpr)
    getter value_expr : NftTypeofExpr?
    getter? interval : Bool
    getter? auto_merge : Bool
    getter comment : String

    def initialize(*, @name : String, @kind : NftObjectKind,
                   @key_exprs : Array(NftTypeofExpr),
                   @value_expr : NftTypeofExpr? = nil,
                   @interval : Bool = false, @auto_merge : Bool = false,
                   @comment : String)
    end

    # Whether the agent declares sets and maps through this nft with typeof
    # rather than plain types (`TYPEOF_NFT`)
    def self.typeof?(nft_version : Util::NftVersion) : Bool
      nft_version >= TYPEOF_NFT
    end

    def nft_kind : String
      kind.map? ? "map" : "set"
    end

    # The plain types of the key, one per concatenated part
    def key_types : Array(NftDataType)
      key_exprs.map(&.data_type)
    end

    # The plain type of a map's value, nil for a set
    def value_type : NftDataType?
      value_expr.try(&.data_type)
    end

    # The arguments of `nft -j` that list the object alone, with its
    # elements but without any rule
    def list_arguments(table : String) : Array(String)
      ["list", nft_kind, "ip", table, name]
    end

    # The object in nft's JSON format, as `nft -j add` takes it: declared
    # with typeof through nft 1.1.2 and newer, with plain types before
    def to_json_object(*, table : String, nft_version : Util::NftVersion) : Hash(String, JSON::Any)
      declare_typeof = NftObjectDescriptor.typeof?(nft_version)
      object = {"family" => JSON::Any.new("ip"), "table" => JSON::Any.new(table), "name" => JSON::Any.new(name)}
      object["type"] = declare_typeof ? NftObjectDescriptor.typeof_json(key_exprs) : json_type
      value_expr.try do |value|
        object["map"] = declare_typeof ? NftObjectDescriptor.typeof_json([value]) : JSON::Any.new(value.data_type.to_nft)
      end
      object["flags"] = NftJson.any(["interval"]) if interval?
      object["auto-merge"] = JSON::Any.new(true) if auto_merge?
      object["comment"] = JSON::Any.new(comment)

      object
    end

    # Whether a listed object has this descriptor's type, value type and
    # flags. nftables cannot change those in place, so an object that differs
    # must be recreated. The type matches in either form nft lists it: plain
    # (nft 1.0.6 and 1.0.9 list an object declared with typeof so too) or as
    # the typeof declaration (1.1.3 and newer, for an object declared with
    # typeof). So does the value type, which every release verified lists
    # plain. The comment does not count, and neither does a missing
    # auto-merge: nft 1.0.6 and 1.0.9 do not list it, 1.1.3 does.
    def matches?(listed : JSON::Any) : Bool
      listed_flags = listed["flags"]?.try { |flags| flags.as_a? || [flags] } || [] of JSON::Any
      expected_flags = interval? ? ["interval"] : [] of String
      listed_auto_merge = listed["auto-merge"]?.try(&.as_bool?)

      listed["type"]?.in?(json_type, NftObjectDescriptor.typeof_json(key_exprs)) &&
        value_matches?(listed["map"]?) &&
        listed_flags.compact_map(&.as_s?).sort! == expected_flags &&
        (listed_auto_merge.nil? || listed_auto_merge == auto_merge?)
    end

    # A set lists no value; a map's value lists plain or as its typeof
    # declaration
    private def value_matches?(listed_value : JSON::Any?) : Bool
      value = value_expr
      return listed_value.nil? if value.nil?

      listed_value.in?(JSON::Any.new(value.data_type.to_nft), NftObjectDescriptor.typeof_json([value]))
    end

    # A single type as a string, a concatenation as a list, as nft lists them
    private def json_type : JSON::Any
      types = key_types.map(&.to_nft)
      types.size == 1 ? JSON::Any.new(types.first) : NftJson.any(types)
    end

    # A typeof declaration of a single expression or a concatenation, as nft
    # takes and lists it
    protected def self.typeof_json(exprs : Array(NftTypeofExpr)) : JSON::Any
      parts = exprs.map(&.to_json_expr)
      expr = parts.size == 1 ? parts.first : NftJson.any({concat: parts})

      JSON::Any.new({"typeof" => expr})
    end
  end

  # Describes a rule that sends a packet to the mark chain a verdict map holds
  # for the packet's key. The chain's rule accepts the packet, so the first
  # map holding the key wins; a key the map lacks falls through to the next
  # rule. With `exclude_set`, the rule skips packets whose original
  # destination is in that set.
  record MarkRuleDescriptor,
    map_name : String,
    chain_name : String,
    match_fields : Array(NftMatchField),
    comment : String,
    exclude_set : String? = nil do
    # The rule's statements in nft's JSON format, as `nft -j list` prints them:
    # <fields> vmap @map
    def expr : JSON::Any
      fields = match_fields.map(&.to_json_expr)
      key = fields.size == 1 ? fields.first : NftJson.any({concat: fields})

      statements = [] of JSON::Any
      exclude_set.try do |set|
        statements << NftJson.any({match: {op: "!=", left: NftMatchField::CtOriginalIpDaddr.to_json_expr, right: "@#{set}"}})
      end
      statements << NftJson.any({vmap: {key: key, data: "@#{map_name}"}})

      JSON::Any.new(statements)
    end

    # Whether a listed rule looks up this rule's map
    def references?(rule : JSON::Any) : Bool
      NftJson.map_references(rule["expr"], kind: "vmap").includes?("@#{map_name}")
    end
  end

  # Describes the regular chain the verdict map elements of a VIP go to. Its
  # one rule sets the firewall mark bits to the VIP's mark, keeps the others
  # and accepts the packet. Its operands are constants, which every nft
  # loads; a mark looked up from a map can be the operand of a bitwise or
  # only with a patched nft.
  record MarkChainDescriptor, mark : Int32 do
    PREFIX = "netwrangler-mark-"

    # The mark a chain's name carries, nil unless the name is a mark chain's:
    # the prefix and eight lower-case hex digits
    def self.mark?(chain_name : String) : Int32?
      digits = chain_name.lchop?(PREFIX)
      return if digits.nil? || !digits.matches?(/\A[0-9a-f]{8}\z/)

      mark = digits.to_i32?(16)

      mark
    end

    # A mark as eight lower-case hex digits, as chain names, log messages and
    # nft's listings write it
    def self.hex_digits(mark : Int32) : String
      mark.to_s(16).rjust(8, '0')
    end

    def name : String
      "#{PREFIX}#{MarkChainDescriptor.hex_digits(mark)}"
    end

    def comment : String
      "Set firewall mark 0x#{MarkChainDescriptor.hex_digits(mark)}"
    end

    # The rule's statements in nft's JSON format:
    # meta mark set meta mark & ~mask | mark accept
    def expr(mask : UInt32) : JSON::Any
      packet_mark = {meta: {key: "mark"}}

      NftJson.any([{mangle: {key: packet_mark, value: {"|": [{"&": [packet_mark, ~mask]}, mark]}}}, {accept: nil}])
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
