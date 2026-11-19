class Netwrangler::PrivilegedRunner
  # A strict check that a text is one JSON object.
  #
  # nft tries its JSON parser first and, when that cannot load the text, hands
  # it to its text parser, which recovers from syntax errors at the next `;`
  # and processes `include`. So a document passes only when nft's JSON
  # library, jansson, loads it too: besides the grammar this refuses what
  # jansson refuses, `\u0000`, lone surrogates, integers beyond 64 bits and
  # reals beyond a double. Hand-written rather than the stdlib's `JSON`, which
  # accepts all of those.
  class JsonCheck
    # Deepest nesting accepted; the agent's documents stay far below it, and
    # the recursion stays bounded
    MAXIMUM_DEPTH = 64

    @bytes : Bytes
    @position = 0

    def initialize(text : String)
      @bytes = text.to_slice
    end

    # Whether +text+ is exactly one JSON object, with optional whitespace
    # around it. The text is UTF-8 already: the arguments check refuses one
    # that is not.
    def self.object?(text : String) : Bool
      check = new(text)
      check.skip_whitespace
      valid = check.peek == '{'.ord && check.value?(0)
      check.skip_whitespace

      object = valid && check.at_end?
      object
    end

    protected def at_end? : Bool
      @position == @bytes.size
    end

    protected def peek : UInt8?
      byte = @bytes[@position]?

      byte
    end

    protected def skip_whitespace : Nil
      while {' '.ord, '\t'.ord, '\n'.ord, '\r'.ord}.includes?(peek)
        @position += 1
      end
    end

    protected def value?(depth : Int32) : Bool
      return false if depth > MAXIMUM_DEPTH

      valid = case peek
              when nil     then false
              when '{'.ord then object?(depth + 1)
              when '['.ord then array?(depth + 1)
              when '"'.ord then string?
              when 't'.ord then literal?("true")
              when 'f'.ord then literal?("false")
              when 'n'.ord then literal?("null")
              else              number?
              end

      valid
    end

    private def next_byte : UInt8?
      byte = peek
      @position += 1 unless byte.nil?

      byte
    end

    private def expect?(expected : Char) : Bool
      matched = next_byte == expected.ord

      matched
    end

    private def object?(depth : Int32) : Bool
      return false unless expect?('{')

      skip_whitespace
      closed = peek == '}'.ord ? expect?('}') : members?(depth)
      closed
    end

    # The members of an object, up to and including its closing brace
    private def members?(depth : Int32) : Bool
      separator = ','.ord.to_u8
      while separator == ','.ord
        skip_whitespace
        return false unless string?

        skip_whitespace
        return false unless expect?(':')

        skip_whitespace
        return false unless value?(depth)

        skip_whitespace
        separator = next_byte
      end

      closed = separator == '}'.ord
      closed
    end

    private def array?(depth : Int32) : Bool
      return false unless expect?('[')

      skip_whitespace
      closed = peek == ']'.ord ? expect?(']') : elements?(depth)
      closed
    end

    # The elements of an array, up to and including its closing bracket
    private def elements?(depth : Int32) : Bool
      separator = ','.ord.to_u8
      while separator == ','.ord
        skip_whitespace
        return false unless value?(depth)

        skip_whitespace
        separator = next_byte
      end

      closed = separator == ']'.ord
      closed
    end

    private def literal?(word : String) : Bool
      return false unless @bytes[@position, word.bytesize]? == word.to_slice

      @position += word.bytesize
      true
    end

    # Only control characters and escapes need checking: the text is UTF-8
    private def string? : Bool
      return false unless expect?('"')

      loop do
        byte = next_byte
        return false if byte.nil? || byte < 0x20
        return true if byte == '"'.ord
        return false if byte == '\\'.ord && !escape?
      end
    end

    private def escape? : Bool
      valid = case next_byte
              when '"'.ord, '\\'.ord, '/'.ord, 'b'.ord, 'f'.ord, 'n'.ord, 'r'.ord, 't'.ord
                true
              when 'u'.ord
                unicode_escape?
              else
                false
              end

      valid
    end

    # A `\u` escape: jansson refuses `\u0000` and a surrogate that is not one
    # half of a pair
    private def unicode_escape? : Bool
      valid = case code_unit
              when nil, 0         then false
              when 0xD800..0xDBFF then expect?('\\') && expect?('u') && (0xDC00..0xDFFF).includes?(code_unit || 0)
              when 0xDC00..0xDFFF then false
              else                     true
              end

      valid
    end

    # The four hex digits of a `\u` escape
    private def code_unit : Int32?
      digits = @bytes[@position, 4]?
      return if digits.nil? || !digits.all?(&.unsafe_chr.hex?)

      @position += 4
      unit = String.new(digits).to_i(16)
      unit
    end

    # `-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?`, an integer within 64
    # bits and a real within a double, as jansson loads them
    private def number? : Bool
      start = @position
      @position += 1 if peek == '-'.ord
      return false unless integer_part?

      real = false
      if peek == '.'.ord
        @position += 1
        return false unless digits?

        real = true
      end
      if peek == 'e'.ord || peek == 'E'.ord
        @position += 1
        @position += 1 if peek == '+'.ord || peek == '-'.ord
        return false unless digits?

        real = true
      end

      text = String.new(@bytes[start...@position])
      valid = real ? finite_real?(text) : !text.to_i64?(whitespace: false).nil?
      valid
    end

    private def integer_part? : Bool
      first = next_byte
      return false if first.nil? || !first.unsafe_chr.ascii_number?

      skip_digits unless first == '0'.ord
      true
    end

    # jansson converts with `strtod` and refuses only an overflow, so a real
    # that underflows to zero passes; the stdlib's `String#to_f64?` refuses
    # both. The text has passed the grammar, so `strtod` reads all of it.
    private def finite_real?(text : String) : Bool
      finite = LibC.strtod(text, nil).finite?

      finite
    end

    # At least one digit
    private def digits? : Bool
      return false unless peek.try(&.unsafe_chr.ascii_number?)

      skip_digits
      true
    end

    private def skip_digits : Nil
      while peek.try(&.unsafe_chr.ascii_number?)
        @position += 1
      end
    end
  end
end
