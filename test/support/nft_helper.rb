# frozen_string_literal: true

module IntegrationTest
  # Helper methods for reading the netwrangler nftables table of a kind node
  # through `nft -j`. They need KindHelper#kind_exec.
  module NftHelper
    # Objects of one kind, such as "map" or "rule", in an `nft -j` listing
    #
    # @param node [String] node name
    # @param command [String] nft command after `nft -j`
    # @param kind [String] object kind
    # @return [Array<Hash>] the objects, none when the listing fails
    def nft_json(node, command, kind)
      result = kind_exec(node, "nft -j #{command}")
      return [] unless result.success?

      JSON.parse(result.message).fetch("nftables").filter_map { |item| item[kind] }
    rescue JSON::ParserError
      []
    end

    # Get the elements of a netwrangler mark map
    #
    # @param node [String] node name
    # @param map_name [String] mark map name (e.g., "ingress-marks-ipv4")
    # @return [Array<Hash>] {ip:, source_cidr:, mark:} hashes; source_cidr is
    #   nil in a default map
    def get_map_entries(node, map_name)
      map = nft_json(node, "list map ip netwrangler #{map_name}", "map").first
      return [] unless map

      (map["elem"] || []).filter_map do |key, mark|
        next unless mark.is_a?(Integer)

        ip, source_cidr = (key.is_a?(Hash) ? key.fetch("concat") : [key]).map do |part|
          part.is_a?(Hash) ? "#{part.dig("prefix", "addr")}/#{part.dig("prefix", "len")}" : part
        end
        { ip: ip, source_cidr: source_cidr, mark: mark }
      end
    end

    # Wait for a mark map element to appear for an IP
    #
    # @param node [String] node name
    # @param map_name [String] mark map name (e.g., "ingress-marks-ipv4")
    # @param ip [String] expected IP address
    # @param mark [Integer] expected firewall mark
    # @param timeout [Integer] maximum seconds to wait (default: 30)
    # @return [Boolean] true if entry appeared
    def wait_for_map_entry(node, map_name, ip, mark, timeout: 30)
      timeout.times do
        entries = get_map_entries(node, map_name)
        return true if entries.any? { |e| e[:ip] == ip && e[:mark] == mark }

        sleep 3
      end

      false
    end

    # Wait for all map entries to be removed for an IP
    #
    # @param node [String] node name
    # @param map_name [String] mark map name (e.g., "ingress-marks-ipv4")
    # @param ip [String] IP address expected to be removed
    # @param timeout [Integer] maximum seconds to wait (default: 30)
    # @return [Boolean] true if entries were removed
    def wait_for_map_entry_removal(node, map_name, ip, timeout: 30)
      timeout.times do
        entries = get_map_entries(node, map_name)
        return true unless entries.any? { |e| e[:ip] == ip }

        sleep 3
      end

      false
    end

    # The maps that `map` or `vmap` lookups name anywhere in a rule expression
    #
    # @param node [Object] parsed nft JSON
    # @param kind [String] "map" or "vmap"
    # @return [Array<String>] map references such as "@ingress-marks-ipv4"
    def map_lookups(node, kind: "map")
      case node
      when Array then node.flat_map { |element| map_lookups(element, kind: kind) }
      when Hash
        node.flat_map do |name, value|
          nested = map_lookups(value, kind: kind)
          name == kind && value.is_a?(Hash) && value["data"] ? [value["data"], *nested] : nested
        end
      else []
      end
    end

    # Rules of a chain that set the firewall mark from a mark map
    #
    # @param node [String] node name
    # @param chain_name [String] nftables chain name
    # @param map_name [String] mark map name
    # @return [Array<Hash>] the rules in nft's JSON format, with handles
    def mark_rules(node, chain_name, map_name)
      nft_json(node, "list chain ip netwrangler #{chain_name}", "rule").select do |rule|
        map_lookups(rule["expr"]).include?("@#{map_name}")
      end
    end

    # Rules of a chain that still dispatch to a verdict map
    #
    # @param node [String] node name
    # @param chain_name [String] nftables chain name
    # @return [Array<Hash>] the rules in nft's JSON format
    def vmap_rules(node, chain_name)
      rules = nft_json(node, "list chain ip netwrangler #{chain_name}", "rule")
      rules.reject { |rule| map_lookups(rule["expr"], kind: "vmap").empty? }
    end

    # The packet fields a mark rule looks up, in nft's text syntax
    #
    # @param rule [Hash] rule in nft's JSON format
    # @return [Array<String>] fields such as "ct original ip saddr"
    def mark_rule_fields(rule)
      mangle = rule["expr"].find { |statement| statement["mangle"] }
      key = mangle&.dig("mangle", "value", "|", 1, "map", "key")
      return [] unless key

      (key["concat"] || [key]).map do |field|
        field["ct"] ? "ct #{field.dig("ct", "dir")} #{field.dig("ct", "key")}" : "ip #{field.dig("payload", "field")}"
      end
    end

    # The bits a mark rule keeps from the packet's mark
    #
    # @param rule [Hash] rule in nft's JSON format
    # @return [Integer, nil] the inverted firewall mark mask
    def mark_rule_kept_bits(rule)
      mangle = rule["expr"].find { |statement| statement["mangle"] }
      mangle&.dig("mangle", "value", "|", 0, "&", 1)
    end

    # Whether a rule skips packets to the gateway destinations
    #
    # @param rule [Hash] rule in nft's JSON format
    # @return [Boolean]
    def egress_guarded?(rule)
      rule["expr"].any? do |statement|
        statement.dig("match", "op") == "!=" && statement.dig("match", "right") == "@gateway-destinations"
      end
    end

    # Wait for a chain to hold a mark rule for a map, optionally one the block accepts
    #
    # @param node [String] node name
    # @param chain_name [String] nftables chain name
    # @param map_name [String] mark map name
    # @param timeout [Integer] maximum seconds to wait (default: 30)
    # @yieldparam rule [Hash] rule in nft's JSON format
    # @return [Boolean] true if such a rule appeared
    def wait_for_mark_rule(node, chain_name, map_name, timeout: 30)
      timeout.times do
        return true if mark_rules(node, chain_name, map_name).any? { |rule| !block_given? || yield(rule) }

        sleep 3
      end

      false
    end

    # The per-VIP mark chains that verdict maps dispatched to before mark maps
    #
    # @param node [String] node name
    # @return [Array<String>] chain names
    def mark_chains(node)
      nft_json(node, "list chains ip", "chain").filter_map do |chain|
        chain["name"] if chain["table"] == "netwrangler" && chain["name"].start_with?("mark-")
      end
    end

    # Handles of the mark rules of a chain for a map
    #
    # @param node [String] node name
    # @param chain_name [String] nftables chain name
    # @param map_name [String] mark map name
    # @return [Array<Integer>] rule handles
    def mark_rule_handles(node, chain_name, map_name)
      mark_rules(node, chain_name, map_name).map { |rule| rule["handle"] }
    end
    # Get the elements of the SNAT map
    #
    # @param node [String] node name
    # @return [Array<Hash>] array of {mark_hex:, interface:, vip_address:} hashes
    def get_snat_entries(node)
      map = nft_json(node, "list map ip netwrangler snat-addresses", "map").first
      return [] unless map

      (map["elem"] || []).filter_map do |key, vip_address|
        mark, interface = key.is_a?(Hash) ? key["concat"] : []
        next unless mark.is_a?(Integer)

        { mark_hex: format("0x%08x", mark), interface: interface, vip_address: vip_address }
      end
    end

    # Wait for an SNAT map entry to appear
    #
    # @param node [String] node name
    # @param vip_address [String] expected VIP address in map
    # @param timeout [Integer] maximum seconds to wait (default: 30)
    # @return [Boolean] true if entry appeared
    def wait_for_snat_entry(node, vip_address, timeout: 30)
      timeout.times do
        entries = get_snat_entries(node)
        return true if entries.any? { |e| e[:vip_address] == vip_address }

        sleep 3
      end

      false
    end


    # Wait for an SNAT map entry to be removed
    #
    # @param node [String] node name
    # @param vip_address [String] VIP address expected to be removed
    # @param timeout [Integer] maximum seconds to wait (default: 30)
    # @return [Boolean] true if entry was removed
    def wait_for_snat_entry_removal(node, vip_address, timeout: 30)
      timeout.times do
        entries = get_snat_entries(node)
        return true unless entries.any? { |e| e[:vip_address] == vip_address }

        sleep 3
      end

      false
    end


    # Check if the nat-postrouting chain has an SNAT rule
    #
    # @param node [String] node name
    # @return [Boolean] true if a rule source-NATs through the SNAT map
    def has_snat_rule?(node)
      nft_json(node, "list chain ip netwrangler nat-postrouting", "rule").any? do |rule|
        rule["expr"].any? { |statement| statement["snat"] } && map_lookups(rule["expr"]).include?("@snat-addresses")
      end
    end

    # Get cluster-networks set elements from a node
    #
    # @param node [String] node name
    # @return [Array<String>] networks in the set, a single address without its length
    def get_cluster_network_entries(node)
      set_networks(node, "cluster-networks")
    end

    # The networks of a set in the netwrangler table
    #
    # @param node [String] node name
    # @param set_name [String] set name
    # @return [Array<String>] networks as CIDRs, a single address without its length
    def set_networks(node, set_name)
      set = nft_json(node, "list set ip netwrangler #{set_name}", "set").first
      (set&.fetch("elem", nil) || []).map do |element|
        element.is_a?(Hash) ? "#{element.dig("prefix", "addr")}/#{element.dig("prefix", "len")}" : element
      end
    end

    # Wait for a cluster-networks set element to appear
    #
    # @param node [String] node name
    # @param cidr [String] expected CIDR
    # @param timeout [Integer] maximum seconds to wait
    # @return [Boolean] true if element appeared
    def wait_for_cluster_network_entry(node, cidr, timeout: 30)
      timeout.times do
        entries = get_cluster_network_entries(node)
        return true if entries.include?(cidr)

        sleep 3
      end

      false
    end


    # Check if a chain has a cluster-networks return rule
    #
    # @param node [String] node name
    # @param chain_name [String] nftables chain name
    # @return [Boolean]
    def has_cluster_networks_rule?(node, chain_name)
      nft_json(node, "list chain ip netwrangler #{chain_name}", "rule").any? do |rule|
        rule["expr"].any? { |statement| statement.dig("match", "right") == "@cluster-networks" } &&
          rule["expr"].include?({ "return" => nil })
      end
    end

    # Get gateway-destinations set elements from a node
    #
    # @param node [String] node name
    # @return [Array<String>] networks in the set, a single address without its length
    def get_gateway_destination_entries(node)
      set_networks(node, "gateway-destinations")
    end

    # Wait for a gateway-destinations set element to appear
    #
    # @param node [String] node name
    # @param cidr [String] expected CIDR
    # @param timeout [Integer] maximum seconds to wait
    # @return [Boolean] true if element appeared
    def wait_for_gateway_destination_entry(node, cidr, timeout: 30)
      timeout.times do
        return true if get_gateway_destination_entries(node).include?(cidr)

        sleep 3
      end

      false
    end

  end
end
