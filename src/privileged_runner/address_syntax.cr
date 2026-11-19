class Netwrangler::PrivilegedRunner
  # Whether a text is an IPv4 or IPv6 address, with exactly the grammar of
  # Rust's `Ipv4Addr` and `Ipv6Addr` parsers, which the wrapper this replaced
  # used: dotted decimal octets without leading zeros, and up to eight groups
  # of one to four hex digits with one optional `::` and an optional dotted
  # IPv4 tail. No zone index, no brackets. Hand-written, as the stdlib's
  # parsers live in `Socket` and would pull far more into a binary that runs
  # with capabilities.
  class AddressSyntax
    # Groups of 16 bits in an IPv6 address
    IPV6_GROUPS = 8

    @bytes : Bytes
    @position = 0

    def initialize(text : String)
      @bytes = text.to_slice
    end

    # Whether +text+ is exactly one IPv4 address
    def self.ipv4?(text : String) : Bool
      parser = new(text)
      valid = parser.read_ipv4 && parser.at_end?

      valid
    end

    # Whether +text+ is exactly one IPv6 address
    def self.ipv6?(text : String) : Bool
      parser = new(text)
      valid = parser.read_ipv6 && parser.at_end?

      valid
    end

    protected def at_end? : Bool
      @position == @bytes.size
    end

    # Four decimal octets of at most three digits, each at most 255, without
    # a leading zero
    protected def read_ipv4 : Bool
      read = atomically do
        (0...4).all? do |index|
          separated(index, '.') { read_number(radix: 10, max_digits: 3, zero_prefix: false, maximum: 0xFF) }
        end
      end

      read
    end

    protected def read_ipv6 : Bool
      read = atomically { scan_ipv6 }

      read
    end

    private def scan_ipv6 : Bool
      head_size, head_ipv4 = read_groups(IPV6_GROUPS)
      return true if head_size == IPV6_GROUPS
      # An IPv4 tail ends the address, so it cannot come before `::`
      return false if head_ipv4
      return false unless read_byte(':') && read_byte(':')

      # `::` stands for at least one group of zeros
      read_groups(IPV6_GROUPS - head_size - 1)
      true
    end

    # Reads up to +limit+ colon-separated groups, the last two of which may be
    # one IPv4 address; returns how many groups it read and whether an IPv4
    # address ended them
    private def read_groups(limit : Int32) : {Int32, Bool}
      count = 0
      ipv4 = false
      while count < limit
        if count < limit - 1 && separated(count, ':') { read_ipv4 }
          count += 2
          ipv4 = true
          break
        end
        break unless separated(count, ':') { read_number(radix: 16, max_digits: 4, zero_prefix: true, maximum: 0xFFFF) }

        count += 1
      end

      result = {count, ipv4}
      result
    end

    # Reads the separator unless this is the first item, then the item; leaves
    # the position unchanged when either is missing
    private def separated(index : Int32, separator : Char, & : -> Bool) : Bool
      read = atomically { (index == 0 || read_byte(separator)) && yield }

      read
    end

    private def read_number(*, radix : Int32, max_digits : Int32, zero_prefix : Bool, maximum : Int32) : Bool
      read = atomically { scan_number(radix: radix, max_digits: max_digits, zero_prefix: zero_prefix, maximum: maximum) }

      read
    end

    private def scan_number(*, radix : Int32, max_digits : Int32, zero_prefix : Bool, maximum : Int32) : Bool
      leading_zero = peek == '0'.ord
      value = 0
      digits = 0
      loop do
        digit = digit_value(peek, radix)
        break if digit.nil?

        @position += 1
        value = value * radix + digit
        digits += 1
        return false if value > maximum || digits > max_digits
      end
      return false if digits == 0

      valid = zero_prefix || !leading_zero || digits == 1
      valid
    end

    # The value of an ASCII digit in +radix+ (10 or 16), nil for anything else
    private def digit_value(byte : UInt8?, radix : Int32) : Int32?
      return if byte.nil?

      code = byte.to_i32
      value = case code
              when '0'.ord..'9'.ord then code - '0'.ord
              when 'a'.ord..'f'.ord then code - 'a'.ord + 10
              when 'A'.ord..'F'.ord then code - 'A'.ord + 10
              end
      digit = value.try { |found| found < radix ? found : nil }

      digit
    end

    private def peek : UInt8?
      byte = @bytes[@position]?

      byte
    end

    private def read_byte(expected : Char) : Bool
      return false unless peek == expected.ord

      @position += 1
      true
    end

    # Runs the block and rewinds to where it started when the block fails
    private def atomically(& : -> Bool) : Bool
      start = @position
      read = yield
      @position = start unless read

      read
    end
  end
end
