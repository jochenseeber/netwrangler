# frozen_string_literal: true

require "English"
require "rbconfig"
require "yaml"
require "json"
require "digest"
require "rake"
require "rake/clean"
require "tsort"

# Run a command and return its output, or nil when it fails. stderr is discarded,
# so a caller reads only what the command meant to produce.
def capture(*args)
  output = IO.popen(args, err: File::NULL, &:read)
  $CHILD_STATUS.success? ? output : nil
end

# Like capture, but merges stderr into the result. Some tools report their
# primary output there — `codesign --display` writes everything to stderr — and
# capture would discard it.
def capture_merged(*args)
  output = IO.popen(args, err: %i[child out], &:read)
  $CHILD_STATUS.success? ? output : nil
end

# The build platform as an OS/arch pair. libc/link detection lives with the
# project that consumes it (see Crystal::Project).
Platform = Data.define(:ostype, :arch) do
  def self.detect
    host_os = RbConfig::CONFIG["host_os"]
    ostype =
      case host_os
      when %r{darwin} then "darwin"
      when %r{linux}  then "linux"
      else raise "unsupported host OS: #{host_os.inspect}"
      end
    host_cpu = RbConfig::CONFIG["host_cpu"]
    arch =
      case host_cpu
      when "x86_64", "amd64"  then "amd64"
      when "aarch64", "arm64" then "arm64"
      else raise "unsupported host architecture: #{host_cpu.inspect}"
      end
    new(ostype: ostype, arch: arch)
  end
end

# The build host: its platform (OS type + arch) plus the specific OS
# distribution. Host.detect classifies the current machine and raises when it
# cannot be positively determined, so an unknown host fails loudly.
Host = Data.define(:osname, :platform) do
  def self.detect
    platform = Platform.detect
    new(platform: platform, osname: detect_osname(platform))
  end

  # The specific OS: :macosx, :alpine, or :debian.
  def self.detect_osname(platform)
    return :macosx if platform.ostype == "darwin"
    return :alpine if alpine?
    return :debian if debian?

    raise "cannot determine OS (ostype=#{platform.ostype}, /etc/os-release ID=#{os_release_id.inspect})"
  end

  def self.alpine?
    os_release_id == "alpine"
  end

  def self.debian?
    os_release_id == "debian"
  end

  def self.os_release_id
    return nil unless File.exist?("/etc/os-release")

    contents = File.read("/etc/os-release")
    value = contents[%r{^ID_LIKE=(.*)$}, 1] || contents[%r{^ID=(.*)$}, 1]
    value&.delete('"')
  end
end

# A parsed semantic version. Comparison ignores the prerelease tag (major.minor.
# patch only), matching how release ordering treats X.Y.Z-dev and X.Y.Z.
Version = Data.define(:major, :minor, :patch, :prerelease) do
  def self.parse(text)
    match = %r{\A(\d+)\.(\d+)\.(\d+)(?:-(.+))?\z}.match(text.to_s)
    raise "Invalid version: #{text}" unless match

    new(major: match[1].to_i, minor: match[2].to_i, patch: match[3].to_i, prerelease: match[4])
  end

  def to_s
    base = "#{major}.#{minor}.#{patch}"
    prerelease ? "#{base}-#{prerelease}" : base
  end

  def <=>(other)
    [major, minor, patch] <=> [other.major, other.minor, other.patch]
  end
end

