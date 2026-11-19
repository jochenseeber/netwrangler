# Runs the node's own `nft`, `ip`, `wg` or `arping` for the netwrangler agent,
# with the capabilities that tool needs, and refuses everything else.
#
# The image ships none of nftables, iproute2, wireguard-tools and iputils: the
# node's own releases run, in the node's mount namespace, so there is no skew
# between image and node.
#
# This is the image's only file with capabilities, all permitted-only. The
# wrapper is called through symlinks named after the tools, checks the
# arguments against what the agent passes, and execs the tool with only its
# own capabilities, as ambient ones, and an environment it sets.

require "./privileged_runner/refusal"
require "./privileged_runner/tools"

# The capability and namespace calls exist only on Linux; elsewhere the binary
# builds, so the specs and the linter cover the rest, but refuses every call
{% if flag?(:linux) %}
  require "./privileged_runner/capabilities"
  require "./privileged_runner/lib_c"
  require "./privileged_runner/node"
{% end %}

# One call of the wrapper: the program name it was called by, which names the
# tool, and the arguments for that tool
class Netwrangler::PrivilegedRunner
  # Exit code for a refused call or a failed setup step, as a shell reports a
  # command it cannot run
  REFUSED = 126

  # Exit code when the node has no such tool, as a shell reports a command it
  # cannot find
  MISSING = 127

  # The environment the tool gets, in place of the caller's: the tool carries
  # no file capabilities, so nothing would protect it from `LD_PRELOAD` and
  # the like
  TOOL_ENVIRONMENT = {"PATH=/usr/sbin:/usr/bin:/sbin:/bin", "LC_ALL=C"}

  # Standard input, output and error, which the tool inherits
  STANDARD_DESCRIPTORS = {0, 1, 2}

  def initialize(@program : String, @arguments : Array(String))
  end

  # Prints `<name>: <message>` to stderr and exits with +code+. A stderr that
  # cannot be written, such as a pipe whose reader has gone, must not turn the
  # refusal into Crystal's exit 1, which would read as the tool's own.
  def self.exit_with(name : String, message : String, code : Int32) : NoReturn
    Crystal.ignore_stdio_errors { STDERR.puts "#{name}: #{message}" }
    exit code
  end

  {% if flag?(:linux) %}
    # Everything runs on the main thread, in the main fiber: capability sets
    # and the ambient set are per thread, and they must be this thread's when
    # it calls `execve`
    def run : NoReturn
      restore_blocking_stdio
      called = File.basename(@program)
      name = called
      begin
        tool = Tool.find?(called)
        PrivilegedRunner.exit_with(called, "only ip, wg, arping and nft are allowed", REFUSED) if tool.nil?

        name = tool.name
        tool.check(@arguments)
        Capabilities.require_permitted(ENTRY_CAPABILITIES.to_a + tool.capabilities)
        Node.enter
        path = Node.find_program(name)
        PrivilegedRunner.exit_with(name, "the node has no #{name}", MISSING) if path.nil?

        Node.check_not_wrapper(path, name)
        Capabilities.restrict_to(tool.capabilities)
        Capabilities.forbid_new_privileges
        execute(path, name)
      rescue error : Refusal
        PrivilegedRunner.exit_with(name, error.message.to_s, REFUSED)
      rescue error : Exception
        # Crystal's own exit 1 for an unhandled exception would read as the
        # tool's, such as `arping -U` or `nft -j list` with nothing to list
        PrivilegedRunner.exit_with(name, error.message || error.class.name, REFUSED)
      end
    end

    # Crystal's runtime sets `O_NONBLOCK` on piped standard descriptors before
    # `main`. The flag belongs to the open file description, not to this
    # process: it survives `execve`, so the tool would get `EAGAIN` writing to
    # a full pipe and lose output whenever the agent reads more slowly than it
    # writes, and it stays on the pipe for whatever writes to it next. Cleared
    # before anything can refuse, so a refusal leaves the descriptors as the
    # caller passed them, too. Errors are ignored: a closed descriptor has no
    # flags to clear. The descriptors are the numbers, not `STDOUT` and the
    # like, which stand for a private clone when they are a terminal.
    private def restore_blocking_stdio : Nil
      STANDARD_DESCRIPTORS.each do |fd|
        flags = LibC.fcntl(fd, LibC::F_GETFL)
        LibC.fcntl(fd, LibC::F_SETFL, flags & ~LibC::O_NONBLOCK) unless flags < 0
      end
    end

    # Replaces this process with the tool, `argv[0]` its name rather than the
    # node's path, as the tool's own messages expect. `Process.exec` cannot do
    # this: it passes the path it runs as `argv[0]` and searches `PATH` when
    # the path has no slash.
    private def execute(path : String, name : String) : NoReturn
      argv = ([name] + @arguments).map(&.to_unsafe) << Pointer(LibC::Char).null
      environment = TOOL_ENVIRONMENT.map(&.to_unsafe).to_a << Pointer(LibC::Char).null
      restore_signal_defaults
      LibC.execve(path, argv, environment)
      errno = Errno.value
      raise Refusal.failure("exec of #{path}", errno)
    end

    # Crystal's runtime ignores SIGPIPE, and an ignored signal stays ignored
    # across `execve`: a tool writing to a closed pipe would get EPIPE errors
    # instead of ending. The tool gets the default disposition and an empty
    # signal mask, as from a shell and as the Rust wrapper's exec gave it.
    private def restore_signal_defaults : Nil
      ::Signal::PIPE.reset
      mask = uninitialized LibC::SigsetT
      LibC.sigemptyset(pointerof(mask))
      # Cannot fail: SIG_SETMASK is valid and the set is empty
      LibC.pthread_sigmask(LibC::SIG_SETMASK, pointerof(mask), nil)
    end

    new(PROGRAM_NAME, ARGV).run
  {% else %}
    exit_with("node-tool", "runs only on Linux", REFUSED)
  {% end %}
end
