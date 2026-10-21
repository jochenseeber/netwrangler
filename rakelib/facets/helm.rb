# frozen_string_literal: true

require_relative "../project"

# Generic Helm chart tasks, usable by any project that ships a chart: package it,
# push it to an OCI registry, and publish the Artifact Hub repository metadata
# beside it. A chart's name and its own version are read from its Chart.yaml, so
# a project never restates them there. What this facet writes is the version:
# a chart carries it twice, as its own `version` and as the `appVersion` of the
# application it deploys, and both are written from the project file so the
# chart and what it deploys are released as one.
#
# Only the facet block at the bottom contributes anything: requiring this file
# registers the facet and nothing more, so the constants and the Chart class
# above are readable by any facet that reaches for them, whether or not it
# declared an `after:` edge to this one.
module Helm
  # Artifact Hub identifies a repository-metadata artifact by these media types
  # specifically — a plain OCI push with the defaults is ignored — and expects it
  # at the `artifacthub.io` tag of the chart's own repository.
  METADATA_FILE = "artifacthub-repo.yml"
  METADATA_TAG = "artifacthub.io"
  METADATA_CONFIG_TYPE = "application/vnd.cncf.artifacthub.config.v1+yaml"
  METADATA_LAYER_TYPE = "application/vnd.cncf.artifacthub.repository-metadata.layer.v1.yaml"

  # Where a chart lives, by convention. Deliberately bounded rather than a `**`
  # sweep: a chart vendors its dependencies under its own `charts/`, and those
  # are not charts this project publishes.
  CHART_GLOBS = ["deploy/charts/*/Chart.yaml"].freeze

  DEFAULT_REGISTRY = "registry-1.docker.io"
  DEFAULT_DIST_DIR = "dist"

  # One chart this project publishes, and everything this facet does with it:
  # package, push, publish Artifact Hub metadata, and keep both the version it
  # is published under and the `appVersion` it declares in step with the
  # project's.
  #
  # Includes Rake::DSL so the task action blocks below — which run with a Chart
  # as self — can call sh/mkdir_p directly.
  Chart = Data.define(:dir, :registry, :dist_dir, :read_repository) do
    include Rake::DSL

    def chart_path = File.join(dir, "Chart.yaml")

    # Read fresh on every call rather than cached, so a task that writes the
    # versions mid-run (version:update:helm ahead of a package built in the same
    # invocation) is seen by whatever reads them after — package_path among them,
    # which names the file after the version just written.
    def manifest = YAML.load_file(chart_path)
    def name = manifest.fetch("name")
    def package_version = manifest.fetch("version")
    def app_version = manifest["appVersion"].to_s

    def package_path = File.join(dist_dir, "#{name}-#{package_version}.tgz")
    def metadata_file = File.join(dir, METADATA_FILE)
    def metadata? = File.exist?(metadata_file)

    # Write +version+ into both the chart's own `version` and its `appVersion`,
    # which this project keeps in step: the chart and the application it deploys
    # are released together, so one version describes both.
    #
    # Helm validates only the first of the two. `version` must be a string and
    # valid SemVer — an unquoted `0.1` is read as a float and rejected — while
    # `appVersion` is a free-form label it never checks. A prerelease version is
    # valid in both, at the cost of the chart being a prerelease itself: `helm
    # search` hides it without `--devel` and a dependency constraint will not
    # match it until a release version is cut.
    def write_version(version)
      write_field("version", version)
      write_field("appVersion", version)
    end

    # Write +version+ into +field+, preserving whatever quoting that line already
    # used. Edited line-by-line rather than round-tripped through YAML, which
    # would drop every comment the file carries. Anchored to the start of a line,
    # so writing `version` cannot match `appVersion`.
    def write_field(field, version)
      raw = File.read(chart_path)
      abort "#{chart_path} has no #{field} field" unless raw.match?(%r{^#{field}:.*$})

      quote = raw[%r{^#{field}:\s*(["']?)}, 1]
      File.write(chart_path, raw.sub(%r{^#{field}:.*$}, "#{field}: #{quote}#{version}#{quote}"))
    end

    # Push the Artifact Hub repository metadata to the chart's OCI repository.
    #
    # `--disable-path-validation` is required because oras rejects an absolute
    # file path by default, and +metadata_file+ is one whenever the chart
    # directory is.
    def push_metadata
      sh("oras", "push", "#{registry}/#{read_repository.call}/#{name}:#{METADATA_TAG}",
         "--disable-path-validation",
         "--config", "/dev/null:#{METADATA_CONFIG_TYPE}",
         "#{metadata_file}:#{METADATA_LAYER_TYPE}")
    end

    # `package`, `push` and — only when the chart carries an
    # artifacthub-repo.yml, since there is nothing to publish otherwise —
    # `push:metadata`, in whatever namespace +context+ is currently in.
    #
    # +read_repository+ is called when a task runs, so a repository namespace
    # that is configuration rather than a literal is resolved at the last
    # moment.
    def define_tasks(context)
      context.desc "Package the #{name} chart into #{dist_dir}/"
      context.task "package" do
        mkdir_p dist_dir
        sh("helm", "package", dir, "--destination=#{dist_dir}")
      end

      context.desc "Push the #{name} chart to #{registry}"
      context.task "push" => "package" do
        sh("helm", "push", package_path, "oci://#{registry}/#{read_repository.call}")
      end

      return unless metadata?

      context.desc "Push the #{name} Artifact Hub repository metadata to #{registry}"
      context.task "push:metadata" do
        push_metadata
      end
    end
  end

  module_function

  # The chart directories this project publishes. Dir.glob already returns
  # matches in a stable order, so the task list does not shuffle between runs.
  def chart_dirs = Dir.glob(CHART_GLOBS).map { |manifest| File.dirname(manifest) }

  # Every chart this project publishes, sharing the repository namespace its
  # images publish under: read from the docker facet's own slot when one is
  # installed, falling back to the project file's `docker` section directly so
  # this facet still works in a project with no docker facet at all.
  def charts(project)
    repository = -> { project[:docker]&.repository || project.config(:docker)["repository"] }

    chart_dirs.map do |dir|
      Chart.new(dir: dir, registry: DEFAULT_REGISTRY, dist_dir: DEFAULT_DIST_DIR, read_repository: repository)
    end
  end

  # Project-level `helm:<action>`, each fanning out to the same task on every
  # chart that defines it — `push:metadata` only reaches the charts that have
  # metadata.
  def define_aggregate_tasks(context, charts:)
    {
      "package" => "Package every Helm chart",
      "push" => "Push every Helm chart",
      "push:metadata" => "Push every chart's Artifact Hub repository metadata",
    }.each do |action, summary|
      defined_for = charts.select { |chart| Rake::Task.task_defined?("helm:#{chart.name}:#{action}") }
      next if defined_for.empty?

      context.desc summary
      context.task action => defined_for.map { |chart| "helm:#{chart.name}:#{action}" }
    end
  end

  # This facet's share of the project-wide version tasks: a chart carries the
  # project version twice — as its own `version` and as the `appVersion` of what
  # it deploys — and this project keeps the two in step, so both are written from
  # the project file and reported when either drifts. A project's charts are
  # typically one, so both tasks loop over +charts+ rather than naming one per
  # chart — `rake -T` gains exactly these two lines, not one more per chart.
  #
  # Each joins its umbrella in rakelib/project.rake as a prerequisite, the same
  # way `version:update:crystal` and `version:lint:crystal` do.
  def define_version_tasks(context, project:, charts:)
    context.task "version:update" => "version:update:helm"
    context.task "version:lint" => "version:lint:helm"

    context.namespace "version" do
      context.namespace "update" do
        context.desc "Write the project version into every chart's version and appVersion"
        context.task "helm" do
          charts.each { |chart| chart.write_version(project.version) }
        end
      end

      context.namespace "lint" do
        context.desc "Report any chart's version or appVersion disagreeing with the project version"
        context.task "helm" do
          charts.each do |chart|
            report_version_drift(manifest: "#{chart.chart_path} (version)",
                                 found: chart.package_version.to_s)
            report_version_drift(manifest: "#{chart.chart_path} (appVersion)",
                                 found: chart.app_version)
          end
        end
      end
    end
  end
end

# Helm follows docker for the repository namespace its charts publish under,
# read from the docker facet's own object when one is installed.
facet :helm, after: %i[docker] do
  charts = Helm.charts(project)
  charts.each { |chart| project.add_version_file(chart.chart_path) }
  # The same write `version:update:helm` performs, offered to whoever writes the
  # project version out in one go — `release` does, twice inside one procedure.
  project.add_version_writer { |version| charts.each { |chart| chart.write_version(version) } }

  Helm.define_version_tasks(self, project: project, charts: charts)

  next if charts.empty?

  namespace "helm" do
    charts.each do |chart|
      namespace chart.name do
        chart.define_tasks(self)
      end
    end

    Helm.define_aggregate_tasks(self, charts: charts)
  end
end
