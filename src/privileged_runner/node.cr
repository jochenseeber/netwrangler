require "./capabilities"
require "./lib_c"
require "./refusal"
require "./tools"

class Netwrangler::PrivilegedRunner
  # Entering the node's mount namespace and finding a tool there.
  #
  # The pod mounts the node's `/proc` at `/hostfs/proc`. The kernel guards
  # `/hostfs/proc/1/ns/mnt` with a ptrace check, which is why the agent itself
  # cannot open it and the wrapper raises `cap_sys_ptrace` to do so. Entering
  # the namespace, rather than chrooting, gives the tool the node's mount table
  # and libraries as well as its executable.
  #
  # Files are examined with `stat` and friends from `LibC` rather than
  # `File.info`, so each failure carries the system's own error and nothing
  # depends on how the stdlib maps it.
  module Node
    # Where the node's tools are, searched in this order
    TOOL_DIRECTORIES = {"/usr/sbin", "/sbin", "/usr/bin", "/bin"}

    # The inode number the kernel gives the initial user namespace, fixed in
    # `include/linux/proc_ns.h`
    PROC_USER_INIT_INO = 0xEFFFFFFD_u64

    # A file's device and inode, which tell files apart across mount
    # namespaces where paths do not
    record Identity, device : UInt64, inode : UInt64

    # Moves this process into the node's mount namespace. The entry
    # capabilities are effective from opening the namespace through its checks
    # to the `setns` call, and gone from every set afterwards, whether or not
    # entering succeeded, so a refusal exits without them.
    def self.enter : Nil
      check_node_proc
      Capabilities.raise_effective(ENTRY_CAPABILITIES)
      begin
        enter_privileged
      ensure
        drop_entry_capabilities
      end
    end

    private def self.enter_privileged : Nil
      # Opened privileged: without the ptrace check passing, the kernel does
      # not follow the link and this resolves to the directory instead
      namespace = LibC.open(NODE_MOUNT_NAMESPACE, LibC::O_RDONLY | LibC::O_CLOEXEC)
      errno = Errno.value
      raise Refusal.open_failure(errno) if namespace < 0

      begin
        check_namespace(namespace)
        enter_namespace(namespace)
      ensure
        LibC.close(namespace)
      end
    end

    # A failed drop is ignored, as it would otherwise replace a refusal in
    # flight. It cannot leave the tool privileged: `Capabilities.restrict_to`
    # removes every file capability but the tool's own from all sets before
    # the `exec`, and refuses when it cannot.
    private def self.drop_entry_capabilities : Nil
      Capabilities.drop_all(ENTRY_CAPABILITIES)
    rescue Refusal
    end

    private def self.check_node_proc : Nil
      status = uninitialized LibC::Stat
      result = LibC.lstat(NODE_MOUNT_NAMESPACE, pointerof(status))
      errno = Errno.value
      return if result == 0
      raise Refusal.new("mount the node's /proc at #{NODE_PROC}") if errno == Errno::ENOENT

      raise Refusal.new("reading #{NODE_MOUNT_NAMESPACE} failed: #{Refusal.describe(errno)}")
    end

    private def self.check_namespace(namespace : LibC::Int) : Nil
      status = uninitialized LibC::Stat
      result = LibC.fstat(namespace, pointerof(status))
      errno = Errno.value
      raise Refusal.new("reading #{NODE_MOUNT_NAMESPACE} failed: #{Refusal.describe(errno)}") unless result == 0
      raise Refusal.new("#{NODE_MOUNT_NAMESPACE} is not a namespace") if file_type?(status, LibC::S_IFDIR)
      # Our own namespace means the /proc mounted is not the node's, and the
      # tool found there would be this wrapper
      if identity(status) == identity?("/proc/self/ns/mnt")
        raise Refusal.new("#{NODE_MOUNT_NAMESPACE} is this container's own namespace, not the node's")
      end

      check_owned_by_initial_user_namespace(namespace)
    end

    # Checks that the mount namespace is owned by the initial user namespace,
    # which rules out the mount namespace of a user-namespaced container, such
    # as one whose `/proc` were mounted at `/hostfs/proc`. A container without
    # its own user namespace passes; only the check against this container's
    # own namespace and the tool search narrow that down. The reference is the
    # kernel's fixed inode number, as every file under `/hostfs/proc` is the
    # one being vetted.
    private def self.check_owned_by_initial_user_namespace(namespace : LibC::Int) : Nil
      owner = LibC.ioctl(namespace, LibC::NS_GET_USERNS)
      errno = Errno.value
      raise Refusal.failure("finding the user namespace of #{NODE_MOUNT_NAMESPACE}", errno) if owner < 0

      begin
        status = uninitialized LibC::Stat
        result = LibC.fstat(owner, pointerof(status))
        errno = Errno.value
        unless result == 0
          raise Refusal.new("reading the user namespace of #{NODE_MOUNT_NAMESPACE} failed: #{Refusal.describe(errno)}")
        end
      ensure
        LibC.close(owner)
      end
      return if status.st_ino.to_u64 == PROC_USER_INIT_INO

      raise Refusal.new("#{NODE_MOUNT_NAMESPACE} is owned by a user namespace other than the initial one")
    end

    private def self.enter_namespace(namespace : LibC::Int) : Nil
      # The kernel lets only a thread whose filesystem context no other thread
      # shares change its mount namespace, and refuses with EINVAL otherwise.
      # The Crystal runtime may start threads of its own (the GC's parallel
      # markers), and QEMU's user-mode emulation, as a cross-platform image
      # build runs it, adds more; each shares the context. A private copy is
      # harmless where nothing shares it, and needs no privilege.
      result = LibC.unshare(LibC::CLONE_FS)
      errno = Errno.value
      raise Refusal.failure("taking a private filesystem context", errno) unless result == 0

      result = LibC.setns(namespace, LibC::CLONE_NEWNS)
      errno = Errno.value
      raise Refusal.failure("entering the node's mount namespace", errno) unless result == 0
    end

    # The node's executable for a tool, the first regular file of that name in
    # the tool directories, symlinks followed; called after `enter`
    def self.find_program(name : String) : String?
      program = TOOL_DIRECTORIES.map { |directory| "#{directory}/#{name}" }.find do |path|
        status = uninitialized LibC::Stat
        LibC.stat(path, pointerof(status)) == 0 && file_type?(status, LibC::S_IFREG)
      end

      program
    end

    # A second guard against running ourselves, by device and inode, as paths
    # differ between the namespaces. Two files that cannot be examined count
    # as the same, so a failure refuses.
    def self.check_not_wrapper(program : String, name : String) : Nil
      return unless identity?(program) == identity?("/proc/self/exe")

      raise Refusal.new("#{program} is this wrapper, not the node's #{name}")
    end

    private def self.identity?(path : String) : Identity?
      status = uninitialized LibC::Stat
      return unless LibC.stat(path, pointerof(status)) == 0

      identity = identity(status)
      identity
    end

    private def self.identity(status : LibC::Stat) : Identity
      identity = Identity.new(device: status.st_dev.to_u64, inode: status.st_ino.to_u64)

      identity
    end

    private def self.file_type?(status : LibC::Stat, type : Int) : Bool
      matches = (status.st_mode & LibC::S_IFMT) == type

      matches
    end
  end
end
