# frozen_string_literal: true

require_relative "../project"

# Generic conventional-commits changelog generator: a Ruby port of the myborg
# TypeScript changelog script (conventional-changelog, conventionalcommits
# preset). Regenerates the section for the current version from the commits
# since the last tag and prepends it under a single "# Changelog" title.
# Idempotent: an existing section for the version is left untouched.
# Language-agnostic.
#
# Only the facet block at the bottom contributes anything: requiring this file
# registers the facet and nothing more, so the constants and classes above are
# readable by any facet that reaches for them, whether or not it declared an
# `after:` edge to this one — the release facet reads Changelog::PATH and
# Changelog.regenerate exactly that way, with no edge between them.
module Changelog
  # The heading every changelog carries, once, above every version's section.
  TITLE = "# Changelog"

  # Where a project's changelog lives, by convention.
  PATH = "CHANGELOG.md"

  # Release tags are `v1.2.3`, optionally with a prerelease suffix. The release
  # tasks build the same pattern from their own `tag_prefix`; this is the
  # default a plain `rake changelog` assumes.
  TAG_PREFIX = "v"

  # conventionalcommits preset: the commit types that get a section, in order,
  # with their headings. Other types (docs, chore, style, refactor, …) are
  # hidden.
  SECTIONS = {
    "feat" => "Features",
    "fix" => "Bug Fixes",
    "perf" => "Performance Improvements",
    "revert" => "Reverts",
  }.freeze

  # A parsed conventional commit: type, optional scope, subject, short hash,
  # and whether it declares a breaking change. The hash member is
  # +short_hash+ rather than +hash+, which would override Data's own and
  # quietly break any use of an entry as a Hash key or in a Set.
  Commit = Data.define(:type, :scope, :subject, :short_hash, :breaking) do
    # Parse a commit subject/body into a Commit, or nil when the subject is
    # not a conventional commit.
    def self.parse(hash:, subject:, body:)
      match = subject.match(%r{\A(\w+)(?:\(([^)]+)\))?(!)?:\s*(.+)\z})
      return nil unless match

      breaking = !match[3].nil? || body.include?("BREAKING CHANGE")
      new(type: match[1], scope: match[2], subject: match[4].strip, short_hash: hash, breaking: breaking)
    end

    # A single "* …" changelog line for this commit (bold scope, linked hash
    # when the repository is on GitHub).
    def line(slug:)
      scoped = scope ? "**#{scope}:** " : ""
      ref = slug ? "([#{short_hash}](https://github.com/#{slug}/commit/#{short_hash}))" : "(#{short_hash})"
      "* #{scoped}#{subject} #{ref}"
    end
  end

  # Builds the markdown section for one version: its heading (linked to a
  # GitHub compare when the origin remote is one and a previous matching tag
  # exists), and a subsection per commit type that has entries, breaking
  # changes first.
  #
  # Everything this needs — the repo slug, the previous tag, the commits since
  # it — is read from git when #to_s is called rather than cached, so a
  # release building one of these per version it writes always sees the
  # repository as it stands at that point.
  class Section
    def initialize(version:, tag_prefix:, tag_re:, date:)
      @version = version
      @tag_prefix = tag_prefix
      @tag_re = tag_re
      @date = date
    end

    def to_s
      slug = repo_slug
      previous = previous_tag
      commits = commits_since(previous)

      parts = [header(slug: slug, previous: previous)]

      breaking = commits.select(&:breaking)
      append_subsection(parts, "⚠ BREAKING CHANGES", breaking, slug: slug) unless breaking.empty?

      SECTIONS.each do |type, heading|
        entries = commits.select { |commit| commit.type == type }
        append_subsection(parts, heading, entries, slug: slug) unless entries.empty?
      end

      parts.join("\n")
    end

    private

    def append_subsection(parts, heading, entries, slug:)
      parts.push("", "### #{heading}", "")
      entries.each { |entry| parts << entry.line(slug: slug) }
    end

    # The GitHub "owner/repo" slug from the origin remote, or nil when it is
    # not a GitHub remote (links are then omitted).
    def repo_slug
      url = capture("git", "remote", "get-url", "origin").to_s.strip
      return nil if url.empty?

      match = url.match(%r{github\.com[:/]([^/]+/[^/]+?)(?:\.git)?\z})
      match && match[1]
    end

    # The highest existing tag matching @tag_re, or nil (bounds the commit
    # range and the compare link's left side).
    def previous_tag
      tags = capture("git", "tag", "-l").to_s.split("\n").reject(&:empty?)
      tags.grep(@tag_re).max_by do |tag|
        match = @tag_re.match(tag)
        Version.new(major: match[1].to_i, minor: match[2].to_i, patch: match[3].to_i, prerelease: nil)
      end
    end

    # The conventional commits since +previous+ (or the whole history when
    # there is none), newest first, non-conventional subjects dropped.
    def commits_since(previous)
      range = previous ? "#{previous}..HEAD" : "HEAD"
      log = capture("git", "log", range, "--no-merges", "--pretty=format:%h%x1f%s%x1f%b%x1e").to_s
      log.split("\x1e").map(&:strip).reject(&:empty?).filter_map do |record|
        short, subject, body = record.split("\x1f")
        Commit.parse(hash: short.to_s.strip, subject: subject.to_s.strip, body: body.to_s.strip)
      end
    end

    def header(slug:, previous:)
      tag = "#{@tag_prefix}#{@version}"
      if slug && previous
        "## [#{@version}](https://github.com/#{slug}/compare/#{previous}...#{tag}) (#{@date})"
      else
        "## #{@version} (#{@date})"
      end
    end
  end

  module_function

  # The tag pattern for +prefix+, which is what bounds the commit range and
  # the compare link.
  def tag_pattern(prefix: TAG_PREFIX)
    %r{\A#{Regexp.escape(prefix)}(\d+)\.(\d+)\.(\d+)(?:-[\w.-]+)?\z}
  end

  # The changelog body with the leading title (and blank lines) removed, so a
  # new section can be prepended above it.
  def strip_title(content)
    lines = content.split("\n")
    index = 0
    if lines[0].to_s.strip == TITLE
      index = 1
      index += 1 while index < lines.length && lines[index].to_s.strip.empty?
    end
    lines[index..].to_a.join("\n").strip
  end

  # Whether +body+ already has a section for +version+ (idempotency guard).
  def version?(body:, version:)
    %r{^##\s+\[?#{Regexp.escape(version.to_s)}[\]\s(]}.match?(body)
  end

  # Whether the changelog at +path+ already carries a section for +version+.
  def covers?(version:, path: PATH)
    return false unless File.exist?(path)

    version?(body: strip_title(File.read(path)), version: version)
  end

  # Prepend the section for +version+ to the changelog at +path+ (created if
  # missing), under a single title. A no-op if the version already has a
  # section.
  def regenerate(version:, tag_prefix:, tag_re:, date:, path: PATH)
    existing = File.exist?(path) ? File.read(path) : ""
    body = strip_title(existing)
    return if version?(body: body, version: version)

    section = Section.new(version: version, tag_prefix: tag_prefix, tag_re: tag_re, date: date).to_s
    combined = body.empty? ? section : "#{section}\n\n#{body}"
    File.write(path, "#{TITLE}\n\n#{combined.strip}\n")
  end

  # The version to write a section for: +project+'s, less any prerelease
  # suffix, so a mainline carrying `1.2.0-dev` documents what it is working
  # toward rather than leaving a `-dev` heading behind for the release to
  # duplicate.
  def version(project) = project.version.to_s.sub(%r{-.*\z}, "")
end

# Changelog names no `after:`: it reads only the project's own version and
# git, neither of which is another facet's to contribute.
facet :changelog do
  desc "Update #{Changelog::PATH} with the section for the manifest's version"
  task "changelog" do
    version = Changelog.version(project)
    abort "the project manifest carries no version" if version.empty?

    if Changelog.covers?(version: version)
      puts "#{Changelog::PATH} already has a section for #{version}"
    else
      Changelog.regenerate(version: version, tag_prefix: Changelog::TAG_PREFIX,
                           tag_re: Changelog.tag_pattern, date: Time.now.strftime("%Y-%m-%d"))
      puts "updated #{Changelog::PATH} for #{version}"
    end
  end
end
