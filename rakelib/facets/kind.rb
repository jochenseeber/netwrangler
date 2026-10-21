# frozen_string_literal: true

require "ipaddr"
require "socket"
require "uri"

require_relative "../project"

# Generic kind (Kubernetes-in-Docker) tasks, usable by any project that develops
# against a local cluster: the cluster's lifecycle, getting an image into its nodes,
# and rolling a workload over to a newly loaded image.
#
# Only the facet block at the bottom contributes anything, and it contributes nothing
# at all to a project whose project file has no `kubernetes` section. Everything above
# it is inert until required, so any facet may read Kind::Settings without an `after:`
# edge to this one.
#
# What a project deploys and how it deploys it stays with the project: nothing here
# runs helm, helmfile or `kubectl apply`, it only depends on the task named by
# `kubernetes.deploy`. The `kubernetes` section holds what cannot be discovered:
#
#   deploy        the project's own task that applies its manifests
#   version       the Kubernetes version to create the cluster at
#   cluster       the cluster's name, defaulting to the project's own
#   namespace     where those workloads live, likewise defaulting to it
#   environment   the helmfile environment `kind:sync` syncs
#   timeout       how long `kind:restart` waits for each rollout
#
# Both of those names are RFC 1123 DNS labels: derived from the project's name they
# are reduced to one, and a name set here is checked against it.
#
# The workloads to restart are not configured at all — they are the Deployments,
# StatefulSets and DaemonSets the project's own manifests declare.
module Kind
  # Where a kind cluster config lives, by convention. Without one kind creates its
  # default single-node cluster, so a project needs one only for a topology.
  CONFIG_GLOBS = ["deploy/kind-config.yaml"].freeze

  # How long a rollout is waited for, when the project file states nothing.
  DEFAULT_TIMEOUT = "120s"

  # The helmfile environment to sync, when the project file states nothing. `kind` by
  # convention, since that is the environment a project adds for its local cluster.
  DEFAULT_ENVIRONMENT = "kind"

  # What Kubernetes requires of a namespace, and accepts for anything else named in a
  # cluster: lowercase alphanumerics and hyphens, no more than 63 characters, first
  # and last character alphanumeric.
  LABEL_LIMIT = 63
  LABEL_PATTERN = %r{\A[a-z0-9]([-a-z0-9]*[a-z0-9])?\z}

  # A project's helmfile, whose `sync` is the deploy this facet falls back to when the
  # project names no task of its own.
  HELMFILE_GLOB = "{,deploy/}helmfile.yaml{,.gotmpl}"

  # Where the cluster's kubeconfig is written, relative to the project. Under the
  # build's own working directory rather than `~/.kube/config`, so a throwaway
  # cluster's credentials never land among the user's real ones. Ignored by git along
  # with the rest of that directory.
  KUBECONFIG_PATH = ".work/kube/config"

  # A name for the API server's loopback address, and the name its certificate is
  # issued for. Docker Desktop publishes the first for the host it runs on; the second
  # is a subject alternative name Kubernetes puts on every API server certificate.
  # Used together by +name_the_api_server+ — see there for why a name is needed at all.
  API_SERVER_HOST = "kubernetes.docker.internal"
  API_SERVER_CERT_NAME = "kubernetes"

  # Chart CRD directories. Helm installs a chart's `crds/` only when the CRDs are
  # absent and never updates one, so an edited CRD would otherwise never reach a
  # cluster that already has the old version — hence applying them on every sync.
  CRD_GLOB = "**/crds"

  # The kinds a rollout applies to. A Job or a Pod is not restarted, it is replaced,
  # and neither has a rollout to wait on.
  WORKLOAD_KINDS = %w[deployment statefulset daemonset].freeze

  # All the kind-specific project data, with the names derived from it and the task
  # definitions. +project+ is the model this was built against, which is where the
  # project's name and its components come from; the rest of the members are this
  # facet's own, from the project file's `kubernetes` section.
  #
  # The two names are held as declared — +declared_cluster+ and +declared_namespace+,
  # either of them nil when the project file states none — and checked by the readers
  # below rather than here, so that nothing a project file gets wrong is discovered
  # while the tasks are being defined.
  #
  # Includes Rake::DSL so the task action blocks — which run with this instance as
  # self — can call sh. The +namespace+ reader shadows Rake's own `namespace` in doing
  # so, which is one more reason every declaration below is made on the facet context
  # rather than bare.
  Settings = Data.define(
    :project, :declared_cluster, :declared_namespace, :node_version, :environment,
    :timeout, :deploy
  ) do
    include Rake::DSL

    # The cluster's name, and the namespace its workloads live in: what the project
    # file states, or the project's own name reduced to a label when it states nothing.
    #
    # Checked when read rather than when the settings are built, so a project file
    # stating a name Kubernetes would reject still lists its tasks and fails on the
    # tasks that need the name — the same reason +node_version+ is not fetched up
    # front. Every reader of either name is inside a task action, so the check happens
    # exactly when the name is about to be used.
    def cluster = Kind.configured_label("cluster", declared_cluster) || project_label
    def namespace = Kind.configured_label("namespace", declared_namespace) || project_label

    # The kubeconfig context name kind gives the cluster.
    def kube_context = "kind-#{cluster}"

    # Where this cluster's kubeconfig is kept, and the environment every command that
    # talks to the cluster is given.
    #
    # A throwaway cluster's credentials do not belong in the user's own kubeconfig:
    # `kind export kubeconfig` would merge them into `~/.kube/config`, leaving a
    # context behind for a cluster that is deleted and recreated constantly, next to
    # the contexts of clusters that matter. Kept under the build's own working
    # directory instead, it is created with the cluster, thrown away with it, and
    # never touches anything the user configured by hand.
    def kubeconfig = File.expand_path(KUBECONFIG_PATH)

    def kube_env = { "KUBECONFIG" => kubeconfig }

    # Every command that writes the kubeconfig needs its directory to exist first —
    # kind writes the file but not the path to it.
    def prepare_kubeconfig = mkdir_p(File.dirname(kubeconfig), verbose: false)

    # Point the kubeconfig at the API server by name rather than by loopback address,
    # where a name for it exists.
    #
    # kind publishes the API server on a loopback port, and Go's HTTP client never
    # sends a request for a loopback address through a proxy: the rule is compiled
    # into net/http and no NO_PROXY setting reaches it. Every Go tool here — kubectl,
    # helm, helmfile — therefore dials the address directly, which a sandbox that
    # allows outbound traffic only through its proxy refuses. Given a name instead,
    # the same tools proxy the connection like any other.
    #
    # The API server's certificate is issued for the address, not for this name, so
    # the name to verify against is pinned separately to one the certificate carries.
    # A no-op wherever the name does not resolve — a plain Linux host, CI — leaving
    # the kubeconfig kind wrote untouched.
    def name_the_api_server
      server = capture(kube_env, "kubectl", "config", "view", "--minify",
                       "--output=jsonpath={.clusters[0].cluster.server}")
      port = server && URI.parse(server.strip).port
      return if port.nil? || !Kind.loopback_alias?(API_SERVER_HOST)

      sh(kube_env, "kubectl", "config", "set-cluster", kube_context,
         "--server=https://#{API_SERVER_HOST}:#{port}",
         "--tls-server-name=#{API_SERVER_CERT_NAME}")
    end

    def config_file = Dir.glob(CONFIG_GLOBS).first
    def helmfile = Dir.glob(HELMFILE_GLOB).first
    def crd_dirs = Dir.glob(CRD_GLOB).select { |path| File.directory?(path) }

    # The components a workload can belong to: the ones an image was built for, since
    # a component whose image this project builds is one whose workload it may roll
    # over. A component with no Dockerfile behind it has no `:docker` slot and is none
    # of this facet's business, so it is left out rather than reached into.
    #
    # Ordered by Dockerfile rather than by the model, which holds its components in
    # the order the facet that invented them contributed them: every
    # `<component>:kind:upload` depends on the matching `<component>:docker:load`, so
    # `kind:upload` fans out the way `docker:load` does.
    def components
      with_image = project.components.values.select { |component| component[:docker] }
      with_image.sort_by { |component| component[:docker].dockerfile }
    end

    # The task that puts the project's manifests on the cluster: whatever the project
    # file names, or the helmfile sync defined below when a helmfile is what it has.
    def deploy_task
      return deploy if deploy
      return "kind:sync" if helmfile

      abort "#{::Project::FILE} has no kubernetes.deploy and there is no helmfile to " \
            "sync; name the task that deploys this project"
    end

    # Define every kind task on +context+, the facet context. The context is passed
    # down rather than reached for, so every definition names where it is being made.
    def define_tasks(context)
      define_cluster_tasks(context)
      define_upload_tasks(context)
      define_deploy_tasks(context)
      define_project_tasks(context)
    end

    # The cluster's own lifecycle.
    def define_cluster_tasks(context)
      config = config_file

      context.namespace "kind" do
        context.desc ["Create the kind cluster", config && "from #{config}"].compact.join(" ")
        context.task "start" do
          prepare_kubeconfig
          sh(kube_env, *create_cluster_command(config))
        end

        context.desc "Delete the kind cluster"
        context.task "delete" do
          sh(kube_env, "kind", "delete", "cluster", "--name=#{cluster}")
        end

        context.desc "Export the kubeconfig of the kind cluster"
        context.task "kubeconfig" do
          prepare_kubeconfig
          sh(kube_env, "kind", "export", "kubeconfig", "--name=#{cluster}")
          name_the_api_server
        end
      end
    end

    # `<component>:kind:upload`: build the component's image and load it into the
    # cluster's nodes. This is the one thing that is per-component — an image belongs
    # to one — and both the image and the task that builds it come from the docker
    # facet, which this one follows, so the task depended on is already defined.
    def define_upload_tasks(context)
      components.each do |component|
        context.namespace component.name do
          context.namespace "kind" do
            context.desc "Load the #{component.name} image into the kind cluster"
            context.task "upload" => "#{component.name}:docker:load" do
              load_image(Docker.reference_for(project, component.name))
            end
          end
        end
      end
    end

    # The two tasks that only exist when the project has what they act on: `crds` for a
    # chart's CRD directories, and `sync` for a helmfile. A project that deploys some
    # other way defines its own task and names it in `kubernetes.deploy` instead.
    def define_deploy_tasks(context)
      crds = crd_dirs
      manifest = helmfile

      context.namespace "kind" do
        unless crds.empty?
          context.desc "Apply the CRDs to the kind cluster"
          context.task "crds" do
            crds.each do |directory|
              sh(kube_env, "kubectl", "--context=#{kube_context}", "apply",
                 "--filename=#{directory}")
            end
          end
        end

        next if manifest.nil?

        context.desc "Load every image and sync the release to the kind cluster"
        context.task "sync" => ["kind:kubeconfig", crds.empty? ? nil : "kind:crds", "kind:upload"].compact do
          sh(kube_env, "helmfile", "--environment=#{environment}",
             "--kube-context=#{kube_context}", "sync", chdir: File.dirname(manifest))
        end
      end
    end

    # The project-level tasks:
    #
    #   upload    every component's image
    #   deploy    whatever `kubernetes.deploy` names — the project's own apply task
    #   redeploy  deploy, then restart every workload in the namespace: a freshly loaded
    #             image carrying a tag the cluster has already seen is no change as far
    #             as Kubernetes is concerned, so nothing would otherwise pick it up
    #   restart   redeploy, then wait for every rollout to land, so a task chained after
    #             this one meets the new pods and not the old
    #
    # A rollout covers the namespace rather than one workload at a time: which workload
    # runs which component is the deployment's business, and a component's image can be
    # behind more than one of them.
    def define_project_tasks(context)
      context.namespace "kind" do
        context.desc "Load every component's image into the kind cluster"
        context.task "upload" => components.map { |component| "#{component.name}:kind:upload" }

        context.desc "Deploy to the kind cluster"
        context.task "deploy" => deploy_task

        context.desc "Deploy, restarting every workload so reloaded images take effect"
        context.task "redeploy" => "deploy" do
          rollout_all("restart")
        end

        context.desc "Redeploy and wait for every rollout to finish"
        context.task "restart" => "redeploy" do
          rollout_all("status", "--timeout=#{timeout}")
        end
      end
    end

    private

    # The default for both names: the project's own, reduced to a DNS label. Derived on
    # each read rather than up front, so a project whose name holds nothing usable
    # aborts on the task that needed a name instead of on `rake -T`.
    def project_label = Kind.dns_label(project.name)

    # `kind create cluster`, with the cluster config when the project has one. The
    # Kubernetes version is demanded here rather than when the settings are built, so a
    # project file that states none still lists its tasks and fails only on the one
    # task that cannot do without it.
    def create_cluster_command(config)
      if node_version.nil?
        abort "#{::Project::FILE} has no kubernetes.version stating the Kubernetes " \
              "version to create the cluster at"
      end

      command = ["kind", "create", "cluster", "--name=#{cluster}",
                 "--image=kindest/node:v#{node_version}",]
      command << "--config=#{config}" if config
      command
    end

    # Load an image from the local Docker daemon into the cluster's nodes. The nodes
    # have their own image store, so an image the host can see is not one a pod can.
    def load_image(image)
      sh("kind", "load", "docker-image", image, "--name=#{cluster}")
    end

    # The workloads running in the namespace, as the `kind.group/name` references kubectl
    # both prints and accepts.
    #
    # Asked of the cluster rather than read out of the project's manifests: what a
    # rollout has to restart is whatever is actually there. A manifest cannot say — a
    # chart's names are unresolved until a release renders them, values can rename or
    # omit a workload, and a dependency may bring workloads no file here mentions.
    def running_workloads
      listed = capture(kube_env, "kubectl", "--context=#{kube_context}",
                       "--namespace=#{namespace}", "get", WORKLOAD_KINDS.join(","),
                       "--output=name", "--ignore-not-found")
      abort "cannot list workloads in namespace #{namespace} of #{kube_context}" if listed.nil?

      listed.lines.map(&:strip).reject(&:empty?)
    end

    # Every running workload, or an abort: a rollout over nothing would report success
    # for work that never happened, and after a deploy the namespace should not be empty.
    def deployed_workloads
      workloads = running_workloads
      if workloads.empty?
        abort "no #{WORKLOAD_KINDS.join("/")} is running in namespace #{namespace}; " \
              "deploy before rolling out"
      end

      workloads
    end

    # Rolled over one at a time rather than in a single call per action: `rollout status`
    # takes one resource, so the loop is unavoidable there, and matching it for `restart`
    # keeps both reporting which workload each line belongs to.
    def rollout_all(action, *)
      deployed_workloads.each { |workload| rollout(action, *, workload: workload) }
    end

    # `kubectl rollout <action>` against the cluster's context.
    def rollout(action, *, workload:)
      sh(kube_env, "kubectl", "--context=#{kube_context}", "--namespace=#{namespace}",
         "rollout", action, workload, *)
    end

    # Build the settings from the model (the project's name and components) and the
    # project file's `kubernetes` section. Nothing is validated here: what a facet
    # needs to define its tasks is read now, and what only a task body needs — the
    # cluster and namespace names, the Kubernetes version — is checked when that task
    # reads it, so a project file with a mistake in it still lists its tasks.
    def self.create(project)
      config = project.config(:kubernetes)

      new(
        project: project,
        declared_cluster: config["cluster"],
        declared_namespace: config["namespace"],
        node_version: config["version"],
        environment: config.fetch("environment", DEFAULT_ENVIRONMENT),
        timeout: config.fetch("timeout", DEFAULT_TIMEOUT),
        deploy: config["deploy"]
      )
    end
  end

  module_function

  # Whether +name+ resolves, and resolves to a loopback address — the test for
  # whether it is another way of saying the address kind published the API server on.
  # False when it does not resolve at all, which is the ordinary case anywhere Docker
  # Desktop is not what provides the name.
  def loopback_alias?(name)
    addresses = Socket.getaddrinfo(name, nil, nil, Socket::SOCK_STREAM)
    addresses.any? { |address| IPAddr.new(address[3]).loopback? }
  rescue SocketError, IPAddr::InvalidAddressError
    false
  end

  def dns_label?(name) = name.length <= LABEL_LIMIT && name.match?(LABEL_PATTERN)

  # +name+ reduced to an RFC 1123 DNS label, since a project's name need not be one
  # (`netwrangler_vip` becomes `netwrangler-vip`). Leading hyphens go before the length is capped
  # so the cap spends its 63 characters on the name rather than on padding, and
  # trailing ones after, so a name cut at the limit cannot end on a hyphen.
  #
  # A name with nothing usable in it aborts: silently inventing one would put
  # resources somewhere the project never named.
  def dns_label(name)
    label = name.to_s.downcase.gsub(%r{[^a-z0-9-]}, "-").sub(%r{\A-+}, "")
    label = label[0, LABEL_LIMIT].to_s.sub(%r{-+\z}, "")
    abort "cannot derive an RFC 1123 DNS label from #{name.inspect}" if label.empty?

    label
  end

  # The label `kubernetes.<key>` states, or nil when it states none, for the caller to
  # default — which it does with `||`, so the default is derived only when it is
  # actually the answer.
  #
  # A stated name is checked rather than reduced: quietly renaming what someone wrote
  # would send resources somewhere other than where they asked for them.
  def configured_label(key, declared)
    return nil if declared.nil?

    unless dns_label?(declared.to_s)
      abort "kubernetes.#{key} #{declared.inspect} is not an RFC 1123 DNS label: " \
            "lowercase alphanumerics and hyphens, starting and ending alphanumeric, " \
            "at most #{LABEL_LIMIT} characters"
    end

    declared.to_s
  end
end

# Kind follows docker for the images it hands the cluster and the `<component>:docker:load`
# tasks that build them, and crystal because docker does: the components it iterates are
# the ones those two contributed, and both the order it takes them in and the load task
# each upload depends on have to be there already.
facet :kind, after: %i[crystal docker] do
  # A project with no `kubernetes` section develops against no local cluster, and gets
  # none of these tasks.
  next if project.config(:kubernetes).empty?

  project.add_facet(:kubernetes) { Kind::Settings.create(project) }
  project[:kubernetes].define_tasks(self)
end
