require "json"

module Netwrangler::Util
  class QualifiedName
    getter name : String

    getter namespace : String

    def initialize(
      *,
      @name : String,
      @namespace : String,
    )
    end

    def_equals @name, @namespace
    def_hash @name, @namespace

    def to_s(io : IO) : Nil
      io << @namespace << "/" << @name
    end
  end
end
