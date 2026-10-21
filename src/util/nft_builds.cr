require "./tool_version"

module Netwrangler::Util
  # The requested nft build is not in the image
  class NftBuildNotFoundError < Exception
    getter requested : String?
    getter available : Array(ToolVersion)

    def initialize(*, @requested : String?, @available : Array(ToolVersion))
      if @requested.nil?
        super("No nft builds found")
      else
        super("#{NftBuilds::VERSION_ENVIRONMENT_VARIABLE}=#{@requested} names no bundled nft build, " \
              "available: #{@available.join(", ")}")
      end
    end
  end

  # The nft builds bundled in the image, each named nft-<version>. The image
  # carries several so the agent can run the release a host runs; the
  # Dockerfile's NFTABLES_BUILDS lists them.
  record NftBuilds,
    directory : Path,
    versions : Array(ToolVersion) do
    DIRECTORY                    = Path.posix("/usr/local/sbin")
    FILE_PREFIX                  = "nft-"
    VERSION_ENVIRONMENT_VARIABLE = "NETWRANGLER_NFT_VERSION"

    # Finds the builds in a directory, ignoring files not named nft-<version>
    def self.discover(directory : Path) : NftBuilds
      names = Dir.exists?(directory.to_s) ? Dir.children(directory.to_s) : [] of String
      versions = names.compact_map { |name| parse_file_name(name) }.sort!

      builds = NftBuilds.new(directory: directory, versions: versions)

      builds
    end

    private def self.parse_file_name(name : String) : ToolVersion?
      return unless name.starts_with?(FILE_PREFIX)

      version = ToolVersion.parse?(name.lchop(FILE_PREFIX))

      version
    end

    # The nft of the requested version, or of the latest when none is requested
    def path(*, requested : String?) : Path
      version = requested.nil? ? latest : find(requested)

      path = @directory / "#{FILE_PREFIX}#{version}"

      path
    end

    private def latest : ToolVersion
      version = @versions.last?
      raise NftBuildNotFoundError.new(requested: nil, available: @versions) if version.nil?

      version
    end

    private def find(requested : String) : ToolVersion
      requested_version = ToolVersion.parse?(requested)
      version = @versions.find { |candidate| candidate == requested_version }
      raise NftBuildNotFoundError.new(requested: requested, available: @versions) if version.nil?

      version
    end
  end
end
