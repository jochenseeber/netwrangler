# The Linux calls node-tool needs that the stdlib does not bind. The types
# are the same on x86_64 and aarch64, with musl and with glibc.
lib LibC
  # `unshare`: give this thread its own filesystem context (root, working
  # directory, umask), which `setns` into a mount namespace requires
  CLONE_FS = 0x00000200

  # `setns`: the descriptor is a mount namespace
  CLONE_NEWNS = 0x00020000

  # `_IO(0xb7, 0x1)`: a new descriptor for the user namespace that owns a
  # namespace
  NS_GET_USERNS = 0xb701_u64

  # `_LINUX_CAPABILITY_VERSION_3`: 64-bit sets, in two 32-bit words each
  LINUX_CAPABILITY_VERSION_3 = 0x20080522_u32

  PR_SET_NO_NEW_PRIVS  =    38
  PR_CAP_AMBIENT       =    47
  PR_CAP_AMBIENT_RAISE = 2_u64

  # `struct __user_cap_header_struct`
  struct CapUserHeader
    version : UInt32
    pid : Int
  end

  # `struct __user_cap_data_struct`, one per 32-bit word of the sets
  struct CapUserData
    effective : UInt32
    permitted : UInt32
    inheritable : UInt32
  end

  fun setns(fd : Int, nstype : Int) : Int
  fun unshare(flags : Int) : Int
  fun capget(header : CapUserHeader*, data : CapUserData*) : Int
  fun capset(header : CapUserHeader*, data : CapUserData*) : Int

  # Variadic in C, `int prctl(int, ...)`, and bound as such so the call
  # follows the variadic convention; every option used here takes four
  # `unsigned long` arguments, which callers pass as `UInt64`.
  fun prctl(option : Int, ...) : Int

  # musl declares the request an `int`, glibc an `unsigned long`. Passed as
  # an `unsigned long`, it reads correctly as either: the callee takes the low
  # 32 bits of the register for an `int`, and the kernel's `cmd` is 32 bits.
  fun ioctl(fd : Int, request : ULong, ...) : Int
end
