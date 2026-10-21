# frozen_string_literal: true

require_relative "../project"
require "shellwords"

# Crystal-specific project configuration and tasks. Crystal::Project holds the
# crystal-only data (build profiles, static libraries, the signing prefix) and knows
# how to define its tasks; what the project *is* — its name, version and components —
# comes from the model it is built against.
#
# Only the facet block at the bottom contributes anything: requiring this file
# registers the facet and nothing more, so the constants and classes above are
# readable by any facet that reaches for them, whether or not it declared an
# `after:` edge to this one.
#
# The other facets are not required here either, even though the build tasks below
# call Codesign directly. These are .rb files loaded with require_relative, which is
# idempotent, so a facet may require another freely with no risk of running its body
# twice. This file skips it because project.rake requires every facet file before any
# facet body runs, so Codesign is already defined by the time these tasks execute.
module Crystal
  # The shards manifest — the manifest that repeats the project's version, and the
  # source of truth for everything else the shards format defines (name, targets,
  # dependencies).
  SHARD_PATH = "shard.yml"

  # The project file, whose `crystal` key holds the build settings the shards
  # format has no place for (profiles, static_libraries, identifier_prefix).
  PROJECT_PATH = ::Project::FILE

  # The build modes, each with its own profile list in the project file.
  MODES = %w[debug release].freeze

  # The project-file key whose profiles are built in every mode, so a profile
  # that does not differ between modes is listed once.
  COMMON_PROFILES = "common"

  # Where macOS keeps the libraries every Mac is guaranteed to have. A binary
  # linking only these runs on any same-arch Mac; a library from anywhere else
  # (Homebrew, /usr/local, an @rpath) has to travel with it.
  SYSTEM_LIBRARY_PREFIXES = ["/usr/lib/", "/System/Library/"].freeze

  # Every library the Crystal stdlib declares an `@[Link]` for that a Unix host may
  # resolve from Homebrew, so a deps-static build links it from an archive instead of a
  # dylib. Taken from the stdlib's own annotations, less the Windows-only ones, the
  # compiler's own (llvm), and those the platform provides — libSystem covers pthread,
  # dl, m and socket, and macOS ships iconv as a dylib only.
  #
  # Which of these a given binary actually links is the linker's business, not this
  # list's: an offered archive nothing references is simply not pulled in.
  RUNTIME_LIBRARIES = %w[
    crypto event event_core event_extra event_pthreads ffi gc gc-threaded gmp pcre
    pcre2-8 ssl xml2 yaml z
  ].freeze

  # The entitlement every hardened Crystal binary needs, merged into whatever a
  # component declares. Crystal's Regex is PCRE2 with its JIT enabled, and the JIT needs
  # MAP_JIT executable memory, which the hardened runtime withholds without this — a
  # hardened binary without it dies on its first regex compile with "Regex JIT compile
  # error: NOMEMORY". It does not relax library validation, so DYLD_INSERT_LIBRARIES
  # injection stays blocked, which is the whole point of hardening.
  RUNTIME_ENTITLEMENTS = { "com.apple.security.cs.allow-jit" => true }.freeze

  # Parses and confines the user-supplied paths of a `spec` or `test` task's +files+
  # argument to +within+, the suite root. Several paths are space-separated inside the
  # argument, so `rake 'spec[spec/util spec/agent]'` narrows to two — and Rake passes
  # them on to each component's task, which takes the ones it owns.
  #
  # An empty argument yields no paths rather than raising: +files+ is optional,
  # and the tasks read the empty list as "run the default set".
  #
  # +locations+ allows rspec's `<file>:<line>` and `<file>[1:2]` single-example
  # addressing, whose suffix is not part of the path and so comes off before the
  # path is resolved. Crystal's spec runner has no equivalent, so the spec tasks
  # leave it off and such a suffix is rejected there as a nonexistent path.
  module SuitePaths
    module_function

    def parse(input, repository_root:, within:, locations: false)
      paths = Shellwords.split(input.to_s)
      return paths if paths.empty?

      root = File.realpath(File.join(repository_root, within))
      paths.each do |path|
        validate_path!(path, repository_root: repository_root, root: root, within: within,
                             locations: locations)
      end
      paths
    end

    # Rejects anything outside +within+, including a path that only reaches
    # outside once resolved. The prefix check also rejects a leading `-`, which
    # would otherwise smuggle a compiler or runner flag in through a path.
    def validate_path!(path, repository_root:, root:, within:, locations:)
      raise ArgumentError, "Path must be under #{within}/: #{path}" unless path.start_with?("#{within}/")

      file = locations ? strip_location(path) : path
      resolved = File.realpath(File.expand_path(file, repository_root))
      return if resolved.start_with?("#{root}#{File::SEPARATOR}")

      raise ArgumentError, "Path escapes #{within}/: #{path}"
    rescue Errno::ENOENT
      raise ArgumentError, "Path does not exist: #{path}"
    end

    def strip_location(path) = path.sub(%r{(:\d+(?::\d+)*|\[[\d:,\]\[]+\])\z}, "")
  end

  # What this facet knows about a component: its shards target (the component name
  # with the project prefix put back), and the component's own linker argument
  # templates from the project file
  # (`crystal.components.<component>.linker.arguments` — see Project's doc comment
  # for the placeholders). The component's name is the model's, which is what the
  # slot holding this is filed under.
  #
  # Every component is a sibling — there is no privileged one whose specs live at
  # the top level. That special case used to exist, inferred from `name ==
  # target`, and it held only while one target happened to be spelled exactly
  # like the shard; a target rename would have silently pointed the top-level
  # suite at a directory that did not exist and enumerated nothing rather than
  # failing. One directory per component, unconditionally, has no such edge.
  # A +virtual+ component is one the project file declares without a shards
  # target behind it: it owns spec/test directories and takes part in every
  # testing task, but builds and packages nothing, so +target+ is nil. Code
  # shared by several targets and tested on its own (`src/util` with
  # `spec/util`) is the case this exists for.
  Component = Data.define(:target, :linker_arguments, :virtual, :entitlements)

  # A build profile: the platform plus the libc/linkage that identify a build
  # variant. Its dir names the bin/ subdirectory (<ostype>-<arch>-<libc>-<linkage>);
  # Project appends the build mode when building.
  Profile = Data.define(:platform, :libc, :linkage) do
    # Parse a profile dir string (<ostype>-<arch>-<libc>-<linkage>) back into a Profile.
    def self.parse(dir)
      ostype, arch, libc, linkage = dir.split("-")
      new(platform: Platform.new(ostype: ostype, arch: arch), libc: libc, linkage: linkage)
    end

    def dir = "#{platform.ostype}-#{platform.arch}-#{libc}-#{linkage}"

    # On macOS, Crystal auto-adds -fuse-ld=mold, which Apple's clang rejects.
    # Supplying our own -fuse-ld= disables that and forces Apple's ld; no-op elsewhere.
    def linker_args
      platform.ostype == "darwin" ? "-fuse-ld=/usr/bin/ld" : ""
    end

    def link_flags
      linker_args.empty? ? "" : " --link-flags=#{linker_args}"
    end
  end

  # All Crystal-specific project data, with derived build paths and task
  # definitions. +project+ is the model this was built against, which is where the
  # project's name, version and components come from; the rest of the members are
  # this facet's own. Includes Rake::DSL so the task action blocks — which run with
  # this instance as self — can call sh/mkdir_p/ln_sf and the rest.
  # +profiles+ maps each build mode to the profiles valid on the current host
  # (selected from the project file's `crystal.profiles` mapping by
  # Project.create), so a mode builds only the profiles listed under it.
  # Linker arguments are per component: the project file's
  # `crystal.components.<component>.linker.arguments` lists additional linker
  # argument templates for that component's compiles, with `{root}` expanding
  # to the absolute project root and `{ostype}`/`{arch}` to the build
  # profile's platform. A project whose binary links a vendored native archive points a
  # `-L{root}/…` entry at it and hooks whatever builds the archive onto the
  # `prepare` task from its Rakefile; this file stays ignorant of what is
  # being linked.
  Project = Data.define(
    :project, :bin_dir, :dist_dir, :coverage_dir, :src_dir, :profiles,
    :static_libraries, :identifier_prefix
  ) do
    include Rake::DSL

    # The components this facet has settings for, in the order the model holds them.
    # A component another facet invented — a Dockerfile or a workload with no shards
    # target behind it — has no `:crystal` slot and is none of this facet's business,
    # so it is left out rather than reached into.
    def components = project.components.values.select { |component| component[:crystal] }

    # This facet's settings for +component+, a model component.
    def settings_for(component) = component[:crystal]

    def target_for(component) = settings_for(component).target
    def virtual?(component) = settings_for(component).virtual

    # A component owns exactly one directory in each suite root, named after it.
    def spec_dir(component) = "spec/#{component.name}"
    def test_dir(component) = "test/#{component.name}"

    # What to call this component in task descriptions and error messages: the
    # target name when one exists, since that is what a build produces, and the
    # component name for a virtual one.
    def label(component) = target_for(component) || component.name

    # Names the coverage runner binary. Falls back to the component name, which
    # a virtual component has instead of a target.
    def spec_binary_name(component) = "#{label(component)}-specs"

    # The profiles this host builds in +mode+.
    def profiles_for(mode) = profiles.fetch(mode, [])

    # Whether the tools a task runs should color their output, per the NO_COLOR
    # convention (no-color.org): the variable being present and non-empty turns
    # color off whatever its value, so `NO_COLOR=` — set but empty — leaves it on.
    #
    # Read on each call rather than captured, so exporting the variable after the
    # tasks were defined still counts. Public so a project's own tasks pass the
    # same decision to tools this file knows nothing about.
    def color? = ENV.fetch("NO_COLOR", "").empty?

    # The version the shards manifest currently carries, which `version:lint:crystal`
    # compares against the project's and `version:update:crystal` overwrites.
    def shard_version = File.read(SHARD_PATH)[%r{^version:\s*(\S+)}, 1]

    # Write +version+ into the shards manifest. Only the version line is touched, so
    # the rest of the manifest — and its comments — survive.
    def write_shard_version(version)
      raw = File.read(SHARD_PATH)
      abort "could not find the version field in #{SHARD_PATH}" unless raw.match?(%r{^version:.*$})

      File.write(SHARD_PATH, raw.sub(%r{^version:.*$}, "version: #{version}"))
    end

    # `--no-color` for the tools that need telling — crystal, shards and ameba all
    # colorize regardless of NO_COLOR — or nothing at all when color is wanted, so
    # a command never carries an empty argument. Tools that honor NO_COLOR
    # themselves need neither, since they read the same environment.
    def no_color_arguments = color? ? [] : ["--no-color"]

    # The same flag as a command-string fragment, leading space included, for the
    # tasks that assemble a shell command rather than an argument array.
    def no_color_flag = no_color_arguments.map { |flag| " #{flag}" }.join

    # The components a build produces a binary for — everything but the virtual
    # ones. Building and packaging iterate these; the testing tasks iterate
    # +components+, since a virtual component is tested like any other.
    def buildable_components = components.reject { |component| virtual?(component) }

    # The preferred profile for the tools that always build in debug (spec,
    # cover, run), or nil if none apply. Prefers dynamic over static, and musl
    # over glibc.
    def default_profile
      profiles_for("debug").min_by { |profile| [profile.linkage == "dynamic" ? 0 : 1, profile.libc == "musl" ? 0 : 1] }
    end

    # The bin/ subdirectory for a build profile in the given mode (mode appended last).
    def bin_dir_for(profile:, mode:)
      File.join(bin_dir, "#{profile.dir}-#{mode}")
    end

    # The code-signing identifier for a component:
    # <identifier_prefix>.<project name>.<component>, or nil when the project
    # file sets no prefix (codesign then derives one from the file name, which
    # no code-signing requirement can pin). Reverse-DNS by convention, so a
    # peer requirement can name the binary rather than its file name.
    #
    # Built from the project name and the component rather than from the target,
    # so the identifier stays a property of what the binary *is* rather than of
    # what the target happens to be called. It also keeps the identifiers
    # mutually non-prefixing: `<prefix>.<name>` derived from bare target names
    # can end up a proper prefix of a sibling (`…my-tool` vs `…my-tool-run`),
    # which is a hazard for any requirement that ever matched on prefix rather
    # than equality.
    def signing_identifier(component:)
      identifier_prefix && "#{identifier_prefix}.#{project.name}.#{component}"
    end

    # The release archives `dist:package` writes, whichever are present. Globbed
    # rather than derived from this host's profiles, because the assets for the other
    # platforms arrive from CI and land here too — anything that carries a checksum
    # in a formula or a release is one of these. Public for exactly that.
    #
    # Matched on the `.tar.gz` a release archive carries, not on `#{name}-*` alone:
    # `helm:package` writes its chart into the same directory as `#{name}-<version>`,
    # and a chart package is not a release asset. Helm always names those `.tgz`.
    def release_assets
      Dir.glob(File.join(dist_dir, "**", "#{project.name}-*.tar.gz")).select { |path| File.file?(path) }
    end

    # Each component owns exactly its own directory, so there is nothing to
    # subtract: no component's tree contains another's. Dir sorts its matches itself.
    def spec_files(component:)
      Dir[File.join(spec_dir(component), "**", "*_spec.cr")]
    end

    # The complete linker arguments for a profile: the profile's own, plus
    # +component+'s `crystal.components.<component>.linker.arguments` from
    # the project file with `{root}` (the absolute project root — `shards
    # build` does not resolve relative `-L` paths) and `{ostype}`/`{arch}`
    # (the build profile's platform) expanded. Without a component — a compile
    # spanning several, such as `spec` given paths from more than one — the union
    # of every component's arguments applies; a search path a compile does not
    # need is inert.
    # Public because project-specific tasks in the Rakefile build Crystal
    # sources of their own and must link the same way the core tasks do.
    def combined_linker_args(profile:, component: nil)
      abort "no build profile configured for this host in #{PROJECT_PATH}" if profile.nil?

      expanded = linker_argument_templates(component).map do |argument|
        argument.gsub("{root}", Dir.pwd)
          .gsub("{ostype}", profile.platform.ostype)
          .gsub("{arch}", profile.platform.arch)
      end
      [profile.linker_args, *expanded].reject(&:empty?).join(" ")
    end

    # The linker argument templates a compile applies: +component+'s own, or the union
    # of every component's when there is no one component to attribute the compile to.
    def linker_argument_templates(component)
      return settings_for(component).linker_arguments if component

      components.flat_map { |other| settings_for(other).linker_arguments }.uniq
    end

    def crystal_link_flags(profile:, component: nil)
      %( --link-flags="#{combined_linker_args(profile: profile, component: component)}")
    end

    # Define all tasks for this project on +context+, the facet context: the
    # aggregates and per-component namespaces directly, and release/formula via the
    # generic factories. The context is passed down rather than reached for, so every
    # definition names where it is being made.
    def define_tasks(context)
      CLEAN.include("#{bin_dir}/*", "#{dist_dir}/*", coverage_dir)
      CLOBBER.include(bin_dir, "lib", ".shards")

      # The hook every compiling task depends on. Empty here; a project whose
      # `crystal.linker_args` point at a built artifact (a vendored native
      # archive, say) attaches its build from the Rakefile:
      # `task "prepare" => "tree_sitter:build"`.
      context.desc "Prepare compile prerequisites (hook project tasks here)"
      context.task "prepare"

      define_build_tasks(context)
      define_testing_tasks(context)
      define_dist_tasks(context)
      define_lint_tasks(context)
      define_version_tasks(context)

      context.desc "Install Crystal dependencies"
      context.task "deps" do
        sh("shards", "install", *no_color_arguments)
      end

      context.desc "Set up the project (install dependencies)"
      context.task "setup" => "deps"

      context.desc "List the build profiles supported on this host, per mode"
      context.task "profiles" do
        MODES.each do |mode|
          puts "#{mode}:"
          profiles_for(mode).each { |profile| puts "  #{profile.dir}" }
        end
      end

      components.each { |component| define_component_tasks(context, component: component) }
    end

    # One `crystal spec` invocation over +files+. +pattern+ becomes `--example`,
    # a substring of the full nested example name — the same filter
    # `<component>:test` takes, applied at run time, so it narrows output while
    # +files+ narrows what compiles. Without a +component+ the compile links with
    # every component's linker arguments, since the paths may span them and a
    # search path a compile does not need is inert.
    def run_specs(files:, pattern: nil, component: nil)
      link = combined_linker_args(profile: default_profile, component: component)
      command = ["crystal", "spec", *files, "-Dspec", "--link-flags=#{link}", *no_color_arguments]
      command += ["--example", pattern] unless pattern.to_s.empty?
      sh(*command)
    end

    # One rspec run over +files+ (directories, files, or `file:line`), with
    # +pattern+ as `--example`. Built as an argument array rather than a command
    # string, so a pattern containing a quote reaches rspec intact instead of
    # breaking the shell word it was interpolated into.
    def run_integration_tests(files:, pattern: nil)
      command = ["bundle", "exec", "rspec", "--format", "documentation",
                 "--require=./test/spec_helper.rb", *files,]
      command += ["--example", pattern] unless pattern.to_s.empty?
      sh(*command)
    end

    # The project-level testing aggregates. Unit tests and coverage span every
    # component, virtual ones included; integration tests span only those with a
    # suite to run.
    # Each aggregate is its components' tasks and nothing else. Rake re-scopes a task's
    # arguments onto every prerequisite that declares the same argument names, so
    # +files+ and +pattern+ reach each component without anything invoking anything:
    # both arguments stay optional and narrow independently, +files+ selecting what
    # compiles and +pattern+ filtering what runs. Quote the whole thing in zsh —
    # `rake 'spec[spec/util,IPv4Network]'` — or the brackets glob.
    #
    # Depending rather than invoking is also what keeps whatever a project hooks onto
    # `<component>:test` — building images, deploying them, waiting for a rollout — in
    # front of the tests that need it.
    def define_testing_tasks(context)
      context.desc "Run unit tests (optional arguments: spec paths, example pattern)"
      context.task "spec", %i[files pattern] => components.map { |component| "#{component.name}:spec" }

      suites = components.select { |component| integration_suite?(component) }
      context.desc "Run integration tests (optional arguments: test paths, example pattern)"
      context.task "test", %i[files pattern] => suites.map { |component| "#{component.name}:test" }

      context.desc "Run unit tests with coverage"
      context.task "cover" => components.map { |component| "#{component.name}:cover" }
    end

    # This facet's share of the project-wide version tasks: the shards manifest repeats
    # the project version because a manifest must carry one, so it is written from the
    # project file and reported when the two disagree.
    #
    # Each task joins its umbrella in rakelib/project.rake as a prerequisite, the same
    # way `lint:crystal` joins `lint` — which drift also joins, so `rake lint` catches a
    # stale manifest without anyone having to remember a separate task.
    def define_version_tasks(context)
      context.task "version:update" => "version:update:crystal"
      context.task "version:lint" => "version:lint:crystal"
      context.task "lint" => "version:lint"

      context.namespace "version" do
        context.namespace "update" do
          context.desc "Write the project version into #{SHARD_PATH}"
          context.task "crystal" do
            write_shard_version(project.version)
          end
        end

        context.namespace "lint" do
          context.desc "Report #{SHARD_PATH} disagreeing with the project version"
          context.task "crystal" do
            report_version_drift(manifest: SHARD_PATH, found: shard_version)
          end
        end
      end
    end

    # `lint` is a group task with no action of its own: each linter defines its
    # own subtask and joins the group as a prerequisite, so adding a linter
    # never edits this file — `rakelib/github.rake` does exactly that for the
    # workflows.
    def define_lint_tasks(context)
      context.desc "Run every linter"
      context.task "lint" => "lint:crystal"

      context.namespace "lint" do
        # Color is switched off by NO_COLOR in the environment rather than by a task
        # argument: it is the convention every tool already reads, and it describes the
        # whole run rather than one task's input, so no task has to declare it or pass
        # it on.
        context.desc "Run Ameba over the Crystal sources (NO_COLOR disables color)"
        context.task "crystal" do
          binary = "lib/ameba/bin/ameba"
          # An ameba pinned to a commit may ship no postinstall, so a fresh
          # `shards install` leaves only sources behind — build the linter from
          # the installed shard on first use (and again after any reinstall,
          # which removes the whole lib/ameba tree).
          unless File.executable?(binary)
            sh("crystal", "build", "lib/ameba/src/cli.cr", "-o", binary, "--release",
               *no_color_arguments)
          end
          sh(binary, *no_color_arguments)
        end
      end
    end

    # Release-asset packaging, one archive per profile this host has built.
    def define_dist_tasks(context)
      context.namespace "dist" do
        context.desc "Package every built release profile into #{dist_dir}/"
        context.task "package" do
          archives = package_release_profiles
          abort "no release build under #{bin_dir}/; run `rake build:release` first" if archives.empty?

          archives.each { |archive| puts archive }
        end
      end
    end

    # Define the per-component namespace (spec/test/cover/run). Every component
    # gets the testing tasks; a virtual one is skipped only where a binary is
    # unavoidable — `run` has nothing to run, and `test` deploys and exercises
    # binaries, so it is defined only when the component actually has an
    # integration suite of its own.
    def define_component_tasks(context, component:)
      context.namespace component.name do
        define_component_spec_task(context, component: component)
        define_component_cover_task(context, component: component)
        define_component_test_task(context, component: component) if integration_suite?(component)
        define_component_run_task(context, component: component) unless virtual?(component)
      end
    end

    # Whether +component+ has integration tests to run: a directory to point
    # rspec at. A virtual component usually has none — it builds no binary to
    # deploy — but nothing rules one out, so the directory decides rather than
    # the component's kind.
    def integration_suite?(component) = Dir.exist?(test_dir(component))

    # +files+ is whatever the caller asked for, which through `spec` is every
    # component's share at once, so this takes the paths under its own directory and
    # leaves the rest alone. Omitted, it defaults to every spec file the component owns.
    def define_component_spec_task(context, component:)
      context.desc "Run unit tests for #{label(component)} (optional arguments: spec paths, example pattern)"
      context.task "spec", %i[files pattern] => ["prepare"] do |_task, args|
        requested = SuitePaths.parse(args[:files], repository_root: Dir.pwd, within: "spec")
        files = own_suite_paths(component: component, requested: requested, dir: spec_dir(component))
        next if files.nil?

        run_specs(files: files, pattern: args[:pattern], component: component)
      end
    end

    # Mirrors the component's `spec` task: it takes its own share of +files+, defaults
    # to all of its suite, and +pattern+ filters by example name. rspec's
    # `<file>:<line>` addressing is accepted.
    def define_component_test_task(context, component:)
      context.desc "Run integration tests for #{label(component)} (optional arguments: test paths, example pattern)"
      context.task "test", %i[files pattern] do |_task, args|
        requested = SuitePaths.parse(
          args[:files], repository_root: Dir.pwd, within: "test", locations: true
        )
        files = own_suite_paths(component: component, requested: requested, dir: test_dir(component),
                                default: [test_dir(component)])
        next if files.nil?

        run_integration_tests(files: files, pattern: args[:pattern])
      end
    end

    # The paths of +requested+ that belong to +component+, the whole suite when nothing
    # was requested, or nil to say there is nothing here to run.
    #
    # nil is what an aggregate's fan-out needs: every component receives the same
    # +files+, and the ones that own none of them have to stand down. It says so rather
    # than passing silently, since a run that tested nothing should not look like a run
    # that passed. A path no component owns is a different matter and aborts, so a
    # mistyped one cannot be mistaken for a component standing down.
    def own_suite_paths(component:, requested:, dir:, default: nil)
      return default || spec_files(component: component) if requested.empty?

      mine = requested.select { |path| path == dir || path.start_with?("#{dir}/") }
      return mine unless mine.empty?

      unless requested.any? { |path| components.any? { |other| owns_path?(other, path) } }
        abort "no component owns #{requested.join(", ")}"
      end

      warn "#{component.name}: nothing requested is under #{dir}/, skipping"
      nil
    end

    # Whether +path+ lies in either of +component+'s suite directories.
    def owns_path?(component, path)
      [spec_dir(component), test_dir(component)].any? do |dir|
        path == dir || path.start_with?("#{dir}/")
      end
    end

    def define_component_cover_task(context, component:)
      context.desc "Run unit tests with coverage for #{label(component)}"
      context.task "cover" => ["prepare"] do
        bin = bin_dir_for(profile: default_profile, mode: "debug")
        mkdir_p bin
        mkdir_p ".work"

        runner = ".work/run_#{component.name}_specs.cr"
        requires = spec_files(component: component).map { |path| %(require "../#{path}") }
        File.write(runner, "#{requires.join("\n")}\n")

        spec_binary = File.join(bin, spec_binary_name(component))
        link = crystal_link_flags(profile: default_profile, component: component)
        sh "crystal build #{runner} --output #{spec_binary} --debug#{link}#{no_color_flag}"

        coverage_output = File.join(coverage_dir, component.name)
        mkdir_p coverage_output
        sh "kcov --clean --include-path=./#{src_dir} #{coverage_output} #{spec_binary}"
      end
    end

    def define_component_run_task(context, component:)
      target = target_for(component)

      context.desc "Run the application in debug mode"
      context.task "run" => ["prepare"] do
        bin = bin_dir_for(profile: default_profile, mode: "debug")
        link = crystal_link_flags(profile: default_profile, component: component)
        sh "shards run #{target} --output=#{bin}/#{target} " \
           "--debug#{link}#{no_color_flag}"
      end
    end

    # Project-level build tasks: build:<mode>:<profile> for each profile that
    # mode builds, build:<mode> to build them all, `build` for both modes, and
    # a `debug` shortcut for the preferred debug profile. Linkage follows each
    # profile.
    def define_build_tasks(context)
      context.namespace "build" do
        MODES.each do |mode|
          mode_profiles = profiles_for(mode)

          context.namespace mode do
            mode_profiles.each do |profile|
              context.desc "Build all targets for #{profile.dir} (#{mode})"
              context.task(profile.dir => "prepare") { build_profile(profile: profile, mode: mode) }
            end
          end

          context.desc "Build every #{mode} profile for this host"
          context.task mode => mode_profiles.map { |profile| "build:#{mode}:#{profile.dir}" }
        end
      end

      context.desc "Build every host profile (debug and release)"
      context.task "build" => MODES.map { |mode| "build:#{mode}" }

      context.desc "Build the preferred debug profile for this host"
      context.task("debug" => "prepare") { build_profile(profile: default_profile, mode: "debug") }
    end

    private

    # One archive per release profile already built for this host, so a matrix
    # job that built one profile packages exactly that one and nothing else.
    # Profiles with no build directory are skipped rather than failing: a CI
    # runner only ever builds the profile matching its own arch.
    def package_release_profiles
      mkdir_p dist_dir
      profiles_for("release").filter_map do |profile|
        bin = bin_dir_for(profile: profile, mode: "release")
        next unless Dir.exist?(bin)

        package_profile(profile: profile, bin: bin)
      end
    end

    # `<name>-<profile>.tar.gz`, holding every component's binary at the
    # archive root — one asset per platform rather than one per binary, since a
    # multi-target project's binaries are typically useless apart.
    #
    # The members are named explicitly rather than globbed, so a build
    # directory's own scratch (`static-libs`, `.dwarf` companions) can never
    # end up in a release asset, and a missing binary fails here instead of
    # shipping an incomplete archive.
    def package_profile(profile:, bin:)
      targets = buildable_components.map { |component| target_for(component) }
      missing = targets.reject { |target| File.file?(File.join(bin, target)) }
      abort "#{bin}/ is missing #{missing.join(", ")}; run `rake build:release` first" unless missing.empty?

      archive = File.join(dist_dir, "#{project.name}-#{profile.dir}.tar.gz")
      rm_f archive
      # COPYFILE_DISABLE: bsdtar otherwise stores an `._name` AppleDouble
      # member for every file carrying extended attributes, which each consumer
      # then has to know to ignore.
      sh({ "COPYFILE_DISABLE" => "1" }, "tar", "--create", "--gzip",
         "--file", archive, "--directory", bin, *targets)
      archive
    end

    # Build every component for a profile in the given mode.
    def build_profile(profile:, mode:)
      abort "no build profile configured for this host in #{PROJECT_PATH}" if profile.nil?
      # Fail fast on a missing Developer ID before a slow release build.
      Codesign.codesign_identity(release: true) if mode == "release" && profile.platform.ostype == "darwin"
      buildable_components.each { |component| build_target(component: component, mode: mode, profile: profile) }
    end

    # Build one component: assemble the shards command, verify the linkage,
    # sign, notarize (release), and symlink the convenience path. A macOS
    # `system-static` build links the Homebrew deps statically; everything
    # else links as the profile dictates.
    def build_target(component:, mode:, profile:)
      target = target_for(component)
      bin = bin_dir_for(profile: profile, mode: mode)
      mkdir_p bin
      output = "#{bin}/#{target}"
      # macOS cannot fully static-link (no static libSystem); a `system-static`
      # profile instead static-links the Homebrew deps in static_libraries and
      # leaves the OS libraries dynamic, so the binary matches its profile dir in
      # every mode.
      deps_static = profile.platform.ostype == "darwin" && profile.linkage == "static"
      cmd = "shards build #{target} --output=#{output} --#{mode}"
      cmd += " --static" if profile.linkage == "static" && profile.libc != "system"
      cmd += link_flags_for(profile: profile, deps_static: deps_static, bin: bin,
                            component: component)
      cmd += no_color_flag
      sh cmd
      assert_only_system_dylibs(output) if deps_static
      # The hardened runtime rejects at launch any library that is neither a system
      # one nor signed by the same team, so it can only be applied to a build that
      # links nothing else — which on macOS is exactly what deps_static arranges and
      # assert_only_system_dylibs has just confirmed. A dynamic build (every debug
      # one) links the Homebrew libraries Crystal needs and is signed unhardened; it
      # is not a binary that leaves this machine.
      entitlements = component_entitlements_path(component: component, binary: output)
      Codesign.codesign_binary(path: output, release: mode == "release", hardened: deps_static,
                               identifier: signing_identifier(component: component.name),
                               entitlements: entitlements)
      Codesign.notarize_binary(path: output) if mode == "release"
      ln_sf File.join(File.basename(bin), target), File.join(bin_dir, target)
    end

    # The entitlements plist to sign +binary+ with, written fresh from what the project
    # file declares for +component+, or nil when it declares none — a component that
    # needs no capability the hardened runtime withholds is signed without any.
    #
    # Written beside the binary it belongs to, one per profile, so what a given build
    # was signed with is visible next to it rather than in a scratch directory shared
    # by every profile. `dist:package` names its archive members explicitly, so this
    # never ships as part of a release asset.
    def component_entitlements_path(component:, binary:)
      entitlements = settings_for(component).entitlements
      return nil if entitlements.empty?

      Codesign.write_entitlements_plist(entitlements: entitlements, path: "#{binary}-entitlements.plist")
    end

    # The `--link-flags` argument for a build: the combined linker args, plus
    # (on a macOS deps-static build) a search path holding only the static
    # archives so `-l<name>` resolves to the `.a` before any Homebrew `.dylib`.
    def link_flags_for(profile:, deps_static:, bin:, component:)
      linker = combined_linker_args(profile: profile, component: component)
      if deps_static
        extra = "-L#{static_lib_dir(bin)} -Wl,-search_paths_first"
        linker = [linker, extra].reject(&:empty?).join(" ")
      end
      linker.empty? ? "" : %( --link-flags="#{linker}")
    end

    # A directory (beside the built binary) of symlinks to the static archives of every
    # library a Crystal binary might link, plus any the project adds in
    # static_libraries — no `.dylib`, so the linker picks the `.a`.
    #
    # Offering an archive the program never references costs nothing: the linker pulls a
    # member only when a symbol demands it. So this errs towards offering too many, and
    # a library Homebrew has no archive for is skipped rather than aborting — that is
    # how a platform library announces itself (macOS ships libiconv as a dylib only,
    # and library validation accepts it because it is a platform library).
    def static_lib_dir(bin)
      dir = File.join(bin, "static-libs")
      rm_rf dir
      mkdir_p dir
      prefix = capture("brew", "--prefix").to_s.strip
      abort "a deps-static build needs Homebrew's archives, but `brew --prefix` failed" if prefix.empty?

      (RUNTIME_LIBRARIES | static_libraries).each do |name|
        archive = Dir["#{prefix}/opt/*/lib/lib#{name}.a", "#{prefix}/lib/lib#{name}.a"].first
        ln_sf archive, File.join(dir, "lib#{name}.a") if archive
      end

      File.expand_path(dir)
    end

    # The dynamic libraries a Mach-O binary links, per `otool -L`. Its first
    # line names the binary itself, and every dependency carries a trailing
    # version annotation; both are dropped.
    def linked_dylibs(binary)
      listed = capture("otool", "-L", binary)
      abort "otool -L #{binary} failed; cannot verify the linkage of #{binary}" if listed.nil?

      listed.lines.drop(1).map { |line| line.strip.sub(%r{\s+\(compatibility version .*\)\z}, "") }.reject(&:empty?)
    end

    # Fail a deps-static build that still links a library macOS does not ship —
    # a sign static_libraries is missing an entry. Such a binary runs here and
    # nowhere else, so this must stop the build rather than warn: it runs before
    # signing so a rejected binary is never signed or uploaded to Apple.
    def assert_only_system_dylibs(binary)
      external = linked_dylibs(binary).reject { |lib| lib.start_with?(*SYSTEM_LIBRARY_PREFIXES) }
      return if external.empty?

      abort <<~MESSAGE
        #{binary} links #{external.size} librar#{external.size == 1 ? "y" : "ies"} macOS does not ship, so it would not run on another Mac:
        #{external.map { |lib| "  #{lib}" }.join("\n")}
        Add each one's `-l` name to crystal.static_libraries in #{PROJECT_PATH}.
      MESSAGE
    end

    # Build a Crystal::Project from the model (name, version, components) and the
    # project file's `crystal` section (profiles, static libraries, signing prefix,
    # and each component's linker arguments), against the detected host.
    def self.create(project)
      config = project.config(:crystal)
      abort "#{PROJECT_PATH} has no `crystal` key holding the build settings" if config.empty?

      host = ::Host.detect

      # Per mode, the common profiles plus that mode's own, keeping only the
      # ones valid on the current host.
      os_profiles = config.fetch("profiles").fetch(host.osname.to_s, {})
      common = os_profiles.fetch(COMMON_PROFILES, [])
      profiles = MODES.to_h do |mode|
        listed = (common | os_profiles.fetch(mode, [])).map { |p| Profile.parse(p) }
        [mode, listed.filter { |p| p.platform == host.platform }]
      end

      new(
        project: project,
        bin_dir: "bin",
        dist_dir: "dist",
        coverage_dir: "coverage",
        src_dir: "src",
        profiles: profiles,
        static_libraries: config.fetch("static_libraries", []),
        identifier_prefix: config["identifier_prefix"]
      )
    end
  end

  module_function

  # The project's components as `{ name => Component }`, from both files that
  # describe them: every shards target in shard.yml is a component that builds a
  # binary, and the project file's `crystal.components` may declare further ones. A
  # declared component no target backs must say `virtual: true`; without the flag it
  # is an error rather than a component that silently builds nothing, so a misspelled
  # name (or a target renamed in shard.yml alone) fails loudly.
  #
  # Shards targets come first, so `rake -T` lists the components that produce
  # something ahead of the ones that only carry tests.
  #
  # The prefix a target name carries is the shards manifest's own name, not the
  # model's: it is that file's convention for naming a target after the shard.
  def components(project)
    shard = YAML.load_file(SHARD_PATH)
    name = shard.fetch("name")
    declared = project.config(:crystal)["components"] || {}
    targets = shard.fetch("targets").to_h { |target, _| [target.delete_prefix("#{name}-"), target] }

    virtual, unbacked = (declared.keys - targets.keys).partition do |component|
      (declared[component] || {})["virtual"]
    end
    unless unbacked.empty?
      abort "#{PROJECT_PATH}: crystal.components #{unbacked.join(", ")} name no target in " \
            "#{SHARD_PATH}; add the target there, or mark them `virtual: true` to declare " \
            "components that carry tests but build no binary"
    end

    settings = targets.map { |component, target| [component, component_settings(target, declared[component])] }
    settings += virtual.map { |component| [component, component_settings(nil, declared[component])] }
    settings.to_h
  end

  # +target+ is nil for a virtual component, which is what makes it virtual.
  def component_settings(target, declared)
    settings = declared || {}
    Component.new(
      target: target, virtual: target.nil?,
      linker_arguments: settings.dig("linker", "arguments") || [],
      entitlements: RUNTIME_ENTITLEMENTS.merge(settings.fetch("entitlements", {}))
    )
  end
end

# Crystal names no `after:`: it is the facet that contributes the components the
# others read, so it has nothing of its own to follow.
facet :crystal do
  project.add_facet(:crystal) { Crystal::Project.create(project) }
  project.add_version_file(Crystal::SHARD_PATH)
  # The same write `version:update:crystal` performs, offered to whoever writes the
  # project version out in one go — `release` does, twice inside one procedure.
  project.add_version_writer { |version| project[:crystal].write_shard_version(version) }

  Crystal.components(project).each do |name, settings|
    project.add_component(name).add_facet(:crystal) { settings }
  end

  project[:crystal].define_tasks(self)
end
