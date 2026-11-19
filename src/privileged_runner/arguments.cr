require "./address_syntax"
require "./json_check"
require "./refusal"

class Netwrangler::PrivilegedRunner
  # The arguments each tool accepts: exactly what the agent passes, and
  # nothing else. The tools run with network capabilities, and
  # `ip netns exec`, `ip -batch`, `nft -f` or `wg set … private-key` would turn
  # those into running a command or reading a file of the caller's choice.
  #
  # Each check returns when it accepts the arguments and raises a `Refusal`
  # otherwise.
  module Arguments
    # `ip` objects and the verbs the agent uses on each
    IP_COMMANDS = {
      "addr"  => %w[show add del],
      "route" => %w[show get replace del flush],
      "rule"  => %w[show add del],
      "link"  => %w[show],
    }

    # `ip` options that only change how it prints
    IP_OPTIONS = %w[--json -d]

    # `ip` values the agent never passes that change what a route does:
    # `encap` would hand the route's packets to a tunnel or a BPF program
    IP_REFUSED_VALUES = %w[encap]

    # Longest interface name Linux allows: `IFNAMSIZ` less the terminating NUL
    MAXIMUM_INTERFACE_NAME_LENGTH = 15

    # Length of a WireGuard key in base64: 32 bytes, 43 characters and one `=`
    PUBLIC_KEY_LENGTH = 44

    # Longest prefix of an IPv4 and of an IPv6 network
    IPV4_PREFIX_LENGTH =  32
    IPV6_PREFIX_LENGTH = 128

    # Characters of a value besides ASCII letters and digits
    VALUE_PUNCTUATION = "._:/@+,-"

    # Characters of an interface name besides ASCII letters and digits
    INTERFACE_PUNCTUATION = "._-"

    # Characters of base64 besides ASCII letters and digits
    BASE64_PUNCTUATION = "+/"

    # Accepts `-V` alone, or leading output options, an object, one of its
    # verbs, and values
    def self.check_ip(arguments : Array(String)) : Nil
      check_encoding(arguments)
      return if arguments == ["-V"]

      options = arguments.take_while { |argument| IP_OPTIONS.includes?(argument) }.size
      command = arguments[options..]
      raise Refusal.new("needs an object and a verb") if command.empty?
      raise Refusal.not_allowed(command[0]) if command.size == 1

      check_ip_command(command[0], command[1])
      command[2..].each { |value| check_ip_value(value) }
    end

    private def self.check_ip_command(object : String, verb : String) : Nil
      verbs = IP_COMMANDS[object]?
      raise Refusal.not_allowed(object) if verbs.nil?
      raise Refusal.not_allowed(verb) unless verbs.includes?(verb)
    end

    private def self.check_ip_value(value : String) : Nil
      raise Refusal.not_allowed(value) if IP_REFUSED_VALUES.includes?(value)

      check_value(value)
    end

    # Accepts `--version`, `show <interface> allowed-ips`, and
    # `set <interface> peer <public key> allowed-ips <networks>`
    def self.check_wg(arguments : Array(String)) : Nil
      check_encoding(arguments)
      return if arguments == ["--version"]

      if wg_show?(arguments)
        check_interface(arguments[1])
      elsif wg_set?(arguments)
        check_interface(arguments[1])
        check_public_key(arguments[3])
        check_networks(arguments[5])
      else
        raise Refusal.new(
          "only --version, show <interface> allowed-ips and " \
          "set <interface> peer <key> allowed-ips <networks> are allowed"
        )
      end
    end

    private def self.wg_show?(arguments : Array(String)) : Bool
      shown = arguments.size == 3 && arguments[0] == "show" && arguments[2] == "allowed-ips"

      shown
    end

    private def self.wg_set?(arguments : Array(String)) : Bool
      set = arguments.size == 6 && arguments[0] == "set" && arguments[2] == "peer" && arguments[4] == "allowed-ips"

      set
    end

    # The arping options the agent sends a gratuitous ARP with, as far as a
    # call has given them
    private class ArpingCall
      property? unsolicited = false
      property? count = false
      property? interface = false
      property? target = false

      def complete? : Bool
        complete = unsolicited? && count? && interface? && target?

        complete
      end
    end

    # Accepts `-V` alone, or `-U`, `-c <count>`, `-I <interface>` and one
    # IPv4 address, each once, in any order
    def self.check_arping(arguments : Array(String)) : Nil
      check_encoding(arguments)
      return if arguments == ["-V"]

      call = ArpingCall.new
      remaining = arguments.each
      loop do
        argument = remaining.next
        break if argument.is_a?(Iterator::Stop)

        take_arping_argument(call, argument, remaining)
      end
      raise Refusal.new("needs -U, -c <count>, -I <interface> and an IPv4 address") unless call.complete?
    end

    private def self.take_arping_argument(call : ArpingCall, argument : String, remaining : Iterator(String)) : Nil
      if argument == "-U" && !call.unsolicited?
        call.unsolicited = true
      elsif argument == "-c" && !call.count?
        check_count(next_value(remaining))
        call.count = true
      elsif argument == "-I" && !call.interface?
        check_interface(next_value(remaining))
        call.interface = true
      elsif !call.target? && !argument.starts_with?('-')
        check_ipv4_address(argument)
        call.target = true
      else
        raise Refusal.not_allowed(argument)
      end
    end

    # The value after an option, empty when the option is the last argument
    private def self.next_value(remaining : Iterator(String)) : String
      value = remaining.next
      text = value.is_a?(String) ? value : ""

      text
    end

    # Accepts `--version` or `-v` alone, or `-j` followed by either `list` and
    # values, or exactly one argument that is one JSON object, the command
    # document
    def self.check_nft(arguments : Array(String)) : Nil
      check_encoding(arguments)
      return if arguments == ["--version"] || arguments == ["-v"]

      if arguments.size > 2 && arguments[0] == "-j" && arguments[1] == "list"
        arguments[2..].each { |value| check_value(value) }
      elsif arguments.size != 2 || arguments[0] != "-j" || !JsonCheck.object?(arguments[1])
        raise Refusal.new("only --version, -v, -j list <values> and -j <JSON object> are allowed")
      end
    end

    # Every allowed argument is ASCII, so one that is not UTF-8 is refused here
    # and the checks work on text
    private def self.check_encoding(arguments : Array(String)) : Nil
      invalid = arguments.find { |argument| !argument.valid_encoding? }
      raise Refusal.not_allowed(invalid.scrub) if invalid
    end

    # A plain word: never an option, and nothing a shell or a tool would read
    # specially
    private def self.check_value(value : String) : Nil
      valid = !value.empty? && !value.starts_with?('-') && made_of?(value, VALUE_PUNCTUATION)
      raise Refusal.not_allowed(value) unless valid
    end

    private def self.check_interface(name : String) : Nil
      valid = (1..MAXIMUM_INTERFACE_NAME_LENGTH).includes?(name.bytesize) &&
              !name.starts_with?('-') &&
              made_of?(name, INTERFACE_PUNCTUATION)
      raise Refusal.new("not an interface name: #{name}") unless valid
    end

    private def self.check_public_key(key : String) : Nil
      encoded = key.rchop?('=')
      valid = key.bytesize == PUBLIC_KEY_LENGTH && !encoded.nil? && made_of?(encoded, BASE64_PUNCTUATION)
      raise Refusal.new("not a public key: #{key}") unless valid
    end

    # An empty list removes a peer's last allowed IP, which the agent does when
    # the peer loses its last managed network
    private def self.check_networks(networks : String) : Nil
      return if networks.empty?

      networks.split(',').each { |network| check_network(network) }
    end

    # An IPv4 or IPv6 network or address. The agent manages IPv4 networks
    # only, but keeps the peer's other entries, IPv6 ones included, as it
    # rewrites the whole list.
    private def self.check_network(network : String) : Nil
      address, slash, prefix_length = network.partition('/')
      longest = if AddressSyntax.ipv4?(address)
                  IPV4_PREFIX_LENGTH
                elsif AddressSyntax.ipv6?(address)
                  IPV6_PREFIX_LENGTH
                end
      valid = !longest.nil? && (slash.empty? || prefix_length_within?(prefix_length, longest))
      raise Refusal.new("not an IP network: #{network}") unless valid
    end

    # Digits only: a conversion would also take a sign or whitespace
    private def self.prefix_length_within?(text : String, longest : Int32) : Bool
      length = digits?(text) ? text.to_u8?(whitespace: false) : nil
      within = !length.nil? && length <= longest

      within
    end

    private def self.check_count(text : String) : Nil
      count = digits?(text) ? text.to_u32?(whitespace: false) : nil
      raise Refusal.new("not a count: #{text}") if count.nil?
    end

    private def self.check_ipv4_address(text : String) : Nil
      raise Refusal.new("not an IPv4 address: #{text}") unless AddressSyntax.ipv4?(text)
    end

    private def self.digits?(text : String) : Bool
      digits = !text.empty? && text.each_char.all?(&.ascii_number?)

      digits
    end

    # Whether +text+ holds only ASCII letters, digits and +punctuation+
    private def self.made_of?(text : String, punctuation : String) : Bool
      made_of = text.each_char.all? { |character| character.ascii_alphanumeric? || punctuation.includes?(character) }

      made_of
    end
  end
end
