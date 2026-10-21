require "log"
require "../model/condition"
require "../model/vip_address"
require "../model/vip_config"
require "../model/vip_network"
require "../model/service"
require "../model/endpoint_slice"
require "../model/object_meta"
require "../model/object_reference"
require "../util/extensions"
require "../util/ipv4_address"
require "../util/ipv4_network"
require "../util/qualified_name"

module Netwrangler::Controller
  # Allocates virtual IPs to nodes using a load-based distribution algorithm.
  class IpAllocator
    Log = ::Log.for(self)

    # Label keys for VipAddress resources
    LABEL_MANAGED        = "netwrangler.dev/managed-by"
    LABEL_NAMESPACE      = "netwrangler.dev/namespace"
    LABEL_NETWORK        = "netwrangler.dev/network"
    LABEL_SERVICE        = "netwrangler.dev/service"
    LABEL_NODE_NAME      = "netwrangler.dev/node-name"
    LABEL_INGRESS        = "netwrangler.dev/ingress"
    DEFAULT_MANAGER_NAME = "netwrangler"

    # Label key for service name in EndpointSlice
    LABEL_SERVICE_NAME = "kubernetes.io/service-name"

    # Calculates the maximum number of unique non-zero firewall mark values
    # representable by the given mask: 2^popcount(mask) - 1.
    def self.fwmark_capacity(mask : UInt32) : Int32
      bits = mask.popcount
      return 0 if bits == 0
      return Int32::MAX if bits >= 31
      ((1_u32 << bits) - 1).to_i32
    end

    getter services : Hash(Util::QualifiedName, Model::Service)
    getter endpoint_slices : Hash(Util::QualifiedName, Model::EndpointSlice)
    getter vip_networks : Hash(String, Model::VipNetwork)
    getter vip_addresses : Hash(Util::QualifiedName, Model::VipAddress)
    getter vip_addresses_by_node : Hash(String, Array(Model::VipAddress))
    record DisabledNetwork, name : String, reason : String
    getter disabled_networks : Array(DisabledNetwork) = [] of DisabledNetwork
    getter config : Model::VipConfig?
    getter? debug : Bool

    def network_disabled?(name : String) : Bool
      @disabled_networks.any? { |disabled| disabled.name == name }
    end

    def disabled_reason(name : String) : String?
      @disabled_networks.find { |disabled| disabled.name == name }.try(&.reason)
    end

    class StatusInfo
      getter status : Bool?
      getter message : String
      getter reason : String

      def self.ok(message : String) : StatusInfo
        StatusInfo.new(status: true, message: message, reason: "Ok")
      end

      def self.error(exception : Exception) : StatusInfo
        error_message = exception.message || "Unknown Error"
        error_reason = exception.class.name.gsub(%r{^.*::}, "")
        StatusInfo.new(status: false, message: error_message, reason: error_reason)
      end

      def initialize(*, @status : Bool?, @message : String, @reason : String)
      end

      def status_name : String
        @status == true ? "True" : @status == false ? "False" : "Unknown"
      end

      def condition(observed_generation : Int64, last_transition_time : Time) : Netwrangler::Model::Condition
        Netwrangler::Model::Condition.new(
          type: "IpAllocated",
          status: status_name,
          reason: @reason,
          message: @message,
          observed_generation: observed_generation,
          last_transition_time: last_transition_time
        )
      end
    end

    class VipAddressInfo
      getter name : Util::QualifiedName
      getter network : String
      getter virtual_cidr : Util::IPv4Network
      getter service_name : Util::QualifiedName
      getter service_uid : String
      getter interface : String
      getter gateway_ip : Util::IPv4Address?
      getter source_cidrs : Array(Util::IPv4Network)
      property firewall_mark : Int32?
      property route_table : Int32?
      property routing_priority : Int32?
      property egress_enabled : Bool?
      property node_name : String?
      property endpoint_ips : Array(String) = [] of String

      def node_name! : String
        @node_name || raise NilAssertionError.new("VipAddressInfo#node_name is nil")
      end

      property ports : Array(Model::VipAddress::Port) = [] of Model::VipAddress::Port

      def initialize(*, @name : Util::QualifiedName, @network : String, @virtual_cidr : Util::IPv4Network,
                     @service_name : Util::QualifiedName, @service_uid : String,
                     @interface : String,
                     @gateway_ip : Util::IPv4Address? = nil,
                     @source_cidrs : Array(Util::IPv4Network) = [] of Util::IPv4Network,
                     @firewall_mark : Int32? = nil,
                     @route_table : Int32? = nil,
                     @routing_priority : Int32? = nil,
                     @egress_enabled : Bool? = nil,
                     @node_name : String? = nil, @endpoint_ips : Array(String) = [] of String,
                     @ports : Array(Model::VipAddress::Port) = [] of Model::VipAddress::Port)
      end

      def_equals @name, @network, @virtual_cidr, @service_name, @service_uid, @node_name, @interface, @gateway_ip, @source_cidrs, @firewall_mark, @route_table, @routing_priority, @egress_enabled, @endpoint_ips, @ports

      # Check if this VipAddressInfo matches a Model::VipAddress (string boundary)
      def matches?(vip_address : Model::VipAddress) : Bool
        matches_identity?(vip_address) &&
          matches_network?(vip_address) &&
          matches_routing?(vip_address) &&
          @endpoint_ips == vip_address.endpoint_ips &&
          @ports == vip_address.ports
      end

      private def matches_identity?(vip_address : Model::VipAddress) : Bool
        vip_address_name = Util::QualifiedName.new(name: vip_address.metadata.name!, namespace: vip_address.metadata.namespace!)
        @name == vip_address_name &&
          @network == vip_address.network &&
          @virtual_cidr.to_s == vip_address.virtual_cidr &&
          @node_name == vip_address.node_name
      end

      private def matches_network?(vip_address : Model::VipAddress) : Bool
        @interface == vip_address.interface &&
          @gateway_ip.try(&.to_s) == vip_address.gateway_ip &&
          @source_cidrs.map(&.to_s) == vip_address.source_cidrs
      end

      private def matches_routing?(vip_address : Model::VipAddress) : Bool
        @firewall_mark == vip_address.firewall_mark &&
          @route_table == vip_address.route_table &&
          @routing_priority == vip_address.routing_priority &&
          @egress_enabled == vip_address.egress_enabled
      end
    end

    class NodeInfo
      getter name : String
      getter endpoint_count : Int32
      getter endpoint_ips : Array(String)
      getter vip_addresses : Array(VipAddressInfo) = [] of VipAddressInfo
      property quota : Float32 = 0_f32
      property capacity : Int32? = nil

      def initialize(@name : String, *, @endpoint_count : Int32, @endpoint_ips : Array(String) = [] of String)
        raise ArgumentError.new("Endpoint count must be greater than 0") unless @endpoint_count > 0
      end

      def at_capacity? : Bool
        if cap = @capacity
          @vip_addresses.size >= cap
        else
          false
        end
      end

      def add_ip(vip_address : VipAddressInfo) : Nil
        raise ArgumentError.new("IP '#{vip_address.virtual_cidr}' already belongs to node '#{vip_address.node_name}'") if vip_address.node_name

        vip_address.node_name = @name
        @vip_addresses << vip_address
      end

      def remove_last_ip : VipAddressInfo
        vip_address = @vip_addresses.pop
        vip_address.node_name = nil
        vip_address
      end

      # Deviation from quota (positive = over quota, negative = under quota, no IP = severely under quota)
      def quota_deviation(delta : Int32 = 0) : Float32
        vip_address_count = @vip_addresses.size + delta
        vip_address_count - @quota - (vip_address_count == 0 ? 1_000_000_f32 : 0_f32)
      end

      def has_ips? : Bool
        !@vip_addresses.empty?
      end
    end

    class ServiceInfo
      getter service_name : Util::QualifiedName

      getter generation : Int64

      getter nodes : Hash(String, NodeInfo) = {} of String => NodeInfo

      getter endpoint_count : Int32 = 0_i32

      getter vip_addresses : Hash(String, VipAddressInfo) = {} of String => VipAddressInfo

      property status : StatusInfo?

      def status! : StatusInfo
        @status || raise NilAssertionError.new("ServiceInfo#status is nil")
      end

      def initialize(@service_name : Util::QualifiedName, *, @generation : Int64)
      end

      def nodes=(nodes : Hash(String, NodeInfo)) : Hash(String, NodeInfo)
        @nodes = nodes
        @endpoint_count = @nodes.values.sum(&.endpoint_count)

        update_quotas

        nodes
      end

      def vip_addresses=(vip_addresses : Hash(String, VipAddressInfo)) : Hash(String, VipAddressInfo)
        @vip_addresses = vip_addresses

        update_quotas

        vip_addresses
      end

      private def update_quotas : Nil
        if @endpoint_count == 0 || @vip_addresses.empty?
          @nodes.each_value do |node|
            node.quota = 0_f32
          end
        else
          @nodes.each_value do |node|
            node.quota = @vip_addresses.size.to_f32 * node.endpoint_count.to_f32 / @endpoint_count.to_f32
          end
        end
      end
    end

    # Result of allocation containing actions to take
    class AllocationResult
      getter added_ips : Array(Model::VipAddress)
      getter updated_ips : Array(Model::VipAddress)
      getter deleted_ips : Array(Model::ObjectReference)
      getter service_conditions : Hash(Util::QualifiedName, Model::Condition)

      def initialize(*, @added_ips : Array(Model::VipAddress), @updated_ips : Array(Model::VipAddress), @deleted_ips : Array(Model::ObjectReference), @service_conditions : Hash(Util::QualifiedName, Model::Condition))
      end

      def empty? : Bool
        @added_ips.empty? && @updated_ips.empty? && @deleted_ips.empty?
      end
    end

    def initialize(
      *,
      services : Array(Model::Service),
      endpoint_slices : Array(Model::EndpointSlice),
      vip_networks : Array(Model::VipNetwork),
      vip_addresses : Array(Model::VipAddress),
      vip_configs : Array(Model::VipConfig) = [] of Model::VipConfig,
      @manager_name : String = DEFAULT_MANAGER_NAME,
      @debug : Bool = false,
    )
      @services = services.index_by { |service| Util::QualifiedName.new(name: service.metadata.name!, namespace: service.metadata.namespace!) }
      @endpoint_slices = endpoint_slices.index_by { |endpoint_slice| Util::QualifiedName.new(name: endpoint_slice.metadata.name!, namespace: endpoint_slice.metadata.namespace!) }
      @vip_networks = vip_networks.index_by(&.metadata.name!)
      @config = vip_configs.first?
      @vip_addresses_by_node = vip_addresses.group_by(&.spec.node_name)

      @vip_addresses = vip_addresses.to_h do |vip_address|
        key = Util::QualifiedName.new(name: vip_address.metadata.name!, namespace: vip_address.metadata.namespace!)
        {key, vip_address}
      end

      @claimed_fwmarks = Set(Int32).new
      @claimed_tables = Set(Int32).new
      @claimed_priorities = Set(Int32).new
    end

    # Allocate virtual IPs to nodes
    def allocate : AllocationResult
      # Detect and disable overlapping VipNetworks before processing services
      disable_overlapping_networks

      initialize_route_resource_tracking

      # Process each service
      service_infos = @services.values.map do |service|
        process_service(service)
      end

      # Continue only with valid service infos
      valid_service_infos = service_infos.reject(&.status)

      if @debug
        Log.debug { "Valid service infos: #{valid_service_infos.size}" }
        valid_service_infos.each do |service_info|
          Log.debug { "  Service #{service_info.service_name.name}: #{service_info.nodes.size} nodes, #{service_info.vip_addresses.size} IPs" }
          service_info.nodes.each do |name, node|
            Log.debug { "    Node #{name}: #{node.vip_addresses.size} IPs, quota=#{node.quota}" }
            node.vip_addresses.each do |ip|
              Log.debug { "      IP: #{ip.virtual_cidr} -> #{ip.node_name}" }
            end
          end
        end
      end

      # Build hash of assigned virtual IPs
      assigned_vip_addresses = valid_service_infos.flat_map do |service_info|
        service_info.nodes.values.flat_map do |node|
          node.vip_addresses
        end
      end.index_by(&.name)

      if @debug
        Log.debug { "Assigned virtual IPs: #{assigned_vip_addresses.size}" }
        assigned_vip_addresses.each do |key, ip|
          Log.debug { "  #{key.name}: #{ip.virtual_cidr} -> #{ip.node_name}" }
        end
        Log.debug { "Existing virtual IPs: #{@vip_addresses.size}" }
        @vip_addresses.each do |key, ip|
          Log.debug { "  #{key.name}: #{ip.virtual_cidr} on #{ip.node_name}" }
        end
      end

      # Create new virtual IPs
      added_vip_addresses = assigned_vip_addresses.reject do |key, _|
        @vip_addresses.has_key?(key)
      end.map do |_, vip_address_info|
        create_vip_address_resource(vip_address_info)
      end

      # Delete virtual IPs no longer needed (only those managed by this controller)
      deleted_vip_addresses = @vip_addresses.reject do |key, _|
        assigned_vip_addresses.has_key?(key)
      end.select do |_, vip_address|
        vip_address.metadata.labels.try(&.[LABEL_MANAGED]?) == @manager_name
      end.map do |_, vip_address|
        create_vip_address_reference(vip_address)
      end

      # Update virtual IPs where allocation changed
      updated_vip_addresses = assigned_vip_addresses.compact_map do |key, updated_vip_address|
        current_vip_address = @vip_addresses[key]?

        if @debug
          if current_vip_address.nil?
            Log.debug { "  #{key.name}: current_vip_address is nil, skipping" }
          else
            matches = updated_vip_address.matches?(current_vip_address)
            Log.debug { "  #{key.name}: matches?=#{matches}, updated_node=#{updated_vip_address.node_name}, current_node=#{current_vip_address.node_name}" }
          end
        end

        next if current_vip_address.nil? || updated_vip_address.matches?(current_vip_address)

        create_vip_address_resource(updated_vip_address)
      end

      if @debug
        Log.debug { "Added: #{added_vip_addresses.size}, Updated: #{updated_vip_addresses.size}, Deleted: #{deleted_vip_addresses.size}" }
      end

      valid_service_infos.each do |service_info|
        service_info.status = StatusInfo.ok("Allocated #{service_info.nodes.values.sum(&.vip_addresses.size)} IPs to #{service_info.nodes.size} nodes")
      end

      # Build service conditions hash
      now = Time.utc

      service_conditions = service_infos.to_h do |service_info|
        {service_info.service_name, service_info.status!.condition(service_info.generation, now)}
      end

      AllocationResult.new(added_ips: added_vip_addresses, updated_ips: updated_vip_addresses, deleted_ips: deleted_vip_addresses, service_conditions: service_conditions)
    end

    # Process a service
    private def process_service(service : Model::Service) : ServiceInfo
      service_name = Util::QualifiedName.new(name: service.metadata.name!, namespace: service.metadata.namespace!)
      service_info = ServiceInfo.new(service_name, generation: service.metadata.generation || 0_i64)

      begin
        external_ips = service.spec.try(&.external_ips).try(&.empty_to_nil) || begin
          raise ArgumentError.new("No virtual IPs defined")
        end

        egress_label = service.metadata.labels.try(&.["netwrangler.dev/egress"]?)
        egress_enabled = egress_label == "enabled"

        ports = (service.spec.try(&.ports) || [] of Model::ServicePort).map do |service_port|
          Model::VipAddress::Port.new(port: service_port.port, protocol: service_port.protocol || "TCP")
        end

        service_info.vip_addresses = build_vip_address_infos(
          service_name, service_uid: service.metadata.uid!,
          external_ips: external_ips, egress_enabled: egress_enabled, ports: ports)

        distribute_ips_to_nodes(service_info)
      rescue ex : Exception
        service_info.status = StatusInfo.error(ex)
      end

      service_info
    end

    # Builds VipAddressInfo objects for each external IP, resolving networks and parsing typed values
    private def build_vip_address_infos(
      service_name : Util::QualifiedName, *, service_uid : String,
      external_ips : Array(String), egress_enabled : Bool,
      ports : Array(Model::VipAddress::Port),
    ) : Hash(String, VipAddressInfo)
      existing_names = @vip_addresses.values
        .select { |vip_address| vip_address.metadata.labels.try(&.[LABEL_SERVICE]?) == service_name.name && vip_address.metadata.namespace == service_name.namespace }
        .map(&.metadata.name!)

      existing_ip_to_name = @vip_addresses.values
        .select { |vip_address| vip_address.metadata.labels.try(&.[LABEL_SERVICE]?) == service_name.name && vip_address.metadata.namespace == service_name.namespace }
        .to_h { |vip_address| {vip_address.virtual_cidr, vip_address.metadata.name!} }

      used_indices = existing_names.compact_map { |existing_name| extract_vip_index(service_name.name, existing_name) }.to_set

      external_ips.map do |ip|
        vip_network = find_network_for_ip(ip)
        network_name = vip_network.metadata.name!

        parsed_network = Util::IPv4Network.parse(vip_network.network_cidr)
        parsed_ip = Util::IPv4Address.parse(ip)
        vip_address_cidr = Util::IPv4Network.new(parsed_ip, parsed_network.prefix)

        parsed_gateway = if gw = vip_network.gateway_ip
                           begin
                             Util::IPv4Address.parse(gw)
                           rescue ArgumentError
                             raise ArgumentError.new("VipNetwork '#{network_name}' has invalid gateway address: #{gw}")
                           end
                         end

        parsed_source_networks = effective_source_cidrs(vip_network).map { |cidr| Util::IPv4Network.parse(cidr) }

        vip_address_str = vip_address_cidr.to_s
        name = existing_ip_to_name[vip_address_str]? || begin
          index = allocate_next_index(used_indices, external_ips.size)
          used_indices << index
          "#{service_name.name}-#{index}"
        end

        VipAddressInfo.new(
          name: Util::QualifiedName.new(name: name, namespace: service_name.namespace),
          network: network_name,
          virtual_cidr: vip_address_cidr,
          service_name: service_name,
          service_uid: service_uid,
          interface: vip_network.interface,
          gateway_ip: parsed_gateway,
          source_cidrs: parsed_source_networks,
          egress_enabled: egress_enabled,
          ports: ports
        )
      end.index_by(&.virtual_cidr.to_s)
    end

    # Distributes VIPs to nodes: claim existing, allocate resources, assign remaining, rebalance
    private def distribute_ips_to_nodes(service_info : ServiceInfo) : Nil
      nodes = collect_service_nodes(service_info.service_name).empty_to_nil || begin
        raise ArgumentError.new("No ready endpoints found")
      end

      service_info.nodes = nodes

      cap = per_node_cap
      service_info.nodes.each_value do |node|
        node.capacity = cap
      end

      claim_existing_ips(service_info)
      allocate_route_resources(service_info.vip_addresses)
      assign_remaining_ips(service_info)
      rebalance_ips(service_info)

      service_info.nodes.each_value do |node|
        node.vip_addresses.each do |vip_address|
          vip_address.endpoint_ips = node.endpoint_ips
        end
      end
    end

    # Extracts the numeric index from a VipAddress name like "my-service-3" → 3
    private def extract_vip_index(service_name : String, vip_address_name : String) : Int32?
      suffix = vip_address_name.lchop("#{service_name}-")
      return if suffix == vip_address_name # prefix didn't match
      suffix.to_i?
    end

    # Allocates the lowest free 1-based index not in used_indices
    private def allocate_next_index(used_indices : Set(Int32), max_count : Int32) : Int32
      (1..max_count + used_indices.size).each do |candidate|
        return candidate unless used_indices.includes?(candidate)
      end
      used_indices.max + 1
    end

    # Detects overlapping VipNetwork CIDRs and disables networks that overlap.
    # Among overlapping networks, prefers to keep the one with existing VipAddresses.
    # Uses sorted address ranges for O(n log n) detection.
    private def disable_overlapping_networks : Nil
      return if @vip_networks.size < 2

      # Build sorted list of (range, network_name) tuples
      entries = @vip_networks.map do |name, net|
        network = Util::IPv4Network.parse(net.network_cidr)
        {range: network.address_range, name: name}
      end.sort_by!(&.[:range].begin)

      # Scan for overlaps: if current range starts before previous range ends, they overlap
      (1...entries.size).each do |i|
        current = entries[i]
        previous = entries[i - 1]

        next unless current[:range].begin <= previous[:range].end
        next if network_disabled?(current[:name]) || network_disabled?(previous[:name])

        # Determine which network to disable:
        # 1. Prefer keeping the one with existing VipAddresses
        # 2. If tie, prefer keeping the more specific (longer prefix) network
        current_has_ips = @vip_addresses.values.any? { |vip_address| vip_address.metadata.labels.try(&.[LABEL_NETWORK]?) == current[:name] }
        previous_has_ips = @vip_addresses.values.any? { |vip_address| vip_address.metadata.labels.try(&.[LABEL_NETWORK]?) == previous[:name] }

        current_prefix = Util::IPv4Network.parse(@vip_networks[current[:name]].network_cidr).prefix
        previous_prefix = Util::IPv4Network.parse(@vip_networks[previous[:name]].network_cidr).prefix

        keep_current = if current_has_ips != previous_has_ips
                         current_has_ips
                       else
                         current_prefix > previous_prefix
                       end

        if keep_current
          disable_name = previous[:name]
          keep_name = current[:name]
        else
          disable_name = current[:name]
          keep_name = previous[:name]
        end

        reason = "overlaps with '#{keep_name}'"
        @disabled_networks << DisabledNetwork.new(name: disable_name, reason: reason)
        Log.warn { "VipNetwork '#{disable_name}' disabled: #{reason}" }
      end
    end

    # Returns the effective source networks for a VipNetwork after pruning overlaps.
    # If sourceNetworks contains 0.0.0.0/0, returns only ["0.0.0.0/0"] (catch-all).
    # Otherwise, removes entries contained by broader entries and logs warnings.
    private def effective_source_cidrs(vip_network : Model::VipNetwork) : Array(String)
      source_cidrs = vip_network.source_cidrs
      network_name = vip_network.metadata.name!

      # Handle catch-all
      if source_cidrs.includes?("0.0.0.0/0")
        if source_cidrs.size > 1
          Log.warn { "VipNetwork '#{network_name}': sourceNetworks contains 0.0.0.0/0 with other entries, using only 0.0.0.0/0" }
        end
        return ["0.0.0.0/0"]
      end

      return [] of String if source_cidrs.empty?

      # Build combined list: networkAddress + sourceNetworks
      all_cidrs = [vip_network.network_cidr] + source_cidrs
      parsed = all_cidrs.map { |cidr| {cidr: cidr, network: Util::IPv4Network.parse(cidr)} }
      sorted = parsed.sort_by(&.[:network].first_address)

      # Scan for overlaps: remove entries contained by a broader entry
      kept = [] of String
      max_end = Util::IPv4Address.new(0_u32)

      sorted.each do |entry|
        range = entry[:network].address_range

        if !kept.empty? && range.begin <= max_end
          Log.warn { "VipNetwork '#{network_name}': sourceNetwork '#{entry[:cidr]}' overlaps with a broader entry, ignoring" }
          next
        end

        kept << entry[:cidr]
        range_end = range.end
        max_end = range_end if range_end > max_end
      end

      # Return only the sourceNetworks portion (exclude networkAddress which is added separately by the agent)
      kept.reject { |cidr| cidr == vip_network.network_cidr }
    end

    # Finds the unique VipNetwork whose CIDR contains the given IP address.
    # Raises if no network matches, if the matched network is disabled, or
    # if multiple networks match (overlapping CIDRs).
    private def find_network_for_ip(ip : String) : Model::VipNetwork
      parsed_ip = Util::IPv4Address.parse(ip)

      all_matches = @vip_networks.values.select do |net|
        network = Util::IPv4Network.parse(net.network_cidr)
        network.contains?(parsed_ip)
      end

      # Separate active and disabled matches
      active_matches = all_matches.reject { |net| network_disabled?(net.metadata.name!) }
      disabled_matches = all_matches.select { |net| network_disabled?(net.metadata.name!) }

      case active_matches.size
      when 0
        if disabled_match = disabled_matches.first?
          name = disabled_match.metadata.name!
          raise ArgumentError.new("VipNetwork '#{name}' is disabled: #{disabled_reason(name)}")
        end
        raise ArgumentError.new("IP '#{ip}' does not match any VipNetwork CIDR")
      when 1
        active_matches.first
      else
        names = active_matches.map(&.metadata.name).join(", ")
        raise ArgumentError.new("IP '#{ip}' matches multiple active VipNetworks: #{names}")
      end
    end

    private def collect_service_nodes(service_name : Util::QualifiedName) : Hash(String, NodeInfo)
      @endpoint_slices.values.select do |endpoint_slice|
        # Check if this endpoint slice belongs to our service
        slice_service_name = endpoint_slice.metadata.labels.try(&.[LABEL_SERVICE_NAME]?)
        next false unless slice_service_name == service_name.name
        next false unless endpoint_slice.metadata.namespace! == service_name.namespace
        true
      end.flat_map do |endpoint_slice|
        endpoints = endpoint_slice.endpoints
        next [] of Model::EndpointSlice::Endpoint unless endpoints

        endpoints.select do |endpoint|
          next false unless endpoint.conditions.try(&.ready) == true

          endpoint.node_name
        end
      end.group_by do |endpoint|
        endpoint.node_name!
      end.transform_values do |endpoints, node_name|
        endpoint_ips = endpoints.flat_map(&.addresses).sort!.uniq!
        NodeInfo.new(node_name, endpoint_count: endpoints.size, endpoint_ips: endpoint_ips)
      end
    end

    # Assign all existing virtual IPs to nodes based on current allocations
    private def claim_existing_ips(service_info : ServiceInfo) : Nil
      service_info.nodes.each_value do |node|
        # Skip nodes with no endpoints
        next if node.endpoint_count <= 0

        # Skip nodes with no existing IPs
        node_vip_addresses = @vip_addresses_by_node[node.name]?
        next if !node_vip_addresses || node_vip_addresses.empty?

        node_vip_addresses.each do |vip_address|
          # Check if this IP exists and is unclaimed
          info = service_info.vip_addresses[vip_address.virtual_cidr]?
          next if !info || info.node_name

          # Skip if node is at capacity
          next if node.at_capacity?

          carry_over_route_allocations(info, vip_address: vip_address)

          # Set node name and add to node's allocated IPs
          node.add_ip(info)
        end
      end
    end

    # Carries over existing route allocations (firewall mark, route table,
    # routing priority) from a VipAddress to an info record. Skips if any
    # value was already claimed by another VipAddress during this run,
    # forcing the duplicate to be re-allocated.
    private def carry_over_route_allocations(info : VipAddressInfo, *, vip_address : Model::VipAddress) : Nil
      firewall_mark = vip_address.firewall_mark
      route_table = vip_address.route_table
      routing_priority = vip_address.routing_priority

      duplicate = (firewall_mark && @claimed_fwmarks.includes?(firewall_mark)) ||
                  (route_table && @claimed_tables.includes?(route_table)) ||
                  (routing_priority && @claimed_priorities.includes?(routing_priority))
      return if duplicate

      info.firewall_mark = firewall_mark
      info.route_table = route_table
      info.routing_priority = routing_priority
      @claimed_fwmarks << firewall_mark if firewall_mark
      @claimed_tables << route_table if route_table
      @claimed_priorities << routing_priority if routing_priority
    end

    # Assign remaining IPs to most undersupplied nodes
    private def assign_remaining_ips(service_info : ServiceInfo) : Nil
      unassigned_ips = service_info.vip_addresses.values.reject(&.node_name)

      unassigned_ips.each do |vip_address|
        # Find most undersupplied node that is not at capacity
        most_undersupplied_node = service_info.nodes.values
          .reject(&.at_capacity?)
          .min_by?(&.quota_deviation)

        unless most_undersupplied_node
          remaining = unassigned_ips.count { |ip| ip.node_name.nil? }
          Log.warn { "#{remaining} VIPs unassigned: all nodes at fwmark capacity" } if remaining > 0
          break
        end

        most_undersupplied_node.add_ip(vip_address)
      end
    end

    # Rebalance IPs across nodes to optimize average load.
    # Constraint: Every node with active endpoints should have at least one IP if there are enough IPs
    # Initializes tracking sets for route resource allocation. Populates used
    # Resets claimed sets for the current allocation run.
    private def initialize_route_resource_tracking : Nil
      @claimed_fwmarks = Set(Int32).new
      @claimed_tables = Set(Int32).new
      @claimed_priorities = Set(Int32).new
    end

    private def rebalance_ips(service_info : ServiceInfo) : Nil
      nodes = service_info.nodes.values
      return if nodes.size < 2

      # Keep rebalancing until no beneficial moves remain
      loop do
        # Find the best supplied node
        most_supplied_node = nodes.max_by?(&.quota_deviation)

        # Stop if we found no donor
        break unless most_supplied_node

        # Find the least supplied node that is not at capacity
        least_supplied_node = nodes.reject { |node| node == most_supplied_node || node.at_capacity? }.min_by?(&.quota_deviation)

        # Stop if we found no recipient
        break unless least_supplied_node

        # Stop if move would not reduce quota deviation
        break if most_supplied_node.quota_deviation <= least_supplied_node.quota_deviation(1)

        # Move IP
        ip = most_supplied_node.remove_last_ip
        least_supplied_node.add_ip(ip)
      end
    end

    # Allocate firewall mark, route table, and routing policy rule priority for each VipAddress.
    # Existing VipAddresses that already have values keep them; new ones get the lowest free index.
    # Allocation is global across all networks, using base values from the VipConfig singleton.
    private def allocate_route_resources(vip_addresses : Hash(String, VipAddressInfo)) : Nil
      config = @config
      return unless config

      max_count = config.max_address_count
      base_fwmark = config.firewall_mark
      base_table = config.route_table
      base_priority = config.routing_priority

      vip_addresses.each_value do |info|
        allocate_single_route_resource(info,
          max_count: max_count, base_fwmark: base_fwmark, base_table: base_table, base_priority: base_priority)
      end
    end

    # Allocates firewall mark, route table, and routing policy rule priority
    # for a single VipAddressInfo that lacks any of these values.
    private def allocate_single_route_resource(
      info : VipAddressInfo, *,
      max_count : Int32,
      base_fwmark : Int32, base_table : Int32, base_priority : Int32,
    ) : Nil
      # Preserve existing allocations
      return if info.firewall_mark && info.route_table && info.routing_priority

      # Allocate lowest free firewall mark
      fwmark = (0...max_count).each do |offset|
        candidate = base_fwmark + offset
        break candidate unless @claimed_fwmarks.includes?(candidate)
      end

      # Allocate lowest free route table
      route_table = (0...max_count).each do |offset|
        candidate = base_table + offset
        break candidate unless @claimed_tables.includes?(candidate)
      end

      # Allocate lowest free routing policy rule priority
      priority = (0...max_count).each do |offset|
        candidate = base_priority + offset
        break candidate unless @claimed_priorities.includes?(candidate)
      end

      if fwmark.is_a?(Int32) && route_table.is_a?(Int32) && priority.is_a?(Int32)
        info.firewall_mark = fwmark
        info.route_table = route_table
        info.routing_priority = priority
        @claimed_fwmarks << fwmark
        @claimed_tables << route_table
        @claimed_priorities << priority
      else
        Log.warn { "No free firewall mark, route table, or priority for VipAddress #{info.name}" }
      end
    end

    private def per_node_cap : Int32
      config = @config
      return 0 unless config

      fwmark_cap = IpAllocator.fwmark_capacity(config.firewall_mark_mask)
      return 0 if fwmark_cap == 0

      Math.min(config.max_address_count, fwmark_cap)
    end

    # Create an VipAddress resource from an VipAddressInfo
    private def create_vip_address_resource(info : VipAddressInfo) : Model::VipAddress
      # Look up VipNetwork
      vip_network = @vip_networks[info.network]

      # Create owner reference to Service
      service_owner_ref = Model::OwnerReference.new(
        api_version: "v1",
        kind: "Service",
        name: info.service_name.name,
        uid: info.service_uid,
        controller: true,
        block_owner_deletion: true
      )

      # Create owner reference to VipNetwork
      network_owner_ref = Model::OwnerReference.new(
        api_version: "netwrangler.dev/v1",
        kind: "VipNetwork",
        name: vip_network.metadata.name!,
        uid: vip_network.metadata.uid!,
        controller: false,
        block_owner_deletion: true
      )

      metadata = Model::ObjectMeta.new(
        name: info.name.name,
        namespace: info.service_name.namespace,
        labels: {
          LABEL_MANAGED   => @manager_name,
          LABEL_NAMESPACE => info.service_name.namespace,
          LABEL_NETWORK   => info.network,
          LABEL_SERVICE   => info.service_name.name,
          LABEL_NODE_NAME => info.node_name!,
        },
        owner_references: [service_owner_ref, network_owner_ref]
      )

      spec = Model::VipAddress::Spec.new(
        network: info.network,
        node_name: info.node_name!,
        virtual_cidr: info.virtual_cidr.to_s,
        interface: info.interface,
        gateway_ip: info.gateway_ip.try(&.to_s),
        firewall_mark: info.firewall_mark,
        route_table: info.route_table,
        routing_priority: info.routing_priority,
        egress_enabled: info.egress_enabled,
        endpoint_ips: info.endpoint_ips,
        source_cidrs: info.source_cidrs.map(&.to_s),
        ports: info.ports
      )

      Model::VipAddress.new(metadata: metadata, spec: spec)
    end

    # Create an ObjectReference for an VipAddress resource to be deleted
    private def create_vip_address_reference(vip_address : Model::VipAddress) : Model::ObjectReference
      Model::ObjectReference.new(
        kind: "VipAddress",
        namespace: vip_address.metadata.namespace,
        name: vip_address.metadata.name,
        api_version: "netwrangler.dev/v1"
      )
    end
  end
end
