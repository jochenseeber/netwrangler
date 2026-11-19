module Netwrangler::Util
  # The release of a Linux kernel, compared by major and minor number, so 6.9
  # sorts before 6.13
  record KernelVersion,
    major : Int32,
    minor : Int32 do
    include Comparable(KernelVersion)

    # The running kernel's release, such as 7.0.0-29-generic. A container
    # shares the host's kernel, so this is the node's.
    RELEASE_PATH = Path.posix("/proc/sys/kernel/osrelease")

    # Nil unless the release starts with the major and minor number
    def self.parse?(release : String) : KernelVersion?
      match = release.strip.match(/\A(\d+)\.(\d+)/)
      return if match.nil?

      version = KernelVersion.new(major: match[1].to_i, minor: match[2].to_i)

      version
    end

    def self.running(path : Path = RELEASE_PATH) : KernelVersion
      release = File.read(path)

      version = parse?(release)
      raise ArgumentError.new("Cannot parse the kernel release #{release.strip.inspect} in #{path}") if version.nil?

      version
    end

    def <=>(other : KernelVersion) : Int32
      comparison = {major, minor} <=> {other.major, other.minor}

      comparison
    end

    def to_s(io : IO) : Nil
      io << major << "." << minor
    end
  end
end
