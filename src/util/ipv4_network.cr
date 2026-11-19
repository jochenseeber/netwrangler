require "./ipv4_address"

module Netwrangler::Util
  # Immutable value type for a CIDR network (address + prefix length).
  # Provides containment checks and address ranges for overlap detection.
  record IPv4Network, address : IPv4Address, prefix : Int32 do
    # Parses a CIDR string (e.g., "10.0.1.0/24") into an IPv4Network.
    # Raises ArgumentError on invalid input.
    def self.parse(cidr : String) : IPv4Network
      parts = cidr.split('/')

      unless parts.size == 2
        raise ArgumentError.new("Invalid CIDR '#{cidr}': expected format 'address/prefix'")
      end

      address = IPv4Address.parse(parts[0])

      begin
        prefix = parts[1].to_i
      rescue ArgumentError
        raise ArgumentError.new("Invalid CIDR '#{cidr}': non-numeric prefix '#{parts[1]}'")
      end

      unless prefix >= 0 && prefix <= 32
        raise ArgumentError.new("Invalid CIDR '#{cidr}': prefix #{prefix} must be 0-32")
      end

      IPv4Network.new(address, prefix)
    end

    # Returns the subnet mask as a 32-bit unsigned integer.
    def mask : UInt32
      prefix == 0 ? 0_u32 : (~0_u32) << (32 - prefix)
    end

    # Checks whether the given IPv4 address falls within this network.
    def contains?(ip : IPv4Address) : Bool
      (ip.value & mask) == (address.value & mask)
    end

    # Returns the first (network) address in this CIDR range.
    def first_address : IPv4Address
      IPv4Address.new(address.value & mask)
    end

    # Returns the last (broadcast) address in this CIDR range.
    def last_address : IPv4Address
      IPv4Address.new((address.value & mask) | ~mask)
    end

    # Returns the range of addresses in this network, usable for overlap detection.
    def address_range : Range(IPv4Address, IPv4Address)
      first_address..last_address
    end

    # Returns this network with the host bits cleared (10.0.1.10/24 becomes 10.0.1.0/24).
    def canonical : IPv4Network
      IPv4Network.new(first_address, prefix)
    end

    # Checks whether this network and the other share at least one address.
    def overlaps?(other : IPv4Network) : Bool
      contains?(other.first_address) || other.contains?(first_address)
    end

    def to_s(io : IO) : Nil
      address.to_s(io)
      io << '/' << prefix
    end
  end
end
