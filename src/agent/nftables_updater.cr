require "json"

require "../util/ipv4_address"
require "../util/ipv4_network"
require "./nft_types"

module Netwrangler::Agent
  # Manages the mark maps, the per-VIP chains their elements go to, the rules
  # that look them up, and source NAT for virtual IP configuration. Every
  # command and listing uses nft's JSON
  # format (`nft -j`), so nothing depends on how nft prints its text.
  class NftablesUpdater
    Log          = ::Log.for(self)
    MANGLE_TABLE = "netwrangler-ipv4"
    MANGLE_CHAIN = "netwrangler-filter-prerouting"
    OUTPUT_CHAIN = "netwrangler-mangle-output"
    NAT_CHAIN    = "netwrangler-nat-postrouting"

    # The priority nft names `mangle`
    MANGLE_PRIORITY = -150

    # Object descriptors for maps and sets
    INGRESS_MAP = NftObjectDescriptor.new(
      name: "netwrangler-ingress-marks", kind: NftObjectKind::Map,
      key_exprs: [NftTypeofExpr::IpDaddr, NftTypeofExpr::IpSaddr],
      value_expr: NftTypeofExpr::Verdict, interval: true,
      comment: "VIP + source network to firewall mark chain")

    EGRESS_MAP = NftObjectDescriptor.new(
      name: "netwrangler-egress-marks", kind: NftObjectKind::Map,
      key_exprs: [NftTypeofExpr::IpDaddr, NftTypeofExpr::IpSaddr],
      value_expr: NftTypeofExpr::Verdict, interval: true,
      comment: "Endpoint + dest network to firewall mark chain")

    INGRESS_DEFAULT_MAP = NftObjectDescriptor.new(
      name: "netwrangler-ingress-marks-default", kind: NftObjectKind::Map,
      key_exprs: [NftTypeofExpr::IpDaddr],
      value_expr: NftTypeofExpr::Verdict,
      comment: "VIP to firewall mark chain for default route")

    EGRESS_DEFAULT_MAP = NftObjectDescriptor.new(
      name: "netwrangler-egress-marks-default", kind: NftObjectKind::Map,
      key_exprs: [NftTypeofExpr::IpDaddr],
      value_expr: NftTypeofExpr::Verdict,
      comment: "Endpoint to firewall mark chain for default route")

    SNAT_MAP = NftObjectDescriptor.new(
      name: "netwrangler-snat-addresses", kind: NftObjectKind::Map,
      key_exprs: [NftTypeofExpr::MetaMark, NftTypeofExpr::MetaOifname],
      value_expr: NftTypeofExpr::IpSaddr,
      comment: "Firewall mark + outgoing interface to SNAT address")

    CLUSTER_NETWORKS_SET = NftObjectDescriptor.new(
      name: "netwrangler-cluster-networks", kind: NftObjectKind::Set,
      key_exprs: [NftTypeofExpr::IpDaddr], interval: true,
      comment: "Cluster-internal networks excluded from marking")

    GATEWAY_DESTINATIONS_SET = NftObjectDescriptor.new(
      name: "netwrangler-gateway-destinations", kind: NftObjectKind::Set,
      key_exprs: [NftTypeofExpr::IpDaddr], interval: true, auto_merge: true,
      comment: "VipGateway destinations excluded from egress marking")

    # Every set and map of the table, in the order the agent creates them.
    # `remove_outdated_table` lists each by name: that loads neither rules
    # nor other tables' objects, and nft 1.1.1 and older reject
    # `list maps table`.
    SETS_AND_MAPS = [SNAT_MAP, CLUSTER_NETWORKS_SET, GATEWAY_DESTINATIONS_SET,
                     INGRESS_MAP, EGRESS_MAP, INGRESS_DEFAULT_MAP, EGRESS_DEFAULT_MAP]

    # The `nft -j` listing that tells the previous agent's table apart: the
    # ingress mark map alone, as nft before 1.1.2 aborts listing that table's
    # rules
    PREVIOUS_AGENT_TABLE_PROBE = INGRESS_MAP.list_arguments(MANGLE_TABLE)

    # Mark rule descriptors. The agent adds them in this order, and as the
    # mark chain a match goes to accepts, ingress wins over egress and
    # specific source networks over the default route.
    INGRESS_MARK_RULE = MarkRuleDescriptor.new(
      map_name: INGRESS_MAP.name, chain_name: MANGLE_CHAIN,
      match_fields: [NftMatchField::CtOriginalIpDaddr, NftMatchField::CtOriginalIpSaddr],
      comment: "Ingress mark lookup")

    EGRESS_MARK_RULE = MarkRuleDescriptor.new(
      map_name: EGRESS_MAP.name, chain_name: MANGLE_CHAIN,
      match_fields: [NftMatchField::CtOriginalIpSaddr, NftMatchField::CtOriginalIpDaddr],
      comment: "Egress mark lookup", exclude_set: GATEWAY_DESTINATIONS_SET.name)

    INGRESS_OUTPUT_MARK_RULE = MarkRuleDescriptor.new(
      map_name: INGRESS_MAP.name, chain_name: OUTPUT_CHAIN,
      match_fields: [NftMatchField::IpSaddr, NftMatchField::IpDaddr],
      comment: "Output mark lookup")

    INGRESS_DEFAULT_MARK_RULE = MarkRuleDescriptor.new(
      map_name: INGRESS_DEFAULT_MAP.name, chain_name: MANGLE_CHAIN,
      match_fields: [NftMatchField::CtOriginalIpDaddr],
      comment: "Ingress mark lookup for default route")

    EGRESS_DEFAULT_MARK_RULE = MarkRuleDescriptor.new(
      map_name: EGRESS_DEFAULT_MAP.name, chain_name: MANGLE_CHAIN,
      match_fields: [NftMatchField::CtOriginalIpSaddr],
      comment: "Egress mark lookup for default route", exclude_set: GATEWAY_DESTINATIONS_SET.name)

    INGRESS_DEFAULT_OUTPUT_MARK_RULE = MarkRuleDescriptor.new(
      map_name: INGRESS_DEFAULT_MAP.name, chain_name: OUTPUT_CHAIN,
      match_fields: [NftMatchField::IpSaddr],
      comment: "Output mark lookup for default route")

    # Cluster-networks rule descriptors
    CLUSTER_PREROUTING_RULE = ClusterNetworksRuleDescriptor.new(
      set_name: CLUSTER_NETWORKS_SET.name, chain_name: MANGLE_CHAIN,
      match_fields: [NftMatchField::CtOriginalIpSaddr, NftMatchField::CtOriginalIpDaddr],
      comment: "Skip marking for cluster-internal traffic")

    CLUSTER_OUTPUT_RULE = ClusterNetworksRuleDescriptor.new(
      set_name: CLUSTER_NETWORKS_SET.name, chain_name: OUTPUT_CHAIN,
      match_fields: [NftMatchField::IpSaddr, NftMatchField::IpDaddr],
      comment: "Skip marking for cluster-internal traffic")

    SNAT_RULE = SnatRuleDescriptor.new(
      map_name: SNAT_MAP.name, chain_name: NAT_CHAIN,
      comment: "SNAT to VIP address by mark and interface")

    # A mark map element: its key in nft's JSON format, as `nft -j list`
    # prints it, and the firewall mark whose chain it goes to
    record MarkMapEntry, key : JSON::Any, mark : Int32 do
      # An element of a specific-source map (address . network)
      def self.specific(ip : Util::IPv4Address, source_cidr : Util::IPv4Network, mark : Int32) : MarkMapEntry
        key = NftJson.any({concat: [JSON::Any.new(ip.to_s), NftablesUpdater.network_json(source_cidr)]})
        entry = MarkMapEntry.new(key: key, mark: mark)

        entry
      end

      # An element of a default map (address)
      def self.default(ip : Util::IPv4Address, mark : Int32) : MarkMapEntry
        entry = MarkMapEntry.new(key: JSON::Any.new(ip.to_s), mark: mark)

        entry
      end

      # The element as nft's JSON input takes it: the key and a goto to the
      # mark's chain
      def to_json_element : JSON::Any
        NftJson.any([key, {goto: {target: NftablesUpdater.mark_chain_name(mark)}}])
      end

      # The key in nft's text syntax, for log messages
      def key_text : String
        MarkMapEntry.text(key)
      end

      def mark_hex : String
        NftablesUpdater.mark_hex(mark)
      end

      protected def self.text(node : JSON::Any) : String
        object = node.as_h?
        return node.to_s if object.nil?

        if parts = object["concat"]?.try(&.as_a?)
          parts.map { |part| text(part) }.join(" . ")
        elsif prefix = object["prefix"]?
          "#{prefix["addr"]}/#{prefix["len"]}"
        else
          node.to_json
        end
      end
    end

    # Represents a desired SNAT map entry (mark . interface -> VIP address)
    record DesiredSnatEntry, mark : Int32, virtual_ip : Util::IPv4Address, interface : String do
      def key : JSON::Any
        NftJson.any({concat: [mark, interface]})
      end

      def to_json_element : JSON::Any
        JSON::Any.new([key, JSON::Any.new(virtual_ip.to_s)])
      end
    end

    # An SNAT map element as `nft -j list` prints it
    record ExistingSnatEntry, mark : Int32, interface : String, virtual_ip : String do
      def key : JSON::Any
        NftJson.any({concat: [mark, interface]})
      end
    end

    # +nft_version+ is the node's nft release, which decides how the sets and
    # maps are declared (`NftObjectDescriptor.typeof?`). +runner+ runs nft in
    # place of a process of its own, for specs.
    def initialize(*, @nft_version : Util::NftVersion, @runner : Util::ToolRunner? = nil, @debug : Bool = false)
    end

    def self.mark_hex(mark : Int32) : String
      "0x#{MarkChainDescriptor.hex_digits(mark)}"
    end

    # The name of the chain that sets a VIP's firewall mark,
    # `netwrangler-mark-<mark>` with eight lower-case hex digits
    def self.mark_chain_name(mark : Int32) : String
      MarkChainDescriptor.new(mark).name
    end

    # A network as `nft -j list` prints it in an interval set or map: without
    # host bits, and a single address as a plain address
    def self.network_json(network : Util::IPv4Network) : JSON::Any
      canonical = network.canonical
      return JSON::Any.new(canonical.address.to_s) if canonical.prefix == 32

      NftJson.any({prefix: {addr: canonical.address.to_s, len: canonical.prefix}})
    end

    # The objects of one kind, such as "rule" or "map", in an `nft -j` listing
    def self.json_objects(listing : String, kind : String) : Array(JSON::Any)
      items = JSON.parse(listing)["nftables"].as_a

      items.compact_map(&.[kind]?)
    end

    # The elements of a map in an `nft -j list map` listing, skipping any
    # whose value is not a goto to a mark chain
    def self.parse_mark_map_entries(listing : String) : Array(MarkMapEntry)
      map_elements(listing).compact_map do |key, value|
        target = value.as_h?.try(&.["goto"]?).try(&.as_h?).try(&.["target"]?).try(&.as_s?)
        mark = target.try { |name| MarkChainDescriptor.mark?(name) }
        MarkMapEntry.new(key: key, mark: mark) if mark
      end
    end

    # The mark chains in an `nft -j list table` listing that no map element
    # and no rule goes to
    def self.unreferenced_mark_chains(listing : String) : Array(String)
      users = JSON::Any.new(json_objects(listing, "map") + json_objects(listing, "rule"))
      referenced = NftJson.chain_targets(users).to_set

      json_objects(listing, "chain").compact_map do |chain|
        name = chain["name"].as_s
        name if MarkChainDescriptor.mark?(name) && !referenced.includes?(name)
      end
    end

    # Whether an `nft -j list map` listing of a mark map shows the table the
    # previous agent left: its mark maps map to marks, this agent's to
    # verdicts. The previous agent declared plain types, which every nft lists
    # plain, so a value listed as a typeof declaration is this agent's.
    def self.previous_agent_table?(listing : String) : Bool
      json_objects(listing, "map").any? do |map|
        value = map["map"]?.try(&.as_s?)
        !value.nil? && value != NftDataType::Verdict.to_nft
      end
    end

    # Whether the agent moves a table of plain types to typeof through nft
    # +nft_version+: from `TYPEOF_LISTED_NFT` on, which lists an object
    # declared with typeof by its declaration, so a rebuilt table no longer
    # looks outdated
    def self.migrates_plain_types?(nft_version : Util::NftVersion) : Bool
      nft_version >= TYPEOF_LISTED_NFT
    end

    # Whether a listing of sets or maps shows one declared with a plain type
    # that nft +nft_version+ must declare again with typeof. nft 1.1.3 and
    # newer list an object declared with typeof by its typeof declaration;
    # one they list with a plain type crashes nft 1.0.6 on the node. Through
    # nft 1.1.1 and older the agent declares plain types itself, which no nft
    # crashes on, and through the untested 1.1.2 it declares typeof but does
    # not migrate (`migrates_plain_types?`).
    def self.plain_type_table?(listing : String, nft_version : Util::NftVersion) : Bool
      return false unless NftablesUpdater.migrates_plain_types?(nft_version)

      (json_objects(listing, "set") + json_objects(listing, "map")).any? do |object|
        object["type"]?.try(&.as_h?).try(&.has_key?("typeof")) != true
      end
    end

    # The networks that lie inside no other of them, without host bits or
    # duplicates, in their order. An interval set rejects a network inside
    # another unless nft merges them, which needs auto-merge, and nft 1.0.6
    # and 1.0.9 do not keep auto-merge with the set.
    def self.outermost_networks(networks : Array(Util::IPv4Network)) : Array(Util::IPv4Network)
      canonical = networks.map(&.canonical).uniq!

      canonical.reject do |network|
        canonical.any? { |other| other.prefix < network.prefix && other.contains?(network.address) }
      end
    end

    # The elements of the SNAT map in an `nft -j list map` listing
    def self.parse_snat_entries(listing : String) : Array(ExistingSnatEntry)
      map_elements(listing).compact_map do |key, value|
        parts = key["concat"]?.try(&.as_a?)
        mark = parts.try(&.[0]?).try(&.as_i64?)
        interface = parts.try(&.[1]?).try(&.as_s?)
        virtual_ip = value.as_s?
        next if mark.nil? || interface.nil? || virtual_ip.nil?

        ExistingSnatEntry.new(mark: mark.to_i32, interface: interface, virtual_ip: virtual_ip)
      end
    end

    private def self.map_elements(listing : String) : Array({JSON::Any, JSON::Any})
      elements = json_objects(listing, "map").first?.try(&.["elem"]?).try(&.as_a?)
      return [] of {JSON::Any, JSON::Any} if elements.nil?

      elements.compact_map do |element|
        pair = element.as_a?
        {pair[0], pair[1]} if pair && pair.size == 2
      end
    end

    # The commands that flush a set and refill it with networks in one
    # transaction, so the set is never briefly empty
    def self.set_refill_commands(set : NftObjectDescriptor, networks : Array(Util::IPv4Network)) : Array(JSON::Any)
      object = {"family" => JSON::Any.new("ip"), "table" => JSON::Any.new(MANGLE_TABLE), "name" => JSON::Any.new(set.name)}
      commands = [NftJson.any({flush: {set: object}})]
      return commands if networks.empty?

      elements = outermost_networks(networks).map { |network| network_json(network) }
      commands << NftJson.any({add: {element: object.merge({"elem" => JSON::Any.new(elements)})}})

      commands
    end

    # Deletes an outdated netwrangler-ipv4 table in one transaction; the rest
    # of the run rebuilds it. nftables cannot change an object in place nor
    # delete a map that rules use, so the whole table goes. A table is
    # outdated when
    #
    # - the previous agent left it: its mark maps map to marks, and its mark
    #   rules combine the packet's mark with a mark looked up from a map. nft
    #   before 1.1.2 aborts listing such a rule, so this looks only at the
    #   ingress mark map, which lists without the rules.
    # - nft 1.1.3 or newer runs on the node and declared a set or map with a
    #   plain type, which crashes nft 1.0.6 on the node, kube-proxy's
    #   included (`TYPEOF_NFT`, `TYPEOF_LISTED_NFT`). It lists each set and
    #   map by name, the ingress mark map once for both checks.
    #
    # It must run before anything else in a run lists the table's rules.
    def remove_outdated_table : Nil
      reason = outdated_table_reason
      return if reason.nil?

      Log.info { "Deleting table #{MANGLE_TABLE}, #{reason}; this run rebuilds it" }
      run_json([NftJson.any({delete: {table: {family: "ip", name: MANGLE_TABLE}}})])
    rescue ex
      raise Exception.new("Error removing an outdated #{MANGLE_TABLE} table: #{ex.message}", cause: ex)
    end

    # Why the table is outdated, nil when it is not
    private def outdated_table_reason : String?
      ingress_listing = listing(PREVIOUS_AGENT_TABLE_PROBE)
      return "which the previous agent left with mark maps of marks" if NftablesUpdater.previous_agent_table?(ingress_listing)
      return unless NftablesUpdater.migrates_plain_types?(@nft_version)

      plain = SETS_AND_MAPS.find do |descriptor|
        object_listing = descriptor == INGRESS_MAP ? ingress_listing : listing(descriptor.list_arguments(MANGLE_TABLE))
        NftablesUpdater.plain_type_table?(object_listing, @nft_version)
      end
      return if plain.nil?

      "whose #{plain.nft_kind} #{plain.name} has a plain type, which crashes nft 1.0.6 on the node; nft #{@nft_version} declares typeof"
    end

    # Ensures each mark has its chain, holding the one rule that sets the
    # mark under the mask. A map element can go only to a chain that exists,
    # so this runs before `add_marks`.
    def add_mark_chains(marks : Enumerable(Int32), *, mask : UInt32) : Nil
      listing = table_listing
      chains = NftablesUpdater.json_objects(listing, "chain").map(&.["name"].as_s).to_set
      rules_by_chain = NftablesUpdater.json_objects(listing, "rule").group_by(&.["chain"].as_s)

      marks.to_set.to_a.sort!.each do |mark|
        chain = MarkChainDescriptor.new(mark)
        if chains.includes?(chain.name)
          ensure_listed_rule(chain.name, rules_by_chain[chain.name]? || [] of JSON::Any, chain.expr(mask), comment: chain.comment)
        else
          create_mark_chain(chain, mask: mask)
        end
      end
    rescue ex
      raise Exception.new("Error adding mark chains: #{ex.message}", cause: ex)
    end

    # Deletes the mark chains that no map element goes to any more. Runs
    # after `add_marks`, which moves the elements of a VIP whose mark changed
    # to the new mark's chain; a chain an element still goes to cannot be
    # deleted.
    def remove_mark_chains : Nil
      stale = NftablesUpdater.unreferenced_mark_chains(table_listing)
      return if stale.empty?

      commands = stale.flat_map do |name|
        Log.info { "Deleting chain #{MANGLE_TABLE}/#{name}" }
        chain = table_object({"name" => JSON::Any.new(name)})
        [NftJson.any({flush: {chain: chain}}), NftJson.any({delete: {chain: chain}})]
      end
      run_json(commands)
    rescue ex
      raise Exception.new("Error removing mark chains: #{ex.message}", cause: ex)
    end

    # Ensures a mark map holds the desired elements and that its rules look
    # it up. The chains the elements go to must exist (`add_mark_chains`).
    def add_marks(map : NftObjectDescriptor, *, rules : Array(MarkRuleDescriptor),
                  desired_entries : Array(MarkMapEntry)) : Nil
      ensure_infrastructure
      ensure_nft_object(map)
      sync_mark_map(map.name, desired_entries)
      rules.each { |rule| ensure_rule(rule.chain_name, rule.expr, comment: rule.comment) { |listed| rule.references?(listed) } }
    rescue ex
      raise Exception.new("Error adding marks for #{map.name}: #{ex.message}", cause: ex)
    end

    # Removes mark map elements not in the desired set.
    def remove_marks(map : NftObjectDescriptor, *, desired_entries : Array(MarkMapEntry)) : Nil
      desired_keys = desired_entries.map(&.key).to_set

      discover_mark_map_entries(map.name).each do |entry|
        next if desired_keys.includes?(entry.key)

        Log.info { "Removing map entry #{entry.key_text} => #{entry.mark_hex} from #{map.name}" }
        delete_element(map.name, entry.key)
      end
    rescue ex
      raise Exception.new("Error removing marks for #{map.name}: #{ex.message}", cause: ex)
    end

    # --- SNAT map methods (mark -> ipv4_addr data map for source NAT) ---

    # Ensures SNAT map entries and the SNAT rule exist.
    def add_snat(*, desired_entries : Array(DesiredSnatEntry),
                 mask : UInt32) : Nil
      return if desired_entries.empty?

      sync_snat_map(desired_entries)
      ensure_rule(SNAT_RULE.chain_name, SNAT_RULE.expr(mask), comment: SNAT_RULE.comment) { |listed| SNAT_RULE.references?(listed) }
    rescue ex
      raise Exception.new("Error adding SNAT entries: #{ex.message}", cause: ex)
    end

    # Removes SNAT map entries not in the desired set.
    def remove_snat(*, desired_entries : Array(DesiredSnatEntry)) : Nil
      desired_keys = desired_entries.map(&.key).to_set

      discover_snat_entries.each do |entry|
        next if desired_keys.includes?(entry.key)

        Log.info { "Removing SNAT map entry #{NftablesUpdater.mark_hex(entry.mark)} . #{entry.interface} => #{entry.virtual_ip}" }
        delete_element(SNAT_MAP.name, entry.key)
      end
    rescue ex
      raise Exception.new("Error removing SNAT entries: #{ex.message}", cause: ex)
    end

    # --- Cluster network exclusion methods ---

    # Syncs netwrangler-cluster-networks set and ensures return rules exist.
    def sync_cluster_networks(*, addresses : Array(String)) : Nil
      networks = addresses.map { |address| Util::IPv4Network.parse(address) }
      Log.info { "Populating netwrangler-cluster-networks set: #{addresses.join(", ")}" } unless networks.empty?
      run_json(NftablesUpdater.set_refill_commands(CLUSTER_NETWORKS_SET, networks))

      [CLUSTER_PREROUTING_RULE, CLUSTER_OUTPUT_RULE].each do |rule|
        if networks.empty?
          delete_rules(rule.chain_name) { |listed| rule.references?(listed) }
        else
          ensure_rule(rule.chain_name, rule.expr, comment: rule.comment, insert: true) { |listed| rule.references?(listed) }
        end
      end
    rescue ex
      raise Exception.new("Error syncing cluster networks: #{ex.message}", cause: ex)
    end

    # --- Gateway destination exclusion methods ---

    # Replaces the netwrangler-gateway-destinations set contents in one transaction, so
    # egress to a gateway destination is never briefly unguarded.
    def sync_gateway_destinations(*, destinations : Array(Util::IPv4Network)) : Nil
      ensure_infrastructure
      run_json(NftablesUpdater.set_refill_commands(GATEWAY_DESTINATIONS_SET, destinations))
    rescue ex
      raise Exception.new("Error syncing gateway destinations: #{ex.message}", cause: ex)
    end

    # --- Private helpers ---

    private def ensure_infrastructure : Nil
      run_json([NftJson.any({add: {table: {family: "ip", name: MANGLE_TABLE}}})])
      ensure_base_chain(MANGLE_CHAIN, type: "filter", hook: "prerouting", priority: MANGLE_PRIORITY)
      ensure_base_chain(OUTPUT_CHAIN, type: "route", hook: "output", priority: MANGLE_PRIORITY)
      ensure_base_chain(NAT_CHAIN, type: "nat", hook: "postrouting", priority: 90)
      ensure_nft_object(SNAT_MAP)
      ensure_nft_object(CLUSTER_NETWORKS_SET)
      ensure_nft_object(GATEWAY_DESTINATIONS_SET)
    end

    private def ensure_base_chain(name : String, *, type : String, hook : String, priority : Int32) : Nil
      return unless list_json(["list", "chain", "ip", MANGLE_TABLE, name], "chain").empty?

      Log.info { "Creating chain #{MANGLE_TABLE}/#{name}" }
      chain = table_object({
        "name" => JSON::Any.new(name), "type" => JSON::Any.new(type), "hook" => JSON::Any.new(hook),
        "prio" => JSON::Any.new(priority.to_i64), "policy" => JSON::Any.new("accept"),
      })
      run_json([NftJson.any({add: {chain: chain}})])
    end

    # --- JSON command helpers ---

    # The objects of one kind in an `nft -j list ...` listing, or none when
    # the listed object does not exist
    private def list_json(args : Array(String), kind : String) : Array(JSON::Any)
      NftablesUpdater.json_objects(listing(args), kind)
    end

    # An `nft -j list ...` listing, empty when the listed object does not
    # exist
    private def listing(args : Array(String)) : String
      command = Util::Command.new(Util::NFT, args: ["-j"] + args, allowed_exit_codes: [0, 1], runner: @runner)

      self.class.listing_output(command, command.run)
    end

    # The listing of a result, empty when nft says the object does not exist.
    # Exit 1 is nft's code for every error, so only its message tells a
    # missing object from a rejected command; anything else raises.
    def self.listing_output(command : Util::Command, result : Util::Result) : String
      return result.stdout if result.success?
      return %({"nftables": []}) if result.exit_code == 1 && result.stderr.includes?("No such file or directory")

      raise Util::CommandError.new(command, result)
    end

    # The whole netwrangler-ipv4 table: objects, chains, rules and elements
    private def table_listing : String
      listing(["list", "table", "ip", MANGLE_TABLE])
    end

    # Runs commands in one nft invocation, which nftables applies as one
    # transaction
    private def run_json(commands : Array(JSON::Any), *, allowed_exit_codes : Array(Int32) = [0]) : Nil
      Util::Command.new(Util::NFT, args: ["-j", {nftables: commands}.to_json], allowed_exit_codes: allowed_exit_codes, runner: @runner).run
    end

    # The family and table of every object the agent manages, plus its own fields
    private def table_object(fields : Hash(String, JSON::Any)) : Hash(String, JSON::Any)
      {"family" => JSON::Any.new("ip"), "table" => JSON::Any.new(MANGLE_TABLE)}.merge(fields)
    end

    private def element_command(verb : String, map_name : String, elements : Array(JSON::Any)) : JSON::Any
      element = table_object({"name" => JSON::Any.new(map_name), "elem" => JSON::Any.new(elements)})

      JSON::Any.new({verb => JSON::Any.new({"element" => JSON::Any.new(element)})})
    end

    private def delete_element(map_name : String, key : JSON::Any) : Nil
      run_json([element_command("delete", map_name, [key])], allowed_exit_codes: [0, 1])
    end

    # Adds a missing element, or changes an existing one by deleting and
    # adding it in one transaction, so the key never goes without a value
    private def put_element(map_name : String, key : JSON::Any, element : JSON::Any, *, replace : Bool) : Nil
      commands = [element_command("add", map_name, [element])]
      commands.unshift(element_command("delete", map_name, [key])) if replace

      run_json(commands)
    end

    # --- Nft object helpers (maps and sets) ---

    private def ensure_nft_object(descriptor : NftObjectDescriptor) : Nil
      kind = descriptor.nft_kind
      listed = list_json(descriptor.list_arguments(MANGLE_TABLE), kind).first?
      return if listed && descriptor.matches?(listed)

      object = table_object({"name" => JSON::Any.new(descriptor.name)})
      if listed
        Log.info { "Recreating #{kind} #{MANGLE_TABLE}/#{descriptor.name} (type mismatch)" }
        run_json([JSON::Any.new({"flush" => JSON::Any.new({kind => JSON::Any.new(object)})}),
                  JSON::Any.new({"delete" => JSON::Any.new({kind => JSON::Any.new(object)})})], allowed_exit_codes: [0, 1])
      end

      Log.info { "Creating #{kind} #{MANGLE_TABLE}/#{descriptor.name}" }
      definition = JSON::Any.new(descriptor.to_json_object(table: MANGLE_TABLE, nft_version: @nft_version))
      run_json([JSON::Any.new({"add" => JSON::Any.new({kind => definition})})])
    end

    # Creates a mark chain and its rule in one transaction, so the chain is
    # never empty
    private def create_mark_chain(chain : MarkChainDescriptor, *, mask : UInt32) : Nil
      Log.info { "Creating chain #{MANGLE_TABLE}/#{chain.name}" }
      run_json([
        NftJson.any({add: {table: {family: "ip", name: MANGLE_TABLE}}}),
        NftJson.any({add: {chain: table_object({"name" => JSON::Any.new(chain.name)})}}),
        NftJson.any({add: {rule: rule_object(chain.name, chain.expr(mask), comment: chain.comment)}}),
      ])
    end

    # --- Map element helpers ---

    private def discover_mark_map_entries(map_name : String) : Array(MarkMapEntry)
      NftablesUpdater.parse_mark_map_entries(listing(["list", "map", "ip", MANGLE_TABLE, map_name]))
    end

    private def sync_mark_map(map_name : String, desired_entries : Array(MarkMapEntry)) : Nil
      existing_by_key = discover_mark_map_entries(map_name).index_by(&.key)

      desired_entries.uniq(&.key).each do |desired|
        existing = existing_by_key[desired.key]?
        next if existing && existing.mark == desired.mark

        if existing
          Log.info { "Updating map entry #{desired.key_text} in #{map_name}: #{existing.mark_hex} => #{desired.mark_hex}" }
        else
          Log.info { "Adding map entry #{desired.key_text} => #{desired.mark_hex} to #{map_name}" }
        end
        put_element(map_name, desired.key, desired.to_json_element, replace: !existing.nil?)
      end
    end

    private def discover_snat_entries : Array(ExistingSnatEntry)
      NftablesUpdater.parse_snat_entries(listing(["list", "map", "ip", MANGLE_TABLE, SNAT_MAP.name]))
    end

    private def sync_snat_map(desired_entries : Array(DesiredSnatEntry)) : Nil
      existing_by_key = discover_snat_entries.index_by(&.key)

      desired_entries.each do |desired|
        existing = existing_by_key[desired.key]?
        next if existing && existing.virtual_ip == desired.virtual_ip.to_s

        mark_hex = NftablesUpdater.mark_hex(desired.mark)
        if existing
          Log.info { "Updating SNAT entry #{mark_hex} . #{desired.interface}: #{existing.virtual_ip} => #{desired.virtual_ip}" }
        else
          Log.info { "Adding SNAT entry: #{mark_hex} . #{desired.interface} => #{desired.virtual_ip}" }
        end
        put_element(SNAT_MAP.name, desired.key, desired.to_json_element, replace: !existing.nil?)
      end
    end

    # --- Rule helpers ---

    private def chain_rules(chain_name : String) : Array(JSON::Any)
      list_json(["list", "chain", "ip", MANGLE_TABLE, chain_name], "rule")
    end

    private def rule_object(chain_name : String, expr : JSON::Any, *, comment : String, handle : Int64? = nil) : JSON::Any
      object = table_object({
        "chain" => JSON::Any.new(chain_name), "comment" => JSON::Any.new(comment), "expr" => expr,
      })
      object["handle"] = JSON::Any.new(handle) if handle

      JSON::Any.new(object)
    end

    # Ensures one rule the block recognizes holds the statements and comment:
    # adds it at the end of the chain, or at the top with +insert+, or
    # replaces a differing one in place so that the rules keep their order.
    # Duplicates go.
    private def ensure_rule(chain_name : String, expr : JSON::Any, *, comment : String, insert : Bool = false,
                            & : JSON::Any -> Bool) : Nil
      matching = chain_rules(chain_name).select { |listed| yield listed }
      ensure_listed_rule(chain_name, matching, expr, comment: comment, insert: insert)
    end

    # Ensures one of the matching rules, those of the chain a caller listed
    # and recognizes, holds the statements and comment, as `ensure_rule`
    # describes
    private def ensure_listed_rule(chain_name : String, matching : Array(JSON::Any), expr : JSON::Any, *,
                                   comment : String, insert : Bool = false) : Nil
      if matching.empty?
        Log.info { "Adding rule \"#{comment}\" to #{chain_name}" }
        run_json([JSON::Any.new({(insert ? "insert" : "add") => JSON::Any.new({"rule" => rule_object(chain_name, expr, comment: comment)})})])
        return
      end

      current, *duplicates = matching
      duplicates.each { |duplicate| delete_rule(chain_name, duplicate["handle"].as_i64) }
      return if NftJson.normalize(current["expr"]) == NftJson.normalize(expr) && current["comment"]?.try(&.as_s?) == comment

      handle = current["handle"].as_i64
      Log.info { "Replacing rule \"#{comment}\" (handle #{handle}) in #{chain_name}" }
      run_json([NftJson.any({replace: {rule: rule_object(chain_name, expr, comment: comment, handle: handle)}})])
    end

    # Deletes every rule of a chain the block recognizes
    private def delete_rules(chain_name : String, & : JSON::Any -> Bool) : Nil
      chain_rules(chain_name).each do |listed|
        next unless yield listed

        handle = listed["handle"].as_i64
        Log.info { "Deleting rule \"#{listed["comment"]?}\" (handle #{handle}) from #{chain_name}" }
        delete_rule(chain_name, handle)
      end
    end

    private def delete_rule(chain_name : String, handle : Int64) : Nil
      rule = table_object({"chain" => JSON::Any.new(chain_name), "handle" => JSON::Any.new(handle)})
      run_json([NftJson.any({delete: {rule: rule}})], allowed_exit_codes: [0, 1])
    end
  end
end
