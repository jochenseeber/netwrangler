require "json"
require "../util/ipv4_network"

module Netwrangler::Agent
  # Manages WireGuard allowed IPs based on resolved pod routes.
  # When the outgoing interface for a pod route is a WireGuard interface,
  # the destination IP must be in the correct peer's allowed IPs.
  # Tracks managed destinations in a state file for cleanup across invocations.
  class WireguardUpdater
    Log = ::Log.for(self)

    STATE_FILE = "/tmp/shell-operator/wireguard-managed.json"

    # Represents a WireGuard peer with its public key and allowed IPs
    record PeerInfo, public_key : String, allowed_ips : Array(String)

    def initialize(@debug : Bool = false)
    end

    # Checks if an interface is a WireGuard interface
    def wireguard_interface?(iface : String) : Bool
      result = Util::Command.new(Util::WG, args: ["show", iface], allowed_exit_codes: [0, 1]).run
      result.success?
    end

    # Ensures the destination IP is in the correct peer's allowed IPs.
    # The correct peer is found by matching the pod IP against existing
    # allowed IP networks.
    def ensure_allowed_ip(iface : String, *, destination_cidr : Util::IPv4Network, pod_ip : Util::IPv4Address) : Nil
      peers = discover_peers(iface)
      peer = find_peer_for_pod(pod_ip, peers: peers)

      unless peer
        Log.warn { "No WireGuard peer found for pod #{pod_ip} on #{iface}" }
        return
      end

      # Already present on correct peer
      return if allowed_ips_include?(peer.allowed_ips, destination_cidr)

      # Remove from wrong peer if present elsewhere
      peers.each do |other_peer|
        next if other_peer.public_key == peer.public_key
        next unless allowed_ips_include?(other_peer.allowed_ips, destination_cidr)

        new_ips = reject_allowed_ip(other_peer.allowed_ips, destination_cidr).join(",")
        Log.info { "Moving #{destination_cidr} from WireGuard peer #{other_peer.public_key} on #{iface}" }
        Util::Command.new(Util::WG, args: ["set", iface, "peer", other_peer.public_key, "allowed-ips", new_ips]).run
      end

      # Add to correct peer
      new_ips = (peer.allowed_ips + [destination_cidr.to_s]).join(",")
      Log.info { "Adding #{destination_cidr} to WireGuard peer #{peer.public_key} on #{iface}" }
      Util::Command.new(Util::WG, args: ["set", iface, "peer", peer.public_key, "allowed-ips", new_ips]).run
    end

    # Removes a destination IP from all peers on all WireGuard interfaces.
    private def remove_allowed_ip_from_all_interfaces(*, destination_cidr : Util::IPv4Network) : Nil
      interfaces = discover_wireguard_interfaces
      interfaces.each do |iface|
        remove_allowed_ip(iface, destination_cidr: destination_cidr)
      end
    end

    # Removes destinations that were previously managed but are no longer desired.
    # Uses a state file to track which destinations were added by this updater.
    def remove_stale_allowed_ips(*, desired_destinations : Set(String)) : Nil
      previously_managed = load_state
      stale = previously_managed - desired_destinations

      stale.each do |dest|
        remove_allowed_ip_from_all_interfaces(destination_cidr: Util::IPv4Network.parse(dest))
      end

      save_state(desired_destinations)
    end

    # Saves the current set of managed destinations after ensure_allowed_ip calls.
    # Should be called after all ensure_allowed_ip calls for this reconciliation.
    def save_managed_destinations(destinations : Set(String)) : Nil
      existing = load_state
      save_state(existing | destinations)
    end

    # Removes a destination IP from all peers on the given interface.
    def remove_allowed_ip(iface : String, *, destination_cidr : Util::IPv4Network) : Nil
      peers = discover_peers(iface)

      peers.each do |peer|
        next unless allowed_ips_include?(peer.allowed_ips, destination_cidr)

        new_ips = reject_allowed_ip(peer.allowed_ips, destination_cidr).join(",")
        Log.info { "Removing #{destination_cidr} from WireGuard peer #{peer.public_key} on #{iface}" }
        Util::Command.new(Util::WG, args: ["set", iface, "peer", peer.public_key, "allowed-ips", new_ips]).run
      end
    end

    # Discovers WireGuard peers and their allowed IPs via `wg show <iface> dump`
    def discover_peers(iface : String) : Array(PeerInfo)
      result = Util::Command.new(Util::WG, args: ["show", iface, "dump"], allowed_exit_codes: [0, 1]).run
      return [] of PeerInfo unless result.success?

      peers = [] of PeerInfo
      result.stdout.each_line.skip(1).each do |line|
        fields = line.split("\t")
        next if fields.size < 4

        public_key = fields[0]
        allowed_ips = fields[3].split(",").map(&.strip).reject(&.empty?)
        peers << PeerInfo.new(public_key: public_key, allowed_ips: allowed_ips)
      end

      peers
    end

    # Discovers all WireGuard interface names on the system
    private def discover_wireguard_interfaces : Array(String)
      result = Util::Command.new(Util::WG, args: ["show", "interfaces"], allowed_exit_codes: [0, 1]).run
      return [] of String unless result.success?

      result.stdout.split.map(&.strip).reject(&.empty?)
    end

    # Checks if a peer's allowed IPs contain the given network (parsed comparison)
    private def allowed_ips_include?(allowed_ips : Array(String), network : Util::IPv4Network) : Bool
      allowed_ips.any? do |ip|
        Util::IPv4Network.parse(ip) == network
      rescue ArgumentError
        false
      end
    end

    # Removes a network from an allowed IPs list (parsed comparison)
    private def reject_allowed_ip(allowed_ips : Array(String), network : Util::IPv4Network) : Array(String)
      allowed_ips.reject do |ip|
        Util::IPv4Network.parse(ip) == network
      rescue ArgumentError
        false
      end
    end

    # Finds the peer whose existing allowed IPs contain a network that includes the pod IP
    private def find_peer_for_pod(pod_ip : Util::IPv4Address, *, peers : Array(PeerInfo)) : PeerInfo?
      peers.find do |peer|
        peer.allowed_ips.any? do |allowed_ip|
          network = Util::IPv4Network.parse(allowed_ip)
          network.contains?(pod_ip)
        rescue ArgumentError
          false
        end
      end
    end

    private def load_state : Set(String)
      return Set(String).new unless File.exists?(STATE_FILE)
      Array(String).from_json(File.read(STATE_FILE)).to_set
    rescue ex
      Log.warn { "Failed to load WireGuard state: #{ex.message}" }
      Set(String).new
    end

    private def save_state(destinations : Set(String)) : Nil
      File.write(STATE_FILE, destinations.to_a.to_json)
    rescue ex
      Log.warn { "Failed to save WireGuard state: #{ex.message}" }
    end
  end
end
