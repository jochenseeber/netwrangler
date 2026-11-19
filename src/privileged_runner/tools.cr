require "./arguments"
require "./refusal"

class Netwrangler::PrivilegedRunner
  # A Linux capability the wrapper's file carries, numbered as in
  # `linux/capability.h`
  enum Capability : UInt32
    # Configuring interfaces, addresses, routes, rules, nftables and WireGuard
    NetAdmin = 12

    # The raw socket arping sends its ARP packets through
    NetRaw = 13

    # `setns` into a mount namespace takes `cap_sys_chroot` besides
    # `cap_sys_admin`
    SysChroot = 18

    # Opening the node init's namespace link passes the kernel's ptrace check
    SysPtrace = 19

    # `setns` into the node's mount namespace
    SysAdmin = 21

    # The capability's bit in a 64-bit capability set
    def mask : UInt64
      bit = 1_u64 << value

      bit
    end

    # The name as `capsh` and the capabilities(7) man page spell it
    def to_s : String
      name = case self
             when NetAdmin  then "cap_net_admin"
             when NetRaw    then "cap_net_raw"
             when SysChroot then "cap_sys_chroot"
             when SysPtrace then "cap_sys_ptrace"
             when SysAdmin  then "cap_sys_admin"
             else                "capability #{value}"
             end

      name
    end

    def to_s(io : IO) : Nil
      io << to_s
    end
  end

  # What entering the node's mount namespace takes, whatever the tool: the
  # kernel's ptrace check guards the namespace link, and `setns` into a mount
  # namespace takes `cap_sys_chroot` as well as `cap_sys_admin`
  ENTRY_CAPABILITIES = {Capability::SysAdmin, Capability::SysChroot, Capability::SysPtrace}

  # Every capability the wrapper's file carries, so every one a tool must not
  # keep unless it is the tool's own
  FILE_CAPABILITIES = {
    Capability::NetAdmin, Capability::NetRaw, Capability::SysAdmin, Capability::SysChroot, Capability::SysPtrace,
  }

  # The tools the wrapper runs, all the node's own, selected by the basename of
  # `argv[0]`
  enum Tool
    Ip
    Wg
    Arping
    Nft

    # The tool called +name+; names are lower case, as the symlinks are
    def self.find?(name : String) : Tool?
      tool = values.find { |candidate| candidate.name == name }

      tool
    end

    # The name the tool is called by, and its executable's name on the node
    def name : String
      text = to_s.downcase

      text
    end

    # The capabilities the tool runs with, as ambient ones
    def capabilities : Array(Capability)
      own = case self
            in Ip, Wg, Nft then [Capability::NetAdmin]
            in Arping      then [Capability::NetRaw]
            end

      own
    end

    # Accepts the arguments the agent passes the tool, and raises a `Refusal`
    # for all others
    def check(arguments : Array(String)) : Nil
      case self
      in Ip     then Arguments.check_ip(arguments)
      in Wg     then Arguments.check_wg(arguments)
      in Arping then Arguments.check_arping(arguments)
      in Nft    then Arguments.check_nft(arguments)
      end
    end
  end

  # Refuses a call when a capability the wrapper needs is not in the permitted
  # set, which the file capabilities fill only from the container's bounding
  # set, and not at all under `no_new_privs`. Naming the capability tells the
  # operator what to fix, where `capset` would only say "Operation not
  # permitted".
  def self.check_permitted(permitted : UInt64, needed : Enumerable(Capability)) : Nil
    missing = needed.find { |capability| (permitted & capability.mask) == 0 }
    return if missing.nil?

    raise Refusal.new(
      "#{missing} is not permitted: add it to the container's capabilities " \
      "and do not set allowPrivilegeEscalation: false"
    )
  end
end
