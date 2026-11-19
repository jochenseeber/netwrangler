require "./lib_c"
require "./refusal"
require "./tools"

class Netwrangler::PrivilegedRunner
  # This thread's capability sets, through `capget`, `capset` and `prctl`.
  #
  # All of the file's capabilities are permitted-only, so nothing the Crystal
  # runtime does before `main` runs with them. Each is raised to effective
  # only for the call that needs it, and the tool's own reach it as ambient
  # capabilities, which survive the `exec` of a file that carries none.
  #
  # The sets, the ambient set and `no_new_privs` belong to the calling thread,
  # not the process: every call here and the `exec` run on the main thread,
  # which is the only one running Crystal code, as the wrapper spawns no
  # fibers and is built without multithreading.
  module Capabilities
    # A thread's three capability sets, one bit per capability
    record Sets, effective : UInt64, permitted : UInt64, inheritable : UInt64

    # Refuses, naming the capability, when one of +needed+ is not permitted:
    # raising it would fail with only "Operation not permitted"
    def self.require_permitted(needed : Enumerable(Capability)) : Nil
      PrivilegedRunner.check_permitted(read.permitted, needed)
    end

    # Makes +capabilities+ effective; each must be permitted
    def self.raise_effective(capabilities : Enumerable(Capability)) : Nil
      bits = mask(capabilities)
      update { |sets| sets.copy_with(effective: sets.effective | bits) }
    end

    # Removes +capabilities+ from every set, for good
    def self.drop_all(capabilities : Enumerable(Capability)) : Nil
      kept = ~mask(capabilities)
      update do |sets|
        Sets.new(effective: sets.effective & kept, permitted: sets.permitted & kept, inheritable: sets.inheritable & kept)
      end
    end

    # Leaves the tool only its own capabilities, as inheritable and ambient
    # ones for its `exec`; the rest of the file's go from every set, and none
    # stays effective in the wrapper
    def self.restrict_to(tool_capabilities : Enumerable(Capability)) : Nil
      own = mask(tool_capabilities)
      others = mask(FILE_CAPABILITIES) & ~own
      # Ambient capabilities need each one inheritable first, which a process
      # may raise within its permitted set unprivileged
      update do |sets|
        Sets.new(
          effective: sets.effective & ~mask(FILE_CAPABILITIES),
          permitted: sets.permitted & ~others,
          inheritable: (sets.inheritable & ~others) | own
        )
      end
      tool_capabilities.each { |capability| raise_ambient(capability) }
    end

    private def self.raise_ambient(capability : Capability) : Nil
      result = LibC.prctl(LibC::PR_CAP_AMBIENT, LibC::PR_CAP_AMBIENT_RAISE, capability.value.to_u64, 0_u64, 0_u64)
      errno = Errno.value
      raise Refusal.failure("raising capability #{capability.value}", errno) unless result == 0
    end

    # Stops the tool, and anything it runs, from gaining privileges through
    # `exec`: a setuid node tool would otherwise run with the container's whole
    # bounding set. Ambient capabilities survive it, as they are no gain.
    def self.forbid_new_privileges : Nil
      result = LibC.prctl(LibC::PR_SET_NO_NEW_PRIVS, 1_u64, 0_u64, 0_u64, 0_u64)
      errno = Errno.value
      raise Refusal.failure("setting no_new_privs", errno) unless result == 0
    end

    private def self.mask(capabilities : Enumerable(Capability)) : UInt64
      bits = capabilities.reduce(0_u64) { |set, capability| set | capability.mask }

      bits
    end

    private def self.header : LibC::CapUserHeader
      header = LibC::CapUserHeader.new(version: LibC::LINUX_CAPABILITY_VERSION_3, pid: 0)

      header
    end

    # This thread's capability sets
    private def self.read : Sets
      header = self.header
      data = StaticArray(LibC::CapUserData, 2).new(LibC::CapUserData.new)
      result = LibC.capget(pointerof(header), data.to_unsafe)
      errno = Errno.value
      raise Refusal.failure("capget", errno) unless result == 0

      sets = Sets.new(
        effective: join(data[0].effective, data[1].effective),
        permitted: join(data[0].permitted, data[1].permitted),
        inheritable: join(data[0].inheritable, data[1].inheritable)
      )
      sets
    end

    # Reads this thread's capability sets, lets the block change them, and
    # writes them back
    private def self.update(& : Sets -> Sets) : Nil
      sets = yield read
      header = self.header
      data = StaticArray[word(sets, 0), word(sets, 1)]
      result = LibC.capset(pointerof(header), data.to_unsafe)
      errno = Errno.value
      raise Refusal.failure("capset", errno) unless result == 0
    end

    # The version 3 interface splits each 64-bit set into two 32-bit words
    private def self.join(low : UInt32, high : UInt32) : UInt64
      set = low.to_u64 | (high.to_u64 << 32)

      set
    end

    private def self.word(sets : Sets, index : Int32) : LibC::CapUserData
      shift = 32 * index
      data = LibC::CapUserData.new(
        effective: (sets.effective >> shift).to_u32!,
        permitted: (sets.permitted >> shift).to_u32!,
        inheritable: (sets.inheritable >> shift).to_u32!
      )

      data
    end
  end
end
