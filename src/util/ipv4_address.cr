module Netwrangler::Util
  # Immutable value type for a single IPv4 host address.
  # Comparable so it can be used in ranges and sorted collections.
  record IPv4Address, value : UInt32 do
    include Comparable(IPv4Address)

    # Parses a dotted-quad IPv4 string (e.g., "10.0.1.1") into an IPv4Address.
    # Leading zeros in octets are allowed (e.g., "010.000.001.001").
    # Raises ArgumentError on invalid input.
    def self.parse(ip : String) : IPv4Address
      octets = ip.split('.')

      unless octets.size == 4
        raise ArgumentError.new("Invalid IPv4 address '#{ip}': expected 4 octets, got #{octets.size}")
      end

      value = 0_u32

      octets.each_with_index do |octet_str, i|
        if octet_str.empty?
          raise ArgumentError.new("Invalid IPv4 address '#{ip}': empty octet at position #{i + 1}")
        end

        unless octet_str.each_char.all?(&.ascii_number?)
          raise ArgumentError.new("Invalid IPv4 address '#{ip}': non-numeric octet '#{octet_str}' at position #{i + 1}")
        end

        octet = octet_str.to_u32

        if octet > 255
          raise ArgumentError.new("Invalid IPv4 address '#{ip}': octet #{octet} at position #{i + 1} exceeds 255")
        end

        value = (value << 8) | octet
      end

      IPv4Address.new(value)
    end

    def <=>(other : IPv4Address) : Int32
      value <=> other.value
    end

    def to_s(io : IO) : Nil
      io << ((value >> 24) & 0xFF) << '.' << ((value >> 16) & 0xFF) << '.'
      io << ((value >> 8) & 0xFF) << '.' << (value & 0xFF)
    end
  end
end