# A facet-extensible model of the project file. Every facet reads the project's
# name, version and components from here, and stores its own data in a slot
# under its own key, so a facet for another language has somewhere to put it.
#
# Readers never create. Every writer is named add_… and there is no []=, so a
# misspelled name reads as nil where the mistake is rather than adding an entry.
class Project
  # The project file: the one place the name and version are stated.
  FILE = ".project.yaml"

  # One component of the project — a name, and a slot per facet. What a component
  # *is* belongs to the facets: its shards target, its Dockerfile, its workload.
  class Component
    attr_reader :name

    def initialize(name)
      @name = name
      @facets = {}
    end

    def [](key) = @facets[key]

    def add_facet(key) = @facets[key] ||= yield

    def freeze!
      @facets.freeze
      freeze
    end
  end

  # The context a facet body runs against: `project`, and Rake's DSL so the body
  # can define tasks directly.
  class FacetContext
    include Rake::DSL

    # Rake declares its DSL private, which fits a Rakefile's own top level and not a
    # context handed around: a facet body calls `task` on itself, but the helper it
    # passes the context to calls `context.task`, and a private method rejects that.
    public :task, :file, :file_create, :directory, :multitask, :namespace, :rule, :desc, :import

    attr_reader :project

    def initialize(project)
      @project = project
    end
  end

  # A registered facet: its key, the facets it would like to follow, and its
  # unevaluated body.
  Registration = Data.define(:key, :after, :body)

  include TSort

  def self.load(path = FILE)
    abort "#{path} is missing; it states the project's name and version" unless File.exist?(path)

    new(YAML.load_file(path) || {})
  end

  def initialize(config)
    @config = config
    @facets = {}
    @components = {}
    @version_files = []
    @version_writers = []
    @registrations = {}
    @definitions = []
  end

  def name = fetch_project("name")
  def version = fetch_project("version")

  # The declared section for +key+, for a facet to build its object from. Always
  # available, unlike a slot, which only a facet that is installed can fill.
  def config(key) = @config[key.to_s] || {}

  def [](key) = @facets[key]
  def facet(key) = @facets[key]
  def add_facet(key) = @facets[key] ||= yield

  attr_reader :components

  def component(name) = @components[name]
  def add_component(name) = @components[name] ||= Component.new(name)

  def add_version_file(path) = @version_files << path
  def version_files = [FILE, *@version_files]

  # A facet's own writer for the manifest it owns, called when the project version is
  # written out. Registered rather than named, so this file never learns which
  # languages the project uses.
  def add_version_writer(&writer) = @version_writers << writer

  # Write +version+ where the project states it. The manifests that repeat it are
  # each facet's business, through version:update.
  #
  # The parsed file is updated along with the file, so that #version answers with the
  # new value for the rest of the process. `release` bumps the version and then has the
  # manifests written from it, all in one run, and a #version still answering from the
  # parse made at load would write the version before the bump into every one of them.
  def write_version(version)
    lines = File.readlines(FILE)
    index = project_block(lines).find { |line| lines[line].match?(%r{^\s+version:}) }
    abort "#{FILE} has no version in its project: block" if index.nil?

    lines[index] = lines[index].sub(%r{(^\s+version:\s*).*$}, "\\1#{version}")
    File.write(FILE, lines.join)
    (@config["project"] ||= {})["version"] = version.to_s
  end

  # Write +version+ where the project states it, then out to every manifest that
  # repeats it. The paired write is what `release` needs: it writes twice inside one
  # procedure, so it cannot reach the same effect through a task dependency.
  def write_versions(version)
    write_version(version)
    @version_writers.each { |writer| writer.call(version) }
  end

  # Register a block to run once every facet body has run, for reads no `after:`
  # edge can express — every component, whichever facet invented it.
  def define(&block) = @definitions << block

  def register(key, after:, body:)
    abort "two facets both call themselves #{key}" if @registrations.key?(key)

    @registrations[key] = Registration.new(key: key, after: Array(after), body: body)
  end

  # Run every registered facet in dependency order, then freeze and run the
  # blocks that wanted the whole picture.
  def load_facets
    tsort.each { |key| run_facet(@registrations[key]) }
    freeze!
    @definitions.each(&:call)
  end

  def tsort_each_node(&) = @registrations.each_key(&)

  # `after:` orders, it never requires: an edge to a facet that is not installed
  # is skipped, so a facet may name anything it would like to follow.
  def tsort_each_child(key, &)
    @registrations[key].after.select { |other| @registrations.key?(other) }.each(&)
  end

  private

  def run_facet(registration)
    FacetContext.new(self).instance_exec(&registration.body)
  end

  def freeze!
    @components.each_value(&:freeze!)
    @components.freeze
    @facets.freeze
  end

  def fetch_project(field)
    value = (@config["project"] || {})[field]
    abort "#{FILE} has no project.#{field}" if value.nil?

    value.to_s
  end

  # The lines of the `project:` block, as an index range. `crystal:` and
  # `kubernetes:` carry a `version:` of their own at the same indent, so a
  # rewrite has to know where this block ends.
  def project_block(lines)
    start = lines.index { |line| line.start_with?("project:") }
    abort "#{FILE} has no project: block" if start.nil?

    following = lines[(start + 1)..].index { |line| line.match?(%r{^\S}) }
    (start + 1)...(following ? start + 1 + following : lines.length)
  end
end

PROJECT = Project.load

# Report a manifest whose version has drifted from the project's, naming both so the
# message says which way to fix it. Every `version:lint:<language>` ends here.
def report_version_drift(manifest:, found:)
  return if found == PROJECT.version

  abort "#{manifest} says #{found.inspect}, but #{Project::FILE} says " \
        "#{PROJECT.version.inspect}; run `rake version:update` to write it out"
end

# Register a facet. Loading a facet file only registers it; the body runs when
# the loader reaches it, in dependency order.
def facet(key, after: [], &body) = PROJECT.register(key, after: after, body: body)
