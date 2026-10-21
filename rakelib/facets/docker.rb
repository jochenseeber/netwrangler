# frozen_string_literal: true

require_relative "../project"

# Generic Docker image tasks, usable by any project whatever it is written in:
# nothing here knows what goes into an image, only how to address, build, push,
# load and run one — the Dockerfile owns the rest.
#
# Discovery — one image per Dockerfile found, none at all for a project with
# none — happens in the facet block at the bottom. Everything above it is inert
# until required, so any facet may read Docker::Settings or a component's
# Docker::Component slot without an `after:` edge to this one.
module Docker
  # A project's own Dockerfile, plus one per component: `Dockerfile.<component>`.
  DOCKERFILE_GLOB = "Dockerfile{,.*}"

  # Where docker keeps its configuration for this project's builds, relative to the
  # project. Under the build's own working directory rather than `~/.docker`, so a
  # build reads and writes only what belongs to it — the same reason the kind facet
  # keeps its kubeconfig there.
  #
  # A registry login is the one thing this does not carry: `docker login` writes to
  # whichever configuration directory it is given, so pushing to a registry that
  # requires authentication needs a login made against this one.
  CONFIG_PATH = ".work/docker"

  DEFAULT_CONTEXT = "."

  # This facet's own settings, from the project file's `docker:` section: the
  # repository namespace images are pushed under (nil for an image addressed by
  # name alone), the platforms a multi-arch build targets, and the build context.
  Settings = Data.define(:repository, :platforms, :context) do
    def self.create(project)
      config = project.config(:docker)
      new(repository: config["repository"], platforms: config.fetch("platforms", []),
          context: config.fetch("context", DEFAULT_CONTEXT))
    end
  end

  # What this facet knows about a component: the Dockerfile that builds its image.
  Component = Data.define(:dockerfile)

  # So the task actions below — which run with the Docker module as self, since
  # they are defined inside its module-function methods — can call sh directly.
  extend Rake::DSL

  module_function

  # The configuration directory every docker command here is given, created on demand
  # since docker writes into it but will not create it.
  def config_dir
    directory = File.expand_path(CONFIG_PATH)
    FileUtils.mkdir_p(directory)
    directory
  end

  def docker_env = { "DOCKER_CONFIG" => config_dir }

  # Every Dockerfile this project builds an image from, in a stable order.
  def dockerfiles = Dir.glob(DOCKERFILE_GLOB)

  # The component a Dockerfile builds the image for, or nil for a project's single
  # unsuffixed Dockerfile.
  def dockerfile_component(dockerfile)
    component = File.basename(dockerfile).delete_prefix("Dockerfile").delete_prefix(".")
    component.empty? ? nil : component
  end

  # What an image is called: the project, and the component when a Dockerfile names
  # one.
  def image_name(project, component) = [project.name, component].compact.join("-")

  # "repository/name:tag", or "name:tag" for an image with no repository namespace.
  def reference(name:, tag:, repository: nil)
    [repository, "#{name}:#{tag}"].compact.join("/")
  end

  # The full reference of the image built for +component+ (nil for a project-wide
  # image). Public so a project's own tasks — handing an image to a local cluster,
  # say — can name what was built without restating how a reference is composed.
  def reference_for(project, component)
    reference(name: image_name(project, component), tag: project.version,
              repository: project[:docker].repository)
  end

  # The `ARG` names a Dockerfile declares, deduplicated: a multi-stage build
  # redeclares an argument in each stage that uses it, and one `--build-arg` covers
  # them all.
  def dockerfile_args(dockerfile)
    File.readlines(dockerfile).filter_map { |line| line[%r{^\s*ARG\s+([A-Za-z_]\w*)}, 1] }.uniq
  end

  # Every `ARG` a Dockerfile declares, taken from the environment when it is set
  # there. This is how a build is steered from outside without a setting per
  # argument: `CRYSTAL_VERSION=1.22.0 rake docker:build` overrides that one `ARG` and
  # leaves the rest at the Dockerfile's defaults. Each value is read when the task
  # runs, so exporting the variable after the tasks were defined still counts.
  #
  # The environment is trusted here, so a variable set for some unrelated purpose
  # that happens to share an `ARG`'s name does change the build. Name the arguments
  # distinctly, or pass the build argument explicitly, if that matters.
  def build_args(dockerfile)
    dockerfile_args(dockerfile).to_h { |argument| [argument, -> { ENV.fetch(argument, nil) }] }
  end

  # +build_args+ as `--build-arg` flags. A value responding to +call+ is resolved
  # when the task runs rather than when it is defined, so an entry reading the
  # environment or a manifest sees the value at invocation. A nil value is dropped
  # entirely, leaving the Dockerfile's own `ARG` default in force — which is not the
  # same as passing an empty string, and is why nil is not simply stringified.
  def build_arg_flags(build_args)
    build_args.filter_map do |argument, value|
      resolved = value.respond_to?(:call) ? value.call : value
      "--build-arg=#{argument}=#{resolved}" unless resolved.nil?
    end
  end

  # The ports an image declares with `EXPOSE`, as `--publish` flags mapping each to
  # the same port on the host. Read from the built image rather than parsed out of
  # the Dockerfile, so `EXPOSE ${PORT}`, a port inherited from a base image, and
  # multi-stage builds all report what the image actually declares.
  #
  # An image that exposes nothing yields no flags: the ports a container serves are
  # a property of the image, so there is nowhere else for this to come from, and
  # publishing a port nothing listens on only invites the belief that something
  # does. Deliberately not `docker run -P`, which would assign random host ports.
  def publish_flags(reference)
    exposed = capture(docker_env, "docker", "image", "inspect", reference,
                      "--format", "{{json .Config.ExposedPorts}}")
    abort "cannot inspect #{reference}; build it first" if exposed.nil?

    (JSON.parse(exposed) || {}).keys.map do |exposure|
      port = exposure.split("/").first
      "--publish=#{port}:#{exposure}"
    end
  end

  # A `docker buildx build` invocation as an argument array, so a build argument or
  # tag containing a space or quote reaches docker intact. +platforms+ empty builds
  # for the host architecture alone; +mode+ is :manifest to build without keeping
  # the result (a cross-platform check), :load to load it into the local daemon, or
  # :push to publish it.
  def build_command(reference:, dockerfile:, context:, platforms:, build_args:, mode:)
    command = ["docker", "buildx", "build", "--file=#{dockerfile}", "--tag=#{reference}"]
    command << "--platform=#{platforms.join(",")}" unless platforms.empty?
    command.concat(build_arg_flags(build_args))
    # A multi-arch build cannot be loaded into the local daemon, which holds no
    # manifest lists, so :load is the one mode that never spans platforms.
    output =
      case mode
      when :load then "--load"
      when :push then "--push"
      else "--output=type=cacheonly"
      end
    command << output << context
  end

  # Define a `docker` namespace of tasks for the image +dockerfile+ builds, in
  # whatever namespace +context+ is currently in:
  #
  #   build   every configured platform, kept only in the build cache — a check
  #           that the image builds everywhere it has to, with nothing left behind
  #   load    this host's architecture only, loaded into the local daemon, so the
  #           image can be run or handed to a local cluster
  #   push    every configured platform, built and pushed in one step, because a
  #           multi-arch manifest cannot be pushed from the local daemon afterwards
  #   run     the loaded image, in a container removed on exit, publishing whatever
  #           the image declares with `EXPOSE`
  #
  # Descriptions name +component+ rather than the image, which is only known once a
  # component's other facets (whichever gives it a name worth a reference) exist.
  def define_image_tasks(context, project:, dockerfile:, component:, run_arguments: [])
    args = build_args(dockerfile)
    label = component ? "#{component} " : ""

    build = lambda do |mode:, all_platforms:|
      settings = project[:docker]
      build_command(reference: reference_for(project, component), dockerfile: dockerfile,
                    context: settings.context,
                    platforms: all_platforms ? settings.platforms : [],
                    build_args: args, mode: mode)
    end

    context.namespace "docker" do
      context.desc "Build the #{label}image for every configured platform " \
                   "(kept in the build cache only — use `load` for a runnable image)"
      context.task "build" do
        sh(docker_env, *build.call(mode: :manifest, all_platforms: true))
      end

      context.desc "Build the #{label}image for this host and load it into the local daemon"
      context.task "load" do
        sh(docker_env, *build.call(mode: :load, all_platforms: false))
      end

      context.desc "Build and push the #{label}image"
      context.task "push" do
        sh(docker_env, *build.call(mode: :push, all_platforms: true))
      end

      context.desc "Run the #{label}image in a container, publishing the ports it exposes"
      context.task "run" => "load" do
        image = reference_for(project, component)
        sh(docker_env, "docker", "run", "--rm", *publish_flags(image), image,
           *run_arguments)
      end
    end
  end

  # Project-level `docker:*`, each fanning out to the same task on every component's
  # image. +components+ is in Dockerfile discovery order, not the model's — this
  # facet's own components may include one no other facet contributed (a Dockerfile
  # with no shards target behind it), and the model's insertion order for those
  # already shared with another facet is that facet's to keep, not this one's to
  # reorder.
  def define_aggregate_tasks(context, components:)
    { "build" => "Build", "load" => "Build and locally load", "push" => "Build and push" }
      .each do |action, verb|
        context.desc "#{verb} every component image"
        context.task "docker:#{action}" => components.map { |component| "#{component}:docker:#{action}" }
      end
  end
