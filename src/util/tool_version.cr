module Netwrangler::Util
  # A dotted release number such as 1.1.7 or 1.0.6.1, ordered numerically, so
  # 1.0.6.1 sorts before 1.1.2 and 1.1.10 after 1.1.9
  struct ToolVersion
    include Comparable(ToolVersion)

    getter parts : Array(Int32)

    def initialize(@parts : Array(Int32))
    end

    # Nil unless the text is two or more dot-separated numbers
    def self.parse?(text : String) : ToolVersion?
      fields = text.split(".")
      return if fields.size < 2

      parts = fields.map(&.to_i?(whitespace: false, prefix: false))
      return if parts.any?(Nil)

      version = ToolVersion.new(parts.compact)

      version
    end

    def <=>(other : ToolVersion) : Int32
      comparison = @parts <=> other.parts

      comparison
    end

    def to_s(io : IO) : Nil
      @parts.join(io, ".")
    end
  end
end
