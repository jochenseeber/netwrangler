require "../util/ipv4_network"
require "./gateway_policy"
require "./reported_errors"

module Netwrangler::Agent
  # Represents a single route entry from a VipRoute resource
  record VipRouteEntry,
    destination_cidr : Util::IPv4Network,
    gateway_node : String,
    pod_ip : Util::IPv4Address,
    route_table : Int32,
    routing_priority : Int32

  # Holds per-interface desired state for IP addresses and route tables
  class InterfaceState
    getter desired_addresses : Array(AddressUpdater::DesiredAddress) = [] of AddressUpdater::DesiredAddress
    getter route_tables : Array(RouteTableInfo) = [] of RouteTableInfo
  end

  # JSON model for `ip --json link show` output
  class IpLinkOutput
    include JSON::Serializable

    @[JSON::Field(key: "ifname")]
    getter ifname : String = ""

    @[JSON::Field(key: "flags")]
    getter flags : Array(String) = [] of String
  end

  # Main class for monitoring Kubernetes VipAddress resources and managing network configuration
  class AgentHook
    Log = ::Log.for(self)

    # Constants
    EVENT_NAME_RESYNC        = "resync"
    EVENT_NAME_VIP_ADDRESSES = "vip_addresses"
    EVENT_NAME_VIP_NETWORKS  = "vip_networks"
    EVENT_NAME_VIP_CONFIGS   = "vip_configs"
    EVENT_NAME_VIP_ROUTES    = "vip_routes"
    EVENT_NAME_VIP_GATEWAYS  = "vip_gateways"
    EVENT_GROUP              = "vip_address_agent"

    VIP_ADDRESS_FILTER = <<-JQ
      {
        "name": .metadata.name,
        "namespace": .metadata.namespace,
        "network": .spec.network,
        "virtual_cidr": .spec.virtualCIDR,
        "interface": .spec.interface,
        "gateway_ip": .spec.gatewayIP,
        "firewall_mark": (.spec.firewallMark // null),
        "route_table": (.spec.routeTable // null),
        "routing_priority": (.spec.routingPriority // null),
        "egress_enabled": (.spec.egressEnabled // null),
        "endpoint_ips": (.spec.endpointIPs // []),
        "source_cidrs": (.spec.sourceCIDRs // []),
        "ports": (.spec.ports // [])
      }
      JQ

    VIP_NETWORK_FILTER = <<-JQ
      {
        "name": .metadata.name,
        "interface": .spec.interface,
        "gateway_ip": .spec.gatewayIP,
        "network_cidr": .spec.networkCIDR,
        "source_cidrs": (.spec.sourceCIDRs // [])
      }
      JQ

    VIP_CONFIG_FILTER = <<-JQ
      {
        "name": .metadata.name,
        "firewall_mark": .spec.firewallMark,
        "firewall_mark_mask": .spec.firewallMarkMask,
        "route_table": .spec.routeTable,
        "routing_priority": .spec.routingPriority,
        "max_address_count": .spec.maxAddressCount,
        "cluster_cidrs": (.spec.clusterCIDRs // [])
      }
      JQ

    VIP_ROUTE_FILTER = <<-JQ
      {
        "name": .metadata.name,
        "namespace": .metadata.namespace,
        "destination_cidr": .spec.destinationCIDR,
        "gateway_node": .spec.gatewayNode,
        "pod_ip": .spec.podIP,
        "route_table": .spec.routeTable,
        "routing_priority": .spec.routingPriority
      }
      JQ

    VIP_GATEWAY_FILTER = <<-JQ
      {
        "name": .metadata.name,
        "destination_cidr": .spec.destinationCIDR,
        "route_table": .spec.routeTable,
        "routing_priority": .spec.routingPriority
      }
      JQ

    def initialize(*, @node_name : String, @debug : Bool = false)
      @addresses = AddressUpdater.new(debug: @debug)
      @nftables = NftablesUpdater.new(debug: @debug)
      @routes = RoutesUpdater.new(debug: @debug)
      @wireguard = WireguardUpdater.new(debug: @debug)
      @reported_errors = ReportedErrors.new
    end

    # Runs a reconciliation, and again after a failure, up to +attempts+
    # times. Every run is a full, idempotent reconciliation, so one that
    # something changed under, such as another process deleting the
    # netwrangler table between two of its commands, succeeds on the next
    # pass. The last attempt's failure propagates.
    def self.with_attempts(attempts : Int32, & : Int32 -> Nil) : Nil
      (1..attempts).each do |attempt|
        yield attempt
        return
      rescue ex
        raise ex if attempt == attempts

        Log.warn { "Reconciliation failed, reconciling again (attempt #{attempt + 1} of #{attempts}): #{ex.message}" }
      end
    end

    def run(binding_context_path : String) : Nil
      Log.info { "Processing VipAddress events on #{@node_name}" }

      binding_context_content = File.read(binding_context_path)

      if @debug
        STDERR.puts "=== Binding Context ==="
        STDERR.puts binding_context_content
      end

      # Shell-operator provides binding context as an array
      contexts = Array(Util::BindingContext).from_json(binding_context_content)

      contexts.each do |context|
        # Build network lookup from VipNetwork snapshots
        networks_by_name = Hash(String, Util::VipNetworkSnapshot).new
        context.snapshots.vip_networks.each do |network|
          networks_by_name[network.name] = network
        end

        # Get VipConfig singleton (first config if any)
        config = context.snapshots.vip_configs.first?

        # The VipAddress snapshots hold only this node's VipAddresses
        vip_route_tables = context.snapshots.vip_addresses.compact_map(&.route_table).to_set
        gateways = applied_gateways(context.snapshots.vip_gateways, config, vip_route_tables: vip_route_tables)

        # A refused gateway gets no pod route and no WireGuard allowed IP
        vip_routes = AgentHook.vip_route_entries(context.snapshots.vip_routes)
        resolved_routes = GatewayPolicy.applied_routes(vip_routes, gateways).map do |entry|
          {entry, @routes.resolve_pod_route(entry.pod_ip.to_s)}
        end

        # Where a gateway's pod runs on this node with the node's address, the
        # node reaches the destination itself; its destination stays excluded
        # from egress marking, but gets no rule and no routes here
        local_gateways = GatewayPolicy.local_gateways(gateways, resolved_routes)
        local_gateways.each { |gateway| Log.debug { "VipGateway #{gateway.name} runs on this node, routing by the node's own tables" } }
        routed_gateways = gateways - local_gateways

        # Gateway rules and fallbacks exist before the gateway-destinations
        # sync stops marking their destinations, so a later failure fails closed
        @routes.add_gateways(routed_gateways, firewall_mark_mask: config.try(&.firewall_mark_mask))

        process_vip_addresses(context.snapshots.vip_addresses, networks_by_name, config, gateways)
        routed = routed_gateways.map { |gateway| {gateway.destination_cidr, gateway.route_table} }.to_set
        process_vip_routes(vip_routes,
          resolved_routes: resolved_routes.select { |entry, _| routed.includes?({entry.destination_cidr, entry.route_table}) },
          gateways: routed_gateways, vip_route_tables: vip_route_tables)
      end

      @addresses.wait_for_announcements
      @reported_errors.save
    end

    # Applies the safety guard and logs every refused gateway
    private def applied_gateways(snapshots : Array(Util::VipGatewaySnapshot),
                                 config : Util::VipAddressConfigSnapshot?, *,
                                 vip_route_tables : Set(Int32)) : Array(GatewayRuleEntry)
      return [] of GatewayRuleEntry if snapshots.empty?

      selection = GatewayPolicy.select_gateways(snapshots,
        cluster_cidrs: config.try(&.cluster_cidrs) || [] of String,
        node_networks: node_networks,
        vip_route_tables: vip_route_tables)
      selection.errors.each { |message| Log.error { message } }
      selection.applied
    end

    # Raises when the addresses cannot be read: applying a gateway whose
    # safety was not checked could cut the node off.
    private def node_networks : Array(Util::IPv4Network)
      result = Util::Command.new(Util::IP, args: ["--json", "addr", "show"]).run
      GatewayPolicy.parse_node_networks(result.stdout)
    end

    # Holds collected desired state for nftables entries
    private class NftDesiredState
      getter gateways : Array(GatewayRuleEntry)
      getter ingress_entries = Array(NftablesUpdater::MarkMapEntry).new
      getter egress_entries = Array(NftablesUpdater::MarkMapEntry).new
      getter ingress_default_entries = Array(NftablesUpdater::MarkMapEntry).new
      getter egress_default_entries = Array(NftablesUpdater::MarkMapEntry).new
      getter snat_entries = Array(NftablesUpdater::DesiredSnatEntry).new

      def initialize(@gateways : Array(GatewayRuleEntry))
      end
    end

    private def process_vip_addresses(vip_addresses : Array(Util::VipAddressSnapshot), networks_by_name : Hash(String, Util::VipNetworkSnapshot), config : Util::VipAddressConfigSnapshot?, gateways : Array(GatewayRuleEntry)) : Nil
      # Query active network interfaces on this node
      active_ifaces = active_interfaces

      # Per-interface state: desired IP addresses and route tables
      interfaces = Hash(String, InterfaceState).new do |hash, key|
        hash[key] = InterfaceState.new
      end

      nft_state = NftDesiredState.new(gateways)

      vip_addresses.each do |vip_address|
        collect_vip_address_state(vip_address, active_ifaces: active_ifaces,
          networks_by_name: networks_by_name, config: config,
          interfaces: interfaces, nft_state: nft_state)
      end

      remove_stale_resources(interfaces, nft_state: nft_state)
      add_missing_resources(interfaces, nft_state: nft_state, config: config)
    end

    private def collect_vip_address_state(vip_address : Util::VipAddressSnapshot, *,
                                          active_ifaces : Set(String),
                                          networks_by_name : Hash(String, Util::VipNetworkSnapshot),
                                          config : Util::VipAddressConfigSnapshot?,
                                          interfaces : Hash(String, InterfaceState),
                                          nft_state : NftDesiredState) : Nil
      vip_address_ref = "#{vip_address.namespace}/#{vip_address.name}"

      interface = vip_address.interface

      unless active_ifaces.includes?(interface)
        Log.warn { "Skipping VipAddress #{vip_address_ref}: interface '#{interface}' not found or not active" }
        return
      end

      # Look up the VipNetwork (needed for interface validation)
      network = networks_by_name[vip_address.network]?
      unless network
        Log.warn { "Skipping VipAddress #{vip_address_ref}: VipNetwork '#{vip_address.network}' not found" }
        return
      end

      # Parse vipAddress (e.g., "10.0.1.10/24") to extract IP and prefix
      parsed_vip = Util::IPv4Network.parse(vip_address.virtual_cidr)

      # Collect for AddressUpdater
      interfaces[interface].desired_addresses << AddressUpdater::DesiredAddress.new(
        ip: parsed_vip.address, prefix: parsed_vip.prefix)

      collect_nft_entries(vip_address, parsed_vip: parsed_vip, interface: interface,
        config: config, nft_state: nft_state)

      collect_route_table(vip_address, parsed_vip: parsed_vip, interface: interface,
        config: config, interfaces: interfaces)
    end

    private def collect_nft_entries(vip_address : Util::VipAddressSnapshot, *,
                                    parsed_vip : Util::IPv4Network, interface : String,
                                    config : Util::VipAddressConfigSnapshot?,
                                    nft_state : NftDesiredState) : Nil
      vip_address_ref = "#{vip_address.namespace}/#{vip_address.name}"
      ip_firewall_mark = vip_address.firewall_mark

      unless ip_firewall_mark && config
        Log.warn { "Skipping marks for VipAddress #{vip_address_ref}: missing #{ip_firewall_mark ? "VipConfig" : "firewall_mark"}" }
        return
      end

      is_default = vip_address.source_cidrs.includes?("0.0.0.0/0")

      if is_default
        collect_default_nft_entries(vip_address, parsed_vip: parsed_vip,
          mark: ip_firewall_mark, nft_state: nft_state)
      else
        collect_specific_nft_entries(vip_address, parsed_vip: parsed_vip,
          mark: ip_firewall_mark, nft_state: nft_state)
      end

      nft_state.snat_entries << NftablesUpdater::DesiredSnatEntry.new(
        mark: ip_firewall_mark, virtual_ip: parsed_vip.address, interface: interface)
    end

    private def collect_default_nft_entries(vip_address : Util::VipAddressSnapshot, *,
                                            parsed_vip : Util::IPv4Network,
                                            mark : Int32,
                                            nft_state : NftDesiredState) : Nil
      nft_state.ingress_default_entries << NftablesUpdater::MarkMapEntry.default(parsed_vip.address, mark: mark)

      return unless vip_address.egress_enabled == true

      vip_address.endpoint_ips.each do |ep_ip|
        nft_state.egress_default_entries << NftablesUpdater::MarkMapEntry.default(Util::IPv4Address.parse(ep_ip), mark: mark)
      end
    end

    private def collect_specific_nft_entries(vip_address : Util::VipAddressSnapshot, *,
                                             parsed_vip : Util::IPv4Network,
                                             mark : Int32,
                                             nft_state : NftDesiredState) : Nil
      # Derive network CIDR from vipAddress (e.g., "10.0.1.10/24" → "10.0.1.0/24")
      network_cidr = Util::IPv4Network.new(parsed_vip.first_address, parsed_vip.prefix)

      # Specific source networks: entries go in the concatenation maps
      source_cidrs = [network_cidr] + vip_address.source_cidrs.map { |addr| Util::IPv4Network.parse(addr) }

      source_cidrs.each do |source_cidr|
        nft_state.ingress_entries << NftablesUpdater::MarkMapEntry.specific(parsed_vip.address, source_cidr, mark: mark)
      end

      return unless vip_address.egress_enabled == true

      log_gateway_overlaps(vip_address, source_cidrs: source_cidrs, gateways: nft_state.gateways)

      vip_address.endpoint_ips.each do |ep_ip|
        parsed_ep_ip = Util::IPv4Address.parse(ep_ip)
        source_cidrs.each do |source_cidr|
          nft_state.egress_entries << NftablesUpdater::MarkMapEntry.specific(parsed_ep_ip, source_cidr, mark: mark)
        end
      end
    end

    private def log_gateway_overlaps(vip_address : Util::VipAddressSnapshot, *,
                                     source_cidrs : Array(Util::IPv4Network),
                                     gateways : Array(GatewayRuleEntry)) : Nil
      GatewayPolicy.overlapping_gateways(source_cidrs, gateways).each do |source, gateway|
        message = "VipAddress #{vip_address.namespace}/#{vip_address.name} source network #{source} " \
                  "overlaps VipGateway #{gateway.name} destination #{gateway.destination_cidr}; the gateway takes precedence"
        # Logged as an error once while the overlap lasts, not on every resync
        if @reported_errors.fresh?(message)
          Log.error { message }
        else
          Log.debug { message }
        end
      end
    end

    private def collect_route_table(vip_address : Util::VipAddressSnapshot, *,
                                    parsed_vip : Util::IPv4Network, interface : String,
                                    config : Util::VipAddressConfigSnapshot?,
                                    interfaces : Hash(String, InterfaceState)) : Nil
      vip_address_ref = "#{vip_address.namespace}/#{vip_address.name}"
      ip_firewall_mark = vip_address.firewall_mark
      gateway_ip = vip_address.gateway_ip
      route_table = vip_address.route_table
      routing_priority = vip_address.routing_priority

      unless gateway_ip
        Log.warn { "Skipping routes for VipAddress #{vip_address_ref}: missing gateway_ip" }
        return
      end

      unless ip_firewall_mark && route_table && routing_priority && config
        Log.warn { "Skipping routes for VipAddress #{vip_address_ref}: missing firewall_mark, route_table, routing_priority, or VipConfig" }
        return
      end

      interfaces[interface].route_tables << RouteTableInfo.new(
        route_table: route_table,
        virtual_ip: parsed_vip.address,
        gateway_ip: Util::IPv4Address.parse(gateway_ip),
        network_cidr: Util::IPv4Network.new(parsed_vip.first_address, parsed_vip.prefix),
        source_cidrs: vip_address.source_cidrs.map { |addr| Util::IPv4Network.parse(addr) },
        firewall_mark: ip_firewall_mark,
        firewall_mark_mask: config.firewall_mark_mask,
        routing_priority: routing_priority,
      )
    end

    # Stale entries are judged against the desired state of every interface,
    # which also covers an interface that lost its last VipAddress: its map
    # entries, route tables and SNAT entries are not desired, so they go, and
    # the other interfaces' entries stay in place.
    private def remove_stale_resources(interfaces : Hash(String, InterfaceState), *, nft_state : NftDesiredState) : Nil
      # Remove stale mark entries (specific + default maps)
      @nftables.remove_marks(NftablesUpdater::INGRESS_DEFAULT_MAP,
        desired_entries: nft_state.ingress_default_entries)
      @nftables.remove_marks(NftablesUpdater::EGRESS_DEFAULT_MAP,
        desired_entries: nft_state.egress_default_entries)
      @nftables.remove_marks(NftablesUpdater::INGRESS_MAP,
        desired_entries: nft_state.ingress_entries)
      @nftables.remove_marks(NftablesUpdater::EGRESS_MAP,
        desired_entries: nft_state.egress_entries)

      # Remove stale VIP rules and route tables, sparing the gateway tables
      @routes.remove(route_tables: AgentHook.desired_route_tables(interfaces),
        gateway_tables: nft_state.gateways.map(&.route_table).to_set)

      # Remove stale SNAT entries
      @nftables.remove_snat(desired_entries: nft_state.snat_entries)

      AgentHook.address_targets(interfaces, managed_interfaces: @addresses.managed_interfaces).each do |interface, desired_addresses|
        @addresses.remove(interface, desired_addresses: desired_addresses)
      end
    end

    # The VIP addresses each interface keeps. An interface that still holds
    # VIP addresses but has no VipAddress left keeps none.
    def self.address_targets(interfaces : Hash(String, InterfaceState), *,
                             managed_interfaces : Set(String)) : Hash(String, Array(AddressUpdater::DesiredAddress))
      targets = interfaces.transform_values(&.desired_addresses)
      (managed_interfaces - interfaces.keys.to_set).each do |interface|
        targets[interface] = [] of AddressUpdater::DesiredAddress
      end
      targets
    end

    private def add_missing_resources(interfaces : Hash(String, InterfaceState), *, nft_state : NftDesiredState, config : Util::VipAddressConfigSnapshot?) : Nil
      # Add missing resources (forward order: addresses first, routes last)
      interfaces.each do |interface, state|
        @addresses.add(interface, desired_addresses: state.desired_addresses)
      end

      # Sync gateway destinations before the egress rules that exclude them
      @nftables.sync_gateway_destinations(destinations: nft_state.gateways.map(&.destination_cidr))

      # Add the mark maps and their rules in the order the rules apply: the
      # first matching map accepts, specific source networks before the
      # default route. Without a VipConfig the mask is unknown, so the maps
      # stay empty and no rule applies them.
      mask = config.try(&.firewall_mark_mask)
      @nftables.add_marks(NftablesUpdater::INGRESS_MAP,
        rules: [NftablesUpdater::INGRESS_MARK_RULE, NftablesUpdater::INGRESS_OUTPUT_MARK_RULE],
        desired_entries: nft_state.ingress_entries, mask: mask)
      @nftables.add_marks(NftablesUpdater::EGRESS_MAP,
        rules: [NftablesUpdater::EGRESS_MARK_RULE],
        desired_entries: nft_state.egress_entries, mask: mask)
      @nftables.add_marks(NftablesUpdater::INGRESS_DEFAULT_MAP,
        rules: [NftablesUpdater::INGRESS_DEFAULT_MARK_RULE, NftablesUpdater::INGRESS_DEFAULT_OUTPUT_MARK_RULE],
        desired_entries: nft_state.ingress_default_entries, mask: mask)
      @nftables.add_marks(NftablesUpdater::EGRESS_DEFAULT_MAP,
        rules: [NftablesUpdater::EGRESS_DEFAULT_MARK_RULE],
        desired_entries: nft_state.egress_default_entries, mask: mask)

      # The maps no longer reference the per-VIP chains of earlier versions
      @nftables.remove_legacy_mark_chains

      # Add SNAT entries (after marks are configured, before routes)
      if config
        @nftables.add_snat(desired_entries: nft_state.snat_entries, mask: config.firewall_mark_mask)
      end

      # Sync cluster-networks exclusion set
      if config
        @nftables.sync_cluster_networks(addresses: config.cluster_cidrs)
      end

      interfaces.each do |interface, state|
        @routes.add(interface, route_tables: state.route_tables)
      end
    end

    # The route tables of every interface on the node. VIP policy rules are
    # node-wide, so stale tables must be judged against all of them: judged
    # per interface, each interface's tables look stale to the others.
    def self.desired_route_tables(interfaces : Hash(String, InterfaceState)) : Array(RouteTableInfo)
      interfaces.values.flat_map(&.route_tables)
    end

    # Parses `ip --json link show` output and returns names of active interfaces
    def self.parse_active_interfaces(json : String) : Set(String)
      links = Array(IpLinkOutput).from_json(json)
      links
        .select(&.flags.includes?("UP"))
        .map(&.ifname)
        .to_set
    end

    private def active_interfaces : Set(String)
      result = Util::Command.new(Util::IP, args: ["--json", "link", "show"], allowed_exit_codes: [0, 1]).run
      return Set(String).new unless result.success?
      AgentHook.parse_active_interfaces(result.stdout)
    end

    def self.vip_route_entries(vip_routes : Array(Util::VipRouteSnapshot)) : Array(VipRouteEntry)
      vip_routes.map do |vip_route|
        VipRouteEntry.new(
          destination_cidr: Util::IPv4Network.parse(vip_route.destination_cidr).canonical,
          gateway_node: vip_route.gateway_node,
          pod_ip: Util::IPv4Address.parse(vip_route.pod_ip),
          route_table: vip_route.route_table,
          routing_priority: vip_route.routing_priority,
        )
      end
    end

    # Installs the pod routes of the routed gateways' VipRoutes, resolved
    # once by the caller, and removes what no routed gateway wants. A gateway
    # that runs on this node is not among them, so its rule, fallback and pod
    # routes go here.
    private def process_vip_routes(all_routes : Array(VipRouteEntry), *,
                                   resolved_routes : Array({VipRouteEntry, RoutesUpdater::ResolvedPodRoute?}),
                                   gateways : Array(GatewayRuleEntry),
                                   vip_route_tables : Set(Int32)) : Nil
      desired_routes = resolved_routes.map(&.first)

      # On remote nodes, ensure WireGuard allowed IPs before installing routes
      remote_resolved = resolved_routes.reject { |entry, _| entry.gateway_node == @node_name }
      update_wireguard_allowed_ips(remote_resolved)
      remove_stale_wireguard_allowed_ips(remote_resolved.map(&.first))

      # Stale rules and routes go after the gateway-destinations sync, so a
      # destination is marked again before its rule goes; then the pod routes
      @routes.remove_stale_gateway_routes(desired_routes, gateways: gateways, route_tables: all_routes.map(&.route_table),
        vip_route_tables: vip_route_tables)
      @routes.add_gateway_routes(resolved_routes)
    end

    # For remote routes, resolve the pod route to find the outgoing interface.
    # If the interface is a WireGuard interface, add the destination to its
    # allowed IPs so the route can work.
    private def update_wireguard_allowed_ips(resolved_entries : Array({VipRouteEntry, RoutesUpdater::ResolvedPodRoute?})) : Nil
      managed = Set(String).new
      resolved_entries.each do |entry, resolved|
        next unless resolved
        next unless @wireguard.wireguard_interface?(resolved.dev)

        @wireguard.ensure_allowed_ip(resolved.dev, destination_cidr: entry.destination_cidr, pod_ip: entry.pod_ip)
        managed << entry.destination_cidr.to_s
      end
      @wireguard.save_managed_destinations(managed) unless managed.empty?
    end

    # Removes destination IPs from WireGuard peers that are no longer in the
    # desired remote route set.
    private def remove_stale_wireguard_allowed_ips(desired_remote_routes : Array(VipRouteEntry)) : Nil
      desired_destinations = desired_remote_routes.map(&.destination_cidr.to_s).to_set
      @wireguard.remove_stale_allowed_ips(desired_destinations: desired_destinations)
    end

    def print_config : Nil
      puts config_json
    end

    def config_json : String
      config = {
        configVersion: "v1",
        schedule:      [
          {
            name:                 EVENT_NAME_RESYNC,
            group:                EVENT_GROUP,
            crontab:              "*/30 * * * * *",
            allowFailure:         true,
            includeSnapshotsFrom: [EVENT_NAME_VIP_ADDRESSES, EVENT_NAME_VIP_NETWORKS, EVENT_NAME_VIP_CONFIGS, EVENT_NAME_VIP_ROUTES, EVENT_NAME_VIP_GATEWAYS],
          },
        ],
        kubernetes: [
          {
            name:                         EVENT_NAME_VIP_ADDRESSES,
            group:                        EVENT_GROUP,
            apiVersion:                   "netwrangler.dev/v1",
            kind:                         "VipAddress",
            executeHookOnEvent:           ["Added", "Modified", "Deleted"],
            executeHookOnSynchronization: true,
            keepFullObjectsInMemory:      false,
            allowFailure:                 true,
            includeSnapshotsFrom:         [EVENT_NAME_VIP_NETWORKS, EVENT_NAME_VIP_CONFIGS, EVENT_NAME_VIP_ROUTES, EVENT_NAME_VIP_GATEWAYS],
            labelSelector:                {
              matchExpressions: [
                {
                  key:      "netwrangler.dev/node-name",
                  operator: "In",
                  values:   [@node_name],
                },
              ],
            },
            jqFilter: VIP_ADDRESS_FILTER.strip,
          },
          {
            name:                         EVENT_NAME_VIP_NETWORKS,
            group:                        EVENT_GROUP,
            apiVersion:                   "netwrangler.dev/v1",
            kind:                         "VipNetwork",
            executeHookOnEvent:           ["Added", "Modified", "Deleted"],
            executeHookOnSynchronization: true,
            keepFullObjectsInMemory:      false,
            allowFailure:                 true,
            includeSnapshotsFrom:         [EVENT_NAME_VIP_ADDRESSES, EVENT_NAME_VIP_CONFIGS, EVENT_NAME_VIP_ROUTES, EVENT_NAME_VIP_GATEWAYS],
            jqFilter:                     VIP_NETWORK_FILTER.strip,
          },
          {
            name:                         EVENT_NAME_VIP_CONFIGS,
            group:                        EVENT_GROUP,
            apiVersion:                   "netwrangler.dev/v1",
            kind:                         "VipConfig",
            executeHookOnEvent:           ["Added", "Modified", "Deleted"],
            executeHookOnSynchronization: true,
            keepFullObjectsInMemory:      false,
            allowFailure:                 true,
            includeSnapshotsFrom:         [EVENT_NAME_VIP_ADDRESSES, EVENT_NAME_VIP_NETWORKS, EVENT_NAME_VIP_ROUTES, EVENT_NAME_VIP_GATEWAYS],
            jqFilter:                     VIP_CONFIG_FILTER.strip,
          },
          {
            name:                         EVENT_NAME_VIP_ROUTES,
            group:                        EVENT_GROUP,
            apiVersion:                   "netwrangler.dev/v1",
            kind:                         "VipRoute",
            executeHookOnEvent:           ["Added", "Modified", "Deleted"],
            executeHookOnSynchronization: true,
            keepFullObjectsInMemory:      false,
            allowFailure:                 true,
            includeSnapshotsFrom:         [EVENT_NAME_VIP_ADDRESSES, EVENT_NAME_VIP_NETWORKS, EVENT_NAME_VIP_CONFIGS, EVENT_NAME_VIP_GATEWAYS],
            jqFilter:                     VIP_ROUTE_FILTER.strip,
          },
          {
            name:                         EVENT_NAME_VIP_GATEWAYS,
            group:                        EVENT_GROUP,
            apiVersion:                   "netwrangler.dev/v1",
            kind:                         "VipGateway",
            executeHookOnEvent:           ["Added", "Modified", "Deleted"],
            executeHookOnSynchronization: true,
            keepFullObjectsInMemory:      false,
            allowFailure:                 true,
            includeSnapshotsFrom:         [EVENT_NAME_VIP_ADDRESSES, EVENT_NAME_VIP_NETWORKS, EVENT_NAME_VIP_CONFIGS, EVENT_NAME_VIP_ROUTES],
            jqFilter:                     VIP_GATEWAY_FILTER.strip,
          },
        ],
      }
      config.to_json
    end
  end
end