end

# Docker follows crystal so that a Dockerfile naming an existing component — one
# of crystal's shards targets, say — merges into the same model Component crystal
# already created, rather than racing it to create a second one first and
# scrambling the model's component order for every facet that iterates it.
facet :docker, after: %i[crystal] do
  project.add_facet(:docker) { Docker::Settings.create(project) }

  named, unnamed = Docker.dockerfiles.partition { |dockerfile| Docker.dockerfile_component(dockerfile) }

  # `docker:build` would have to be both the unsuffixed image's own task and the
  # aggregate over the component images, so the two layouts cannot be mixed.
  if !unnamed.empty? && !named.empty?
    abort "both #{unnamed.join(", ")} and #{named.join(", ")} exist; a project builds " \
          "either one image from Dockerfile or one per component from Dockerfile.<component>"
  end

  if !unnamed.empty?
    Docker.define_image_tasks(self, project: project, dockerfile: unnamed.first, component: nil)
  elsif !named.empty?
    components = named.map { |dockerfile| Docker.dockerfile_component(dockerfile) }

    named.each do |dockerfile|
      component = Docker.dockerfile_component(dockerfile)
      project.add_component(component).add_facet(:docker) { Docker::Component.new(dockerfile: dockerfile) }

      namespace component do
        Docker.define_image_tasks(self, project: project, dockerfile: dockerfile, component: component)
      end
    end

    Docker.define_aggregate_tasks(self, components: components)
  end
end
