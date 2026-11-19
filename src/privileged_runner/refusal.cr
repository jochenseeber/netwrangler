class Netwrangler::PrivilegedRunner
  # Where the pod mounts the node's /proc
  NODE_PROC = "/hostfs/proc"

  # The mount namespace of the node's init, which the tools run in
  NODE_MOUNT_NAMESPACE = "#{NODE_PROC}/1/ns/mnt"

  # Why a call is refused, for the line `<tool>: <message>` on stderr
  class Refusal < Exception
    def initialize(message : String)
      super(message)
    end

    # An argument outside the tool's allowlist
    def self.not_allowed(argument : String) : Refusal
      refusal = new("argument not allowed: #{argument}")

      refusal
    end

    # A failed system call, with the error the kernel reported, worded as the
    # Rust wrapper this replaced worded it. Callers read `Errno.value` right
    # after the call, before anything that allocates, such as building the
    # call's name, can change it.
    def self.failure(call : String, errno : Errno) : Refusal
      refusal = new("#{call} failed: #{describe(errno)}")

      refusal
    end

    # Opening the node's mount namespace failed. With `cap_sys_ptrace`
    # effective, a denied open is a security module's doing: containerd's
    # default AppArmor profile allows ptrace only within that same profile, and
    # an SELinux container type may not ptrace the node's init at all.
    def self.open_failure(errno : Errno) : Refusal
      hint = errno == Errno::EACCES ? " (AppArmor or SELinux may deny ptrace of the node's init)" : ""
      refusal = new("opening #{NODE_MOUNT_NAMESPACE} failed: #{describe(errno)}#{hint}")

      refusal
    end

    # An error as Rust's `io::Error` prints one from the system
    def self.describe(errno : Errno) : String
      description = "#{errno.message} (os error #{errno.value})"

      description
    end
  end
end
