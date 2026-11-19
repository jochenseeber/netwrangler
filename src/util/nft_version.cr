module Netwrangler::Util
  # The release of an nft binary, compared number by number, so 1.0.9 sorts
  # before 1.0.10
  record NftVersion,
    major : Int32,
    minor : Int32,
    patch : Int32 do
    include Comparable(NftVersion)

    # Nil unless the text holds a version as `nft --version` prints it, such
    # as `nftables v1.0.6 (Lester Gooch #5)`. A fourth number, as in 1.0.6.1,
    # is ignored.
    def self.parse?(text : String) : NftVersion?
      match = text.match(/\bv(\d+)\.(\d+)\.(\d+)/)
      return if match.nil?

      version = NftVersion.new(major: match[1].to_i, minor: match[2].to_i, patch: match[3].to_i)

      version
    end

    def <=>(other : NftVersion) : Int32
      comparison = {major, minor, patch} <=> {other.major, other.minor, other.patch}

      comparison
    end

    def to_s(io : IO) : Nil
      io << major << "." << minor << "." << patch
    end
  end
end
