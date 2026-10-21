require "../util/ipv4_address"

module Netwrangler::Agent
  # Updates IP addresses on network interfaces
  class AddressUpdater
    Log = ::Log.for(self)

    # Model for ip addr JSON output
    class IpAddrOutput
      include JSON::Serializable

      @[JSON::Field(key: "ifname")]
      getter ifname : String = ""

      @[JSON::Field(key: "addr_info")]
      getter addr_info : Array(AddrInfo) = [] of AddrInfo
    end

    class AddrInfo
      include JSON::Serializable

      @[JSON::Field(key: "family")]
      getter family : String

      @[JSON::Field(key: "local")]
      getter local : String

      @[JSON::Field(key: "prefixlen")]
      getter prefixlen : Int32

      @[JSON::Field(key: "label")]
      getter label : String?
    end

    # Label prefix used to identify VIP-managed addresses
    VIP_LABEL_PREFIX = "vip:"

    # Represents a desired IP address with its prefix length
    record DesiredAddress, ip : Util::IPv4Address, prefix : Int32

    def initialize(@debug : Bool = false)
      @pending_announcements = [] of Channel(Nil)
    end

    # Adds missing IP addresses on an interface
    # Adds IPs not yet present, or present with wrong prefix length
    # @param interface The network interface to update
    # @param desired_addresses An array of desired IP addresses with their prefix lengths
    def add(interface : String, *, desired_addresses : Array(DesiredAddress)) : Nil
      existing_ips = vip_labeled_ipv4_addresses(interface)

      desired_addresses.each do |desired|
        ip_str = desired.ip.to_s
        prefix_str = desired.prefix.to_s
        existing_prefix = existing_ips[ip_str]?
        next if existing_prefix && existing_prefix.to_s == prefix_str

        label = "#{VIP_LABEL_PREFIX}#{prefix_str}"
        Log.info { "Adding IP #{ip_str}/#{prefix_str} to interface #{interface} with label #{label}" }
        Util::Command.new(Util::IP, args: ["addr", "add", "#{ip_str}/#{prefix_str}", "dev", interface, "label", label]).run
        send_arp_announcement(interface, ip_str)
      end
    rescue ex
      raise Exception.new("Error adding IP addresses for interface #{interface}: #{ex.message}", cause: ex)
    end

    # Removes obsolete or mismatched IP addresses from an interface
    # Removes IPs not in the desired set, and IPs with wrong prefix length
    # @param interface The network interface to update
    # @param desired_addresses An array of desired IP addresses with their prefix lengths
    def remove(interface : String, *, desired_addresses : Array(DesiredAddress)) : Nil
      existing_ips = vip_labeled_ipv4_addresses(interface)
      desired_by_ip = desired_addresses.each_with_object(Hash(String, Int32).new) do |desired, hash|
        hash[desired.ip.to_s] = desired.prefix
      end

      existing_ips.each do |ip, prefixlen|
        desired_prefix = desired_by_ip[ip]?
        next if desired_prefix && prefixlen == desired_prefix

        Log.info { "Removing IP #{ip}/#{prefixlen} from interface #{interface}" }
        Util::Command.new(Util::IP, args: ["addr", "del", "#{ip}/#{prefixlen}", "dev", interface]).run
      end
    rescue ex
      raise Exception.new("Error removing IP addresses for interface #{interface}: #{ex.message}", cause: ex)
    end

    # Returns the set of interface names that currently have VIP-labeled addresses
    def managed_interfaces : Set(String)
      result = Util::Command.new(Util::IP, args: ["--json", "addr", "show"], allowed_exit_codes: [0, 1]).run
      return Set(String).new unless result.success?

      interfaces = Array(IpAddrOutput).from_json(result.stdout)
      interfaces
        .select { |iface| iface.addr_info.any? { |addr| addr.family == "inet" && addr.label.try(&.starts_with?(VIP_LABEL_PREFIX)) } }
        .map(&.ifname)
        .to_set
    end

    # Waits for all background ARP announcements to complete
    def wait_for_announcements : Nil
      @pending_announcements.each(&.receive)
      @pending_announcements.clear
    end

    # Sends 3 gratuitous ARP announcements for a VIP address in the background
    private def send_arp_announcement(interface : String, ip : String) : Nil
      Log.info { "Sending ARP announcements for #{ip} on #{interface}" }
      done = Channel(Nil).new
      @pending_announcements << done
      spawn do
        Util::Command.new(Util::ARPING, args: ["-U", "-c", "3", "-I", interface, ip],
          allowed_exit_codes: [0, 1]).run
      rescue ex
        Log.error { "ARP announcement failed for #{ip} on #{interface}: #{ex.message}" }
      ensure
        done.send(nil)
      end
    end

    # Returns VIP-labeled IPv4 addresses currently configured on the interface
    # @return A hash mapping IP addresses to their prefix lengths
    private def vip_labeled_ipv4_addresses(interface : String) : Hash(String, Int32)
      result = Util::Command.new(Util::IP, args: ["--json", "addr", "show", "dev", interface], allowed_exit_codes: [0, 1]).run
      return Hash(String, Int32).new unless result.success?

      interfaces = Array(IpAddrOutput).from_json(result.stdout)
      return Hash(String, Int32).new if interfaces.empty?

      addresses = Hash(String, Int32).new
      interfaces.first.addr_info
        .select { |addr| addr.family == "inet" && addr.label.try(&.starts_with?(VIP_LABEL_PREFIX)) }
        .each { |addr| addresses[addr.local] = addr.prefixlen }
      addresses
    end
  end
end
