require "json"
require "../util/ipv4_network"
require "./gateway_policy"

module Netwrangler::Agent
  # Represents routing table configuration for a virtual IP
  record RouteTableInfo,
    route_table : Int32,
    virtual_ip : Util::IPv4Address,
    gateway_ip : Util::IPv4Address,
    network_cidr : Util::IPv4Network,
    source_cidrs : Array(Util::IPv4Network),
    firewall_mark : Int32,
    firewall_mark_mask : UInt32,
    routing_priority : Int32

  # Manages routing tables, policy rules, and default routes for virtual IPs
  class RoutesUpdater
    Log = ::Log.for(self)

    # Metric of the unreachable fallback route in a gateway table. Gateway pod
    # routes keep metric 0, so the kernel prefers them while one exists.
    UNREACHABLE_METRIC = 4_294_967_295_u32

    # Routing protocol number that tags every policy rule and route the agent
    # adds. Discovery treats only tagged rules as the agent's, so rules other
    # software installs are left alone. No rt_protos file names 110, so
    # iproute2 prints it as the number.
    PROTOCOL = "110"

    # A destination-based policy rule parsed from `ip --json rule show`. The
    # fwmark selector is kept as `ip rule show` prints it: `value/mask`, or the
    # value alone for a full mask.
    record DestinationRule, priority : Int32, destination : String, fwmark : String?, route_table : Int32,
      protocol : String? = nil do
      def managed? : Bool
        protocol == PROTOCOL
      end
    end

    # A route parsed from `ip --json route show table <t>`
    record ExistingRoute, destination : String, unreachable : Bool, protocol : String? = nil do
      def managed? : Bool
        protocol == PROTOCOL
      end
    end

    def initialize(@debug : Bool = false)
    end

    # Ensures desired policy rules and routes exist
    def add(interface : String, *, route_tables : Array(RouteTableInfo)) : Nil
      route_tables.each do |info|
        ensure_policy_rule(info.route_table, firewall_mark: info.firewall_mark, firewall_mark_mask: info.firewall_mark_mask, routing_priority: info.routing_priority)

        # Connected network route (no gateway)
        ensure_route(interface, destination: info.network_cidr, virtual_ip: info.virtual_ip, route_table: info.route_table)

        # Source network routes (via gateway)
        info.source_cidrs.each do |source_network|
          ensure_route(interface, destination: source_network, gateway_ip: info.gateway_ip, virtual_ip: info.virtual_ip, route_table: info.route_table)
        end

        remove_stale_routes(info)
      end
    end

    # Removes the VIP fwmark rules and flushes the tables of VIP route tables
    # that no interface wants. The policy rules are node-wide, so
    # +route_tables+ must hold the tables of every interface on the node. A
    # table an applied gateway uses keeps its gateway rule and routes; the
    # gateway sweep removes the VIP's routes from it.
    def remove(*, route_tables : Array(RouteTableInfo), gateway_tables : Set(Int32)) : Nil
      desired_tables = route_tables.map(&.route_table).to_set

      RoutesUpdater.stale_tables(discover_managed_rules.keys, desired_tables: desired_tables).each do |table|
        Log.info { "Removing stale policy rule for table #{table}" }
        remove_policy_rule(table)
        flush_route_table(table) unless gateway_tables.includes?(table)
      end
    end

    # The route tables that have a VIP policy rule on the node but are not desired
    def self.stale_tables(existing_tables : Array(Int32), *, desired_tables : Set(Int32)) : Array(Int32)
      existing_tables.reject { |table| desired_tables.includes?(table) }
    end

    # The policy rules `ip --json rule show` lists, all or those the
    # arguments select
    private def list_rules(args : Array(String) = [] of String) : String
      result = Util::Command.new(Util::IP, args: ["--json", "rule", "show"] + args, allowed_exit_codes: [0, 1]).run

      result.success? ? result.stdout : "[]"
    end

    # Discover managed policy rules
    # Returns a hash of {route_table => fwmark} for rules with fwmark
    private def discover_managed_rules : Hash(Int32, Int32)
      RoutesUpdater.parse_fwmark_rules(list_rules)
    end

    # The rules of an `ip --json rule show` listing
    def self.parse_rules(json : String) : Array(JSON::Any)
      return [] of JSON::Any if json.blank?

      Array(JSON::Any).from_json(json)
    end

    # Parses the agent's VIP fwmark rules into {route_table => fwmark}
    def self.parse_fwmark_rules(json : String) : Hash(Int32, Int32)
      rules = Hash(Int32, Int32).new
      parse_rules(json).each do |rule|
        next unless vip_rule?(rule)

        table = rule["table"].as_s.to_i?
        rules[table] = rule["fwmark"].as_s.to_i(prefix: true) if table
      end
      rules
    end

    # Whether a rule is one of the agent's VIP fwmark rules: tagged with its
    # protocol, from all sources to all destinations, not inverted, and
    # selecting a mark. A gateway rule has a destination and selects mark 0,
    # which `ip` prints without 0x.
    def self.vip_rule?(rule : JSON::Any) : Bool
      rule_protocol(rule) == PROTOCOL && rule["src"]?.try(&.as_s?) == "all" && rule["dst"]?.nil? &&
        !rule.as_h.has_key?("not") && rule["fwmark"]?.try(&.as_s?).try(&.starts_with?("0x")) == true
    end

    # The protocol of a rule, if any
    def self.rule_protocol(rule : JSON::Any) : String?
      rule["protocol"]?.try(&.as_s?)
    end

    # The fwmark selector of a rule as `ip rule show` prints it and `ip rule`
    # takes it: `value/mask`, or the value alone for a full mask
    def self.rule_fwmark(rule : JSON::Any) : String?
      fwmark = rule["fwmark"]?.try(&.as_s?)
      return if fwmark.nil?

      mask = rule["fwmask"]?.try(&.as_s?)
      mask ? "#{fwmark}/#{mask}" : fwmark
    end

    # Arguments for `ip rule add` for a VIP's fwmark rule
    def self.policy_rule_add_args(route_table : Int32, *, firewall_mark : Int32, firewall_mark_mask : UInt32,
                                  routing_priority : Int32) : Array(String)
      ["rule", "add", "fwmark", "0x#{firewall_mark.to_s(16)}/0x#{firewall_mark_mask.to_s(16)}",
       "table", route_table.to_s, "priority", routing_priority.to_s, "protocol", PROTOCOL]
    end

    private def ensure_policy_rule(route_table : Int32, *, firewall_mark : Int32, firewall_mark_mask : UInt32, routing_priority : Int32) : Nil
      fwmark_str = "0x#{firewall_mark.to_s(16)}/0x#{firewall_mark_mask.to_s(16)}"

      # Check if rule already exists
      rules = RoutesUpdater.parse_rules(list_rules(["fwmark", fwmark_str, "table", route_table.to_s]))

      return if rules.any? { |rule| RoutesUpdater.rule_protocol(rule) == PROTOCOL }

      # A rule from an agent version that did not tag its rules
      rules.each do
        Log.info { "Removing untagged policy rule: fwmark #{fwmark_str} table #{route_table}" }
        Util::Command.new(Util::IP, args: ["rule", "del", "fwmark", fwmark_str, "table", route_table.to_s],
          allowed_exit_codes: [0, 2]).run
      end

      Log.info { "Adding policy rule: fwmark #{fwmark_str} table #{route_table} priority #{routing_priority}" }
      Util::Command.new(Util::IP, args: RoutesUpdater.policy_rule_add_args(route_table,
        firewall_mark: firewall_mark, firewall_mark_mask: firewall_mark_mask, routing_priority: routing_priority)).run
    end

    # Removes the agent's VIP fwmark rules of a table, one by one, which also
    # handles duplicates left by earlier crashes. A gateway's `to` rule in the
    # same table stays.
    private def remove_policy_rule(route_table : Int32) : Nil
      RoutesUpdater.parse_rules(list_rules(["table", route_table.to_s])).each do |rule|
        next unless args = RoutesUpdater.vip_rule_delete_args(rule)

        Util::Command.new(Util::IP, args: args, allowed_exit_codes: [0, 2]).run
      end
    end

    # Arguments for `ip rule del` that select a VIP fwmark rule, or nil when
    # the rule is not one of the agent's VIP rules (a gateway rule, or a rule
    # of other software)
    def self.vip_rule_delete_args(rule : JSON::Any) : Array(String)?
      return unless vip_rule?(rule)

      ["rule", "del", "priority", rule["priority"].as_i.to_s, "fwmark", rule_fwmark(rule).to_s,
       "table", rule["table"].as_s, "protocol", PROTOCOL]
    end

    private def ensure_route(interface : String, *, destination : Util::IPv4Network, gateway_ip : Util::IPv4Address? = nil, virtual_ip : Util::IPv4Address, route_table : Int32) : Nil
      dest_str = route_destination(destination)

      return if route_exists?(dest_str, interface: interface, gateway_ip: gateway_ip,
                  virtual_ip: virtual_ip, route_table: route_table)

      args = build_route_args(dest_str, interface: interface, gateway_ip: gateway_ip,
        virtual_ip: virtual_ip, route_table: route_table)

      Log.info { "Setting route in table #{route_table}: #{dest_str}#{gateway_ip ? " via #{gateway_ip}" : ""} dev #{interface} src #{virtual_ip}" }
      Util::Command.new(Util::IP, args: args).run
    end

    private def route_exists?(dest_str : String, *, interface : String, gateway_ip : Util::IPv4Address?, virtual_ip : Util::IPv4Address, route_table : Int32) : Bool
      result = Util::Command.new(Util::IP, args: ["--json", "route", "show", "table", route_table.to_s, dest_str],
        allowed_exit_codes: [0, 1, 2, 255]).run

      return false if !result.success? || result.stdout.strip.empty? || result.stdout.strip == "[]"

      routes = Array(JSON::Any).from_json(result.stdout)
      existing = routes.find { |route| route["dst"]?.try(&.as_s?) == dest_str }
      return false unless existing

      gateway_matches = if gw = gateway_ip
                          existing["gateway"]?.try(&.as_s?) == gw.to_s
                        else
                          existing["gateway"]?.nil?
                        end

      existing["dev"]?.try(&.as_s?) == interface &&
        existing["prefsrc"]?.try(&.as_s?) == virtual_ip.to_s &&
        existing["protocol"]?.try(&.as_s?) == PROTOCOL &&
        gateway_matches
    end

    private def build_route_args(dest_str : String, *, interface : String, gateway_ip : Util::IPv4Address?, virtual_ip : Util::IPv4Address, route_table : Int32) : Array(String)
      args = ["route", "replace", dest_str]
      if gw = gateway_ip
        args += ["via", gw.to_s]
      end
      args + ["dev", interface, "src", virtual_ip.to_s, "table", route_table.to_s, "proto", PROTOCOL]
    end

    private def remove_stale_routes(info : RouteTableInfo) : Nil
      result = Util::Command.new(Util::IP, args: ["--json", "route", "show", "table", info.route_table.to_s],
        allowed_exit_codes: [0, 1, 2, 255]).run

      return if !result.success? || result.stdout.strip.empty? || result.stdout.strip == "[]"

      desired_destinations = Set(String).new
      desired_destinations << route_destination(info.network_cidr)
      info.source_cidrs.each { |source_network| desired_destinations << route_destination(source_network) }

      routes = Array(JSON::Any).from_json(result.stdout)
      routes.each do |route|
        dst = route["dst"]?.try(&.as_s?)
        next unless dst
        next if desired_destinations.includes?(dst)

        Log.info { "Removing stale route #{dst} from table #{info.route_table}" }
        Util::Command.new(Util::IP, args: ["route", "del", dst, "table", info.route_table.to_s],
          allowed_exit_codes: [0, 2]).run
      end
    end

    # Normalizes a network to the destination string used by ip route.
    # 0.0.0.0/0 becomes "default" to match ip --json output.
    private def route_destination(network : Util::IPv4Network) : String
      if network.prefix == 0
        "default"
      else
        network.to_s
      end
    end

    private def flush_route_table(route_table : Int32) : Nil
      Log.info { "Flushing route table #{route_table}" }
      Util::Command.new(Util::IP, args: ["route", "flush", "table", route_table.to_s],
        allowed_exit_codes: [0, 2]).run
    end

    # Ensures the gateway pod routes of the applied VipRoutes exist, using
    # pre-resolved pod routes
    def add_gateway_routes(resolved_routes : Array({VipRouteEntry, ResolvedPodRoute?})) : Nil
      resolved_routes.each do |entry, resolved|
        ensure_gateway_route(entry, resolved: resolved)
      end
    end

    # Removes gateway rules, fallbacks and pod routes that neither an applied
    # gateway nor one of its VipRoutes wants. +route_tables+ holds the tables
    # of every VipRoute, applied or not; +vip_route_tables+ the tables of the
    # VipAddresses on this node, which the sweep leaves alone.
    def remove_stale_gateway_routes(desired_routes : Array(VipRouteEntry), *, gateways : Array(GatewayRuleEntry),
                                    route_tables : Array(Int32), vip_route_tables : Set(Int32)) : Nil
      unicast_by_table = desired_routes.group_by(&.route_table)
      unreachable_by_table = gateways.group_by(&.route_table)
      desired_rules = gateways.map { |gateway| {gateway.destination_cidr.to_s, gateway.route_table} }.to_set

      existing_rules = discover_destination_rules
      tables = RoutesUpdater.gateway_sweep_tables(route_tables + unicast_by_table.keys,
        gateways: gateways, rules: existing_rules, vip_route_tables: vip_route_tables)

      tables.each do |table|
        unicast = unicast_by_table[table]?.try(&.map(&.destination_cidr.to_s).to_set) || Set(String).new
        unreachable = unreachable_by_table[table]?.try(&.map(&.destination_cidr.to_s).to_set) || Set(String).new
        remove_stale_table_routes(table, unicast: unicast, unreachable: unreachable)
      end

      existing_rules.each do |rule|
        next if desired_rules.includes?({rule.destination, rule.route_table})

        remove_gateway_rule(rule)
      end
    end

    # Ensures each applied gateway's policy rule and unreachable fallback exist
    def add_gateways(gateways : Array(GatewayRuleEntry), *, firewall_mark_mask : UInt32?) : Nil
      fwmark = RoutesUpdater.gateway_fwmark(firewall_mark_mask)
      gateways.each do |gateway|
        ensure_gateway_rule(gateway, fwmark: fwmark, firewall_mark_mask: firewall_mark_mask)
        ensure_unreachable_fallback(gateway)
      end
    end

    private def discover_destination_rules : Array(DestinationRule)
      RoutesUpdater.managed_destination_rules(list_rules)
    end

    private def remove_stale_table_routes(table : Int32, *, unicast : Set(String), unreachable : Set(String)) : Nil
      result = Util::Command.new(Util::IP, args: ["--json", "route", "show", "table", table.to_s],
        allowed_exit_codes: [0, 1, 2, 255]).run
      return if !result.success? || result.stdout.strip.empty? || result.stdout.strip == "[]"

      existing = RoutesUpdater.parse_routes(result.stdout)
      RoutesUpdater.stale_routes(existing, unicast: unicast, unreachable: unreachable).each do |route|
        Log.info { "Removing stale gateway #{route.unreachable ? "fallback" : "pod"} route #{route.destination} from table #{table}" }
        Util::Command.new(Util::IP, args: RoutesUpdater.route_delete_args(route, route_table: table),
          allowed_exit_codes: [0, 2]).run
      end
    end

    private def ensure_gateway_rule(gateway : GatewayRuleEntry, *, fwmark : String?, firewall_mark_mask : UInt32?) : Nil
      destination = gateway.destination_cidr.to_s
      existing = RoutesUpdater.parse_destination_rules(list_rules(["to", destination, "table", gateway.route_table.to_s]))
      change = RoutesUpdater.gateway_rule_change(existing, gateway, fwmark: fwmark)

      # The replacement goes in before the old rule goes, so the destination
      # never falls through to the main table in between
      if change[:add]
        args = RoutesUpdater.gateway_rule_add_args(gateway, firewall_mark_mask: firewall_mark_mask)
        Log.info { "Adding gateway policy rule: #{args[2..].join(" ")}" }
        Util::Command.new(Util::IP, args: args).run
      end

      change[:remove].each { |rule| remove_gateway_rule(rule) }
    end

    private def ensure_unreachable_fallback(gateway : GatewayRuleEntry) : Nil
      destination = gateway.destination_cidr.to_s
      table = gateway.route_table.to_s
      result = Util::Command.new(Util::IP, args: ["--json", "route", "show", "table", table, destination],
        allowed_exit_codes: [0, 1, 2, 255]).run

      if result.success? && !result.stdout.strip.empty?
        routes = RoutesUpdater.parse_routes(result.stdout)
        return if routes.any? { |route| route.unreachable && route.destination == destination && route.managed? }
      end

      Log.info { "Adding unreachable fallback #{destination} to table #{table}" }
      Util::Command.new(Util::IP, args: ["route", "replace", "unreachable", destination, "table", table,
                                         "metric", UNREACHABLE_METRIC.to_s, "proto", PROTOCOL]).run
    end

    # Removes one destination rule, selected by everything `ip rule show`
    # printed for it, so a replacement next to it stays
    private def remove_gateway_rule(rule : DestinationRule) : Nil
      args = RoutesUpdater.gateway_rule_delete_args(rule)
      Log.info { "Removing gateway rule: #{args[2..].join(" ")}" }
      Util::Command.new(Util::IP, args: args, allowed_exit_codes: [0, 2]).run
    end

    # --- Gateway helpers ---

    # The tables the gateway sweep judges: those of every VipRoute (a refused
    # gateway's table has no rule, but may still hold a pod route installed
    # before the refusal), of every applied gateway and of every destination
    # rule on the node. A reserved table such as main, or the table of a
    # VipAddress on this node, is never swept.
    def self.gateway_sweep_tables(route_tables : Array(Int32), *, gateways : Array(GatewayRuleEntry),
                                  rules : Array(DestinationRule), vip_route_tables : Set(Int32)) : Set(Int32)
      (route_tables + gateways.map(&.route_table) + rules.map(&.route_table))
        .reject { |table| GatewayPolicy.table_refusal(table, vip_route_tables: vip_route_tables) }
        .to_set
    end

    # Parses destination-based rules, the agent's and those of other software
    # alike, that look up a numbered table. `ip` lists a host destination
    # without its length.
    def self.parse_destination_rules(json : String) : Array(DestinationRule)
      parse_rules(json).compact_map do |rule|
        destination = rule["dst"]?.try(&.as_s?)
        table = rule["table"]?.try(&.as_s?).try(&.to_i?)
        next if destination.nil? || table.nil?

        length = rule["dstlen"]?.try(&.as_i?)
        DestinationRule.new(priority: rule["priority"].as_i, destination: normalize_destination(length ? "#{destination}/#{length}" : destination),
          fwmark: rule_fwmark(rule), route_table: table, protocol: rule_protocol(rule))
      end
    end

    # The destination rules the agent added: those tagged with its protocol
    def self.managed_destination_rules(json : String) : Array(DestinationRule)
      parse_destination_rules(json).select(&.managed?)
    end

    # The fwmark selector of a gateway rule as `ip rule show` displays it (for
    # comparison only, never as an `ip rule add` argument). The
    # rule matches packets that carry no VIP mark under the mask.
    def self.gateway_fwmark(mask : UInt32?) : String?
      return unless mask = gateway_mask(mask)

      mask == UInt32::MAX ? "0" : "0/0x#{mask.to_s(16)}"
    end

    # The mask of the gateway rule's fwmark selector, or nil for no selector.
    # A zero mask selects nothing, and `ip rule show` does not print it.
    def self.gateway_mask(mask : UInt32?) : UInt32?
      mask unless mask == 0
    end

    # Brings a destination printed by iproute2 into `IPv4Network#to_s` form:
    # host routes print as a bare address and the default route as "default".
    def self.normalize_destination(destination : String) : String
      return "0.0.0.0/0" if destination == "default"

      cidr = destination.includes?('/') ? destination : "#{destination}/32"
      Util::IPv4Network.parse(cidr).to_s
    rescue ArgumentError
      destination
    end

    # Arguments for `ip rule add` for a gateway. The selector always carries an
    # explicit mask: `fwmark 0` alone would match every packet.
    def self.gateway_rule_add_args(gateway : GatewayRuleEntry, *, firewall_mark_mask : UInt32?) : Array(String)
      args = ["rule", "add", "to", gateway.destination_cidr.to_s]
      if mask = gateway_mask(firewall_mark_mask)
        args += ["fwmark", "0/0x#{mask.to_s(16)}"]
      end
      args + ["table", gateway.route_table.to_s, "priority", gateway.routing_priority.to_s, "protocol", PROTOCOL]
    end

    # What brings the rules for a gateway's destination and table in line:
    # whether its rule must be added, and which other rules must go. One
    # matching rule is kept; every other rule for the destination and table
    # goes, untagged ones from earlier agent versions included.
    def self.gateway_rule_change(existing : Array(DestinationRule), gateway : GatewayRuleEntry, *,
                                 fwmark : String?) : NamedTuple(add: Bool, remove: Array(DestinationRule))
      remove = existing.dup
      kept = remove.index { |rule| gateway_rule_matches?(rule, gateway, fwmark: fwmark) }
      remove.delete_at(kept) if kept
      {add: kept.nil?, remove: remove}
    end

    # Arguments for `ip rule del` that select exactly one rule. A rule without
    # a protocol is selected without one; among rules that then match, the
    # kernel deletes the oldest, which is the one being replaced.
    def self.gateway_rule_delete_args(rule : DestinationRule) : Array(String)
      args = ["rule", "del", "priority", rule.priority.to_s, "to", rule.destination]
      if fwmark = rule.fwmark
        args += ["fwmark", fwmark]
      end
      args += ["table", rule.route_table.to_s]
      if protocol = rule.protocol
        args += ["protocol", protocol]
      end
      args
    end

    def self.gateway_rule_matches?(rule : DestinationRule, gateway : GatewayRuleEntry, *, fwmark : String?) : Bool
      rule.destination == gateway.destination_cidr.to_s &&
        rule.route_table == gateway.route_table &&
        rule.priority == gateway.routing_priority &&
        rule.fwmark == fwmark &&
        rule.managed?
    end

    # Parses the unicast and unreachable routes of a table, the only types
    # the agent adds. Other types, such as blackhole or prohibit routes, come
    # from other software and are left out, so no sweep ever touches them.
    def self.parse_routes(json : String) : Array(ExistingRoute)
      Array(JSON::Any).from_json(json).compact_map do |route|
        destination = route["dst"]?.try(&.as_s?)
        next unless destination

        type = route["type"]?.try(&.as_s?) || "unicast"
        next unless type.in?("unicast", "unreachable")

        ExistingRoute.new(destination: normalize_destination(destination), unreachable: type == "unreachable",
          protocol: route["protocol"]?.try(&.as_s?))
      end
    end

    def self.stale_routes(existing : Array(ExistingRoute), *, unicast : Set(String), unreachable : Set(String)) : Array(ExistingRoute)
      existing.reject do |route|
        wanted = route.unreachable ? unreachable : unicast
        wanted.includes?(route.destination)
      end
    end

    # A delete with metric 0 matches any metric, so a pod route is deleted by
    # type `unicast` and the fallback by type and metric.
    def self.route_delete_args(route : ExistingRoute, *, route_table : Int32) : Array(String)
      if route.unreachable
        ["route", "del", "unreachable", route.destination, "table", route_table.to_s, "metric", UNREACHABLE_METRIC.to_s]
      else
        ["route", "del", "unicast", route.destination, "table", route_table.to_s]
      end
    end

    # Result of resolving a route to a pod IP via `ip route get`. A local pod
    # has one of the node's own addresses, as a gateway pod on the host
    # network does, so the node itself is the gateway.
    record ResolvedPodRoute, gateway : String, dev : String, prefsrc : String, local : Bool = false

    # Resolves the route to a pod IP using `ip route get`.
    # Returns the next-hop gateway (may differ from pod_ip if routed
    # indirectly), outgoing device, and preferred source address.
    def resolve_pod_route(pod_ip : String) : ResolvedPodRoute?
      result = Util::Command.new(Util::IP, args: ["--json", "route", "get", pod_ip],
        allowed_exit_codes: [0, 1, 2]).run
      return unless result.success?

      RoutesUpdater.parse_pod_route(result.stdout, pod_ip: pod_ip)
    end

    # Parses `ip --json route get <pod IP>`. The next hop is the kernel's
    # gateway, or the pod itself when it is directly reachable. A local
    # address resolves to type "local" through lo.
    def self.parse_pod_route(json : String, *, pod_ip : String) : ResolvedPodRoute?
      return if json.blank?

      route = Array(JSON::Any).from_json(json).first?
      return unless route

      dev = route["dev"]?.try(&.as_s?)
      prefsrc = route["prefsrc"]?.try(&.as_s?)
      return unless dev && prefsrc

      gateway = route["gateway"]?.try(&.as_s?) || pod_ip
      local = route["type"]?.try(&.as_s?) == "local"

      ResolvedPodRoute.new(gateway: gateway, dev: dev, prefsrc: prefsrc, local: local)
    end

    private def ensure_gateway_route(entry : VipRouteEntry, *, resolved : ResolvedPodRoute?) : Nil
      unless resolved
        Log.warn { "Cannot resolve route to pod #{entry.pod_ip} for #{entry.destination_cidr}, skipping" }
        return
      end

      return if gateway_route_matches?(entry, resolved: resolved)

      args = ["route", "replace", entry.destination_cidr.to_s, "via", resolved.gateway,
              "dev", resolved.dev, "src", resolved.prefsrc, "table", entry.route_table.to_s, "proto", PROTOCOL]

      Log.info { "Setting gateway pod route: #{entry.destination_cidr} via #{resolved.gateway} dev #{resolved.dev} src #{resolved.prefsrc} table #{entry.route_table}" }
      Util::Command.new(Util::IP, args: args).run
    end

    private def gateway_route_matches?(entry : VipRouteEntry, *, resolved : ResolvedPodRoute) : Bool
      result = Util::Command.new(Util::IP, args: ["--json", "route", "show", "table", entry.route_table.to_s, entry.destination_cidr.to_s],
        allowed_exit_codes: [0, 1, 2, 255]).run

      return false if !result.success? || result.stdout.strip.empty? || result.stdout.strip == "[]"

      routes = Array(JSON::Any).from_json(result.stdout)
      routes.any? do |route|
        route["gateway"]?.try(&.as_s?) == resolved.gateway &&
          route["dev"]?.try(&.as_s?) == resolved.dev &&
          route["prefsrc"]?.try(&.as_s?) == resolved.prefsrc &&
          route["protocol"]?.try(&.as_s?) == PROTOCOL
      end
    end
  end
end
