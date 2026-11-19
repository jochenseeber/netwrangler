# frozen_string_literal: true

require_relative "../project"

# Generic branch-then-tag release task, usable by any project regardless of
# language. Where the version is stored is the project's business — read through
# `version`, written through `write_versions`, staged as the files `version_files`
# names — so this file knows nothing about shard.yml/Chart.yaml/package.json/etc.
#
# Strategy: the mainline branch carries the next minor development version (e.g.
# 0.2.0-dev). Releasing from mainline creates a release branch <prefix><major>.
# <minor><suffix>, tags the stripped version there, starts the branch on the
# next patch dev version, and bumps the mainline to the next minor dev version.
# Patch releases are cut the same way from the release branch.
#
# Only the facet block at the bottom contributes anything: requiring this file
# registers the facet and nothing more, so the constants and Plan above are
# readable by any facet that reaches for them, whether or not it declared an
# `after:` edge to this one.
module Release
  # Extends Rake::DSL so the module functions below — which run the release's git
  # commands — can call sh directly.
  extend Rake::DSL

  # The branch a release is cut from, and the shapes of the tag and release-branch
  # names. Conventions rather than settings: a project that needs different ones
  # passes them to define_task itself.
  MAINLINE = "main"
  TAG_PREFIX = "v"
  BRANCH_SUFFIX = ".x"

  # The computed outcome of a release: the version to tag, the branch it lands on
  # and that branch's next dev version, the branch released from and its next dev
  # version (nil when releasing in place on a release branch), the tag, and an
  # informational bump label (nil when not releasing from the mainline).
  Plan = Data.define(
    :release_version, :release_branch, :release_branch_next_dev,
    :from_branch, :from_branch_next_dev, :tag, :bump
  )

  module_function

  # Read git output, aborting on failure (capture returns nil then).
  def git_capture(*args)
    output = capture("git", *args)
    abort "git #{args.join(" ")} failed" if output.nil?
    output
  end

  def assert_clean_workspace
    abort "Working tree is not clean; commit or stash changes before releasing." \
      unless git_capture("status", "--porcelain").strip.empty?
  end

  # The highest-versioned release branch or tag, or nil. Branches contribute
  # (major, minor) only (patch -1) so a tag ranks above its own branch.
  def latest_release_ref(branch_re:, tag_re:)
    branches = git_capture("for-each-ref", "--format=%(refname:short)", "refs/heads/").split("\n").reject(&:empty?)
    tags = git_capture("tag", "-l").split("\n").reject(&:empty?)
    latest = nil
    consider = lambda do |version, ref|
      latest = { version: version, ref: ref } if latest.nil? || (version <=> latest[:version]).positive?
    end
    branches.each do |branch|
      (match = branch_re.match(branch)) &&
        consider.call(Version.new(major: match[1].to_i, minor: match[2].to_i, patch: -1, prerelease: nil), branch)
    end
    tags.each do |tag|
      (match = tag_re.match(tag)) &&
        consider.call(Version.new(major: match[1].to_i, minor: match[2].to_i, patch: match[3].to_i, prerelease: nil), tag)
    end
    latest
  end

  # Informational bump label; also guards against releasing a version that is not
  # ahead of the latest existing release.
  def detect_bump(current:, branch_re:, tag_re:)
    latest = latest_release_ref(branch_re: branch_re, tag_re: tag_re)
    return "no prior release branches or tags found" if latest.nil?

    unless (current <=> latest[:version]).positive?
      abort "version #{current} is not ahead of latest release #{latest[:ref]}; " \
            "bump the version before releasing."
    end

    if current.major > latest[:version].major
      "#{current} advances major from #{latest[:ref]}"
    else
      "#{current} stays on major #{current.major} (latest release: #{latest[:ref]})"
    end
  end

  def confirm?(question:)
    print "#{question} [y/N] "
    %w[y yes].include?($stdin.gets.to_s.strip.downcase)
  end

  # Compute the Plan for cutting a release from +branch+ at +current+ version, or
  # abort if the branch/version state does not permit a release.
  def plan_release(current:, branch:, mainline:, branch_re:, tag_re:, tag_prefix:, branch_suffix:)
    if branch_re.match?(branch)
      unless current.prerelease == "dev"
        abort "Release branch version #{current} has no -dev suffix; " \
              "bump the branch to the next patch dev version before cutting another release."
      end
      release_version = current.with(prerelease: nil)
      Plan.new(
        release_version: release_version, release_branch: branch,
        release_branch_next_dev: current.with(patch: current.patch + 1, prerelease: "dev"),
        from_branch: branch, from_branch_next_dev: nil,
        tag: "#{tag_prefix}#{release_version}", bump: nil
      )
    elsif branch == mainline
      abort "Current version #{current} has no -dev suffix; nothing to release from #{mainline}." \
        unless current.prerelease == "dev"
      release_version = current.with(prerelease: nil)
      Plan.new(
        release_version: release_version,
        release_branch: "#{tag_prefix}#{release_version.major}.#{release_version.minor}#{branch_suffix}",
        release_branch_next_dev: release_version.with(patch: release_version.patch + 1, prerelease: "dev"),
        from_branch: branch,
        from_branch_next_dev: Version.new(major: current.major, minor: current.minor + 1, patch: 0, prerelease: "dev"),
        tag: "#{tag_prefix}#{release_version}",
        bump: detect_bump(current: current, branch_re: branch_re, tag_re: tag_re)
      )
    else
      abort "Must be on '#{mainline}' or a release branch (got '#{branch}')."
    end
  end

  # Execute +plan+: create the release branch if needed, write versions, regenerate
  # the changelog on the release commit, tag, and bump dev versions. Nothing is
  # pushed.
  #
  # The version is written through +project.write_versions+ rather than
  # +write_version+: the commits stage every file +version_files+ names, and the
  # manifests among those are each facet's to write. That is also why this cannot
  # be a dependency on `version:update` — the write happens twice inside this one
  # procedure, and a prerequisite runs once, before the body.
  def perform_release(plan:, project:, changelog_path:, tag_prefix:, tag_re:)
    release_date = Time.now.strftime("%Y-%m-%d")

    stage_files = lambda do
      project.version_files.each { |file| sh "git", "add", file }
      sh "git", "add", changelog_path if changelog_path && File.exist?(changelog_path)
    end

    # The release commit records the release version and regenerates the changelog
    # section for it from the commits since the last tag.
    release_commit = lambda do |version|
      project.write_versions(version.to_s)
      if changelog_path
        Changelog.regenerate(version: version, tag_prefix: tag_prefix, tag_re: tag_re,
                             date: release_date, path: changelog_path)
      end
      stage_files.call
      sh "git", "commit", "-m", "chore: release #{version}"
    end

    dev_commit = lambda do |version|
      project.write_versions(version.to_s)
      stage_files.call
      sh "git", "commit", "-m", "chore: start #{version} development"
    end

    if plan.release_branch == plan.from_branch
      release_commit.call(plan.release_version)
      sh "git", "tag", plan.tag
      dev_commit.call(plan.release_branch_next_dev)
    else
      sh "git", "checkout", "-b", plan.release_branch
      release_commit.call(plan.release_version)
      sh "git", "tag", plan.tag
      dev_commit.call(plan.release_branch_next_dev)
      sh "git", "checkout", plan.from_branch
      # Bring the regenerated changelog from the release branch onto the mainline
      # so its history is visible there too.
      sh "git", "checkout", plan.release_branch, "--", changelog_path if changelog_path
      dev_commit.call(plan.from_branch_next_dev)
    end
  end

  # Create the `release` task. The version is +project+'s, read and written through
  # it, and the files a commit stages are the ones it names. +mainline+ is the
  # development branch; +tag_prefix+/+branch_suffix+ shape the tag and
  # release-branch names; +changelog_path+ is regenerated on each release commit
  # (nil to disable).
  def define_task(context, project:, name: "release", mainline: MAINLINE,
                  tag_prefix: TAG_PREFIX, branch_suffix: BRANCH_SUFFIX,
                  changelog_path: Changelog::PATH)
    branch_re = %r{\A#{Regexp.escape(tag_prefix)}(\d+)\.(\d+)#{Regexp.escape(branch_suffix)}\z}
    tag_re = %r{\A#{Regexp.escape(tag_prefix)}(\d+)\.(\d+)\.(\d+)(?:-[\w.-]+)?\z}

    context.desc "Cut a release: create the release branch (from #{mainline}), tag it, and bump dev versions"
    context.task name, [:yes] do |_task, args|
      assert_clean_workspace
      current = Version.parse(project.version)
      branch = git_capture("rev-parse", "--abbrev-ref", "HEAD").strip
      abort "Cannot release from detached HEAD." if branch == "HEAD"

      plan = plan_release(current: current, branch: branch, mainline: mainline, branch_re: branch_re,
                          tag_re: tag_re, tag_prefix: tag_prefix, branch_suffix: branch_suffix)

      report(plan)

      abort "Aborted." unless args[:yes] == "yes" || confirm?(question: "Proceed?")

      perform_release(plan: plan, project: project, changelog_path: changelog_path,
                      tag_prefix: tag_prefix, tag_re: tag_re)

      report_next_steps(plan)
    end
  end

  # What the release will do, printed before the confirmation prompt.
  def report(plan)
    puts "Detected bump: #{plan.bump}" if plan.bump
    puts
    puts "Release version         : #{plan.release_version}  (on #{plan.release_branch})"
    puts "Release branch next dev : #{plan.release_branch_next_dev}  (on #{plan.release_branch})"
    puts "Main next dev           : #{plan.from_branch_next_dev}  (on #{plan.from_branch})" if plan.from_branch_next_dev
    puts "Tag to create           : #{plan.tag}"
    puts
  end

  # Nothing is pushed, so the pushes the release leaves to be done are spelled out.
  def report_next_steps(plan)
    puts
    puts "Done. Nothing was pushed. Next steps:"
    puts "  git push origin #{plan.release_branch} #{plan.tag}"
    puts "  git push origin #{plan.from_branch}" if plan.from_branch_next_dev
  end
end

# Release names no `after:`: it reads only the project's own version, the files it
# names, and the writers the manifest-owning facets registered — none of which is
# another facet's to contribute at a point this body could observe.
facet :release do
  Release.define_task(self, project: project)
end
