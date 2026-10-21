require "json"
require "../util/ipv4_address"
require "../util/ipv4_network"
require "../util/binding_context"

module Netwrangler::Agent
  # A VipGateway the agent applies on this node. The destination is canonical.
  record GatewayRuleEntry,
    name : String,
    destination_cidr : Util::IPv4Network,
    route_table : Int32,
    routing_priority : Int32

  # Decides which VipGateways the agent applies on a node, and which VIP
  # source networks conflict with them. Holds no state and runs no commands.
  module GatewayPolicy
    # The gateways to apply, and one error message per refused gateway
    record Selection, applied : Array(GatewayRuleEntry), errors : Array(String)

    # Route tables the kernel defines: unspec, default, main and local
    RESERVED_ROUTE_TABLES = Set{0, 253, 254, 255}

    # Priority of the kernel's main table rule. A gateway rule at or after it
    # never wins against main.
    MAIN_RULE_PRIORITY = 32766

    # Parses the gateway snapshots and refuses those whose destination does
    # not parse or overlaps a cluster or node network, whose route table is
    # reserved or used by a VipAddress on this node, whose priority does not
    # come before main, or whose destination and table another gateway shares.
    # +node_networks+ holds each node address with its prefix length.
    def self.select_gateways(snapshots : Array(Util::VipGatewaySnapshot), *,
                             cluster_cidrs : Array(String),
                             node_networks : Array(Util::IPv4Network),
                             vip_route_tables : Set(Int32)) : Selection
      cluster_networks = cluster_cidrs.map { |cidr| parse_cluster_network(cidr) }
      candidates = [] of GatewayRuleEntry
      errors = [] of String

      snapshots.each do |snapshot|
        destination = parse_destination(snapshot.destination_cidr)
        unless destination
          errors << "Refusing VipGateway #{snapshot.name}: invalid destinationCIDR '#{snapshot.destination_cidr}'"
          next
        end

        gateway = GatewayRuleEntry.new(name: snapshot.name, destination_cidr: destination,
          route_table: snapshot.route_table, routing_priority: snapshot.routing_priority)

        if reason = refusal_reason(gateway, cluster_networks: cluster_networks,
             node_networks: node_networks, vip_route_tables: vip_route_tables)
          errors << "Refusing VipGateway #{gateway.name}: #{reason}"
          next
        end

        candidates << gateway
      end

      unique = reject_duplicates(candidates)
      Selection.new(applied: unique.applied, errors: errors + unique.errors)
    end

    # Returns why a gateway must not be applied on this node, or nil when it is safe.
    def self.refusal_reason(gateway : GatewayRuleEntry, *,
                            cluster_networks : Array(Util::IPv4Network),
                            node_networks : Array(Util::IPv4Network),
                            vip_route_tables : Set(Int32)) : String?
      destination_refusal(gateway.destination_cidr, cluster_networks: cluster_networks, node_networks: node_networks) ||
        table_refusal(gateway.route_table, vip_route_tables: vip_route_tables) ||
        priority_refusal(gateway.routing_priority)
    end

    # Returns why a gateway must not route a destination on this node, or nil.
    def self.destination_refusal(destination : Util::IPv4Network, *,
                                 cluster_networks : Array(Util::IPv4Network),
                                 node_networks : Array(Util::IPv4Network)) : String?
      if network = cluster_networks.find(&.overlaps?(destination))
        return "destinationCIDR #{destination} overlaps cluster network #{network}"
      end

      if network = node_networks.find(&.overlaps?(destination))
        return "destinationCIDR #{destination} overlaps network #{network.canonical} of node address #{network.address}"
      end

      nil
    end

    # Returns why a gateway must not use a route table on this node, or nil.
    def self.table_refusal(route_table : Int32, *, vip_route_tables : Set(Int32)) : String?
      return "routeTable #{route_table} is reserved" if RESERVED_ROUTE_TABLES.includes?(route_table)
      return "routeTable #{route_table} is used by a VipAddress on this node" if vip_route_tables.includes?(route_table)

      nil
    end

    # Returns why a gateway rule priority would lose against main, or nil.
    def self.priority_refusal(routing_priority : Int32) : String?
      return if routing_priority < MAIN_RULE_PRIORITY

      "routingPriority #{routing_priority} does not come before the main table rule at #{MAIN_RULE_PRIORITY}"
    end

    # Refuses every gateway whose destination and table another gateway
    # shares: their rules would replace each other on every run.
    private def self.reject_duplicates(gateways : Array(GatewayRuleEntry)) : Selection
      names_by_key = gateways.group_by { |gateway| {gateway.destination_cidr, gateway.route_table} }
        .transform_values(&.map(&.name))
      applied = [] of GatewayRuleEntry
      errors = [] of String

      gateways.each do |gateway|
        others = names_by_key[{gateway.destination_cidr, gateway.route_table}] - [gateway.name]
        if others.empty?
          applied << gateway
        else
          errors << "Refusing VipGateway #{gateway.name}: destinationCIDR #{gateway.destination_cidr} and " \
                    "routeTable #{gateway.route_table} are also used by VipGateway #{others.join(", ")}"
        end
      end

      Selection.new(applied: applied, errors: errors)
    end

    # Pairs each VIP source network with every gateway whose destination it overlaps.
    def self.overlapping_gateways(source_cidrs : Array(Util::IPv4Network),
                                  gateways : Array(GatewayRuleEntry)) : Array({Util::IPv4Network, GatewayRuleEntry})
      source_cidrs.flat_map do |source|
        gateways.select(&.destination_cidr.overlaps?(source)).map { |gateway| {source, gateway} }
      end
    end

    # The VipRoutes that belong to an applied gateway: same destination and
    # table. A refused gateway's VipRoutes get no pod route and no WireGuard
    # allowed IP.
    def self.applied_routes(routes : Array(VipRouteEntry), gateways : Array(GatewayRuleEntry)) : Array(VipRouteEntry)
      applied = gateways.map { |gateway| {gateway.destination_cidr, gateway.route_table} }.to_set
      routes.select { |route| applied.includes?({route.destination_cidr, route.route_table}) }
    end

    # The applied gateways one of whose pods has an address of this node. On
    # that node the gateway runs on the node itself, which reaches the
    # destination through its own routes, so the agent sets up neither the
    # gateway's rule nor its routes there.
    def self.local_gateways(gateways : Array(GatewayRuleEntry),
                            resolved_routes : Array({VipRouteEntry, RoutesUpdater::ResolvedPodRoute?})) : Array(GatewayRuleEntry)
      local = resolved_routes.compact_map do |route, resolved|
        {route.destination_cidr, route.route_table} if resolved.try(&.local)
      end.to_set

      gateways.select { |gateway| local.includes?({gateway.destination_cidr, gateway.route_table}) }
    end

    # Parses the IPv4 addresses with their prefix length from
    # `ip --json addr show` output (172.18.0.2/16, not canonical).
    def self.parse_node_networks(json : String) : Array(Util::IPv4Network)
      Array(JSON::Any).from_json(json).flat_map do |link|
        infos = link["addr_info"]?.try(&.as_a?) || [] of JSON::Any
        infos.compact_map do |info|
          next unless info["family"]?.try(&.as_s?) == "inet"

          # Without a prefix length, the address alone still counts
          prefix = info["prefixlen"]?.try(&.as_i?) || 32
          info["local"]?.try(&.as_s?).try { |local| Util::IPv4Network.new(parse_node_address(local), prefix) }
        end
      end
    end

    # The CRD validates clusterCIDRs. A value that still does not parse
    # stops the run like unreadable node addresses do: without it no gateway
    # can be checked, and the previous state stays in place.
    private def self.parse_cluster_network(cidr : String) : Util::IPv4Network
      Util::IPv4Network.parse(cidr)
    rescue ex : ArgumentError
      raise ArgumentError.new("Cannot check VipGateways: VipConfig clusterCIDRs entry '#{cidr}' is invalid (#{ex.message})")
    end

    private def self.parse_node_address(local : String) : Util::IPv4Address
      Util::IPv4Address.parse(local)
    rescue ex : ArgumentError
      raise ArgumentError.new("Cannot check VipGateways: node address '#{local}' from ip addr show is invalid (#{ex.message})")
    end

    private def self.parse_destination(cidr : String) : Util::IPv4Network?
      Util::IPv4Network.parse(cidr).canonical
    rescue ArgumentError
      nil
    end
  end
end
