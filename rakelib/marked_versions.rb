# frozen_string_literal: true

require "rubygems"

# The project version in the Markdown files, between a `<!-- release-version -->`
# and a `<!-- /release-version -->` comment, each on a line of its own. The
# marked parts name the latest release: `rake release` writes the released
# version there, and a development version it starts afterwards writes the
# release before it, which the tag `v<version>` names by then.
class MarkedVersions
  REGION = %r{^(<!-- release-version -->\n)(.*?)(^<!-- /release-version -->)$}m
  SEMANTIC_VERSION = %r{\b\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?\b}
  RELEASE_TAG = %r{\Av(\d+\.\d+\.\d+)\z}

  # The tracked Markdown files with a marked region. A symbolic link is left out:
  # writing its target is the target's business.
  #
  # @return [Array<String>]
  def self.files
    %x(git ls-files -z -- '*.md').split("\0").select do |file|
      !File.symlink?(file) && File.read(file).match?(REGION)
    end
  end

  # The released versions, from the `v<major>.<minor>.<patch>` tags
  #
  # @return [Array<Gem::Version>]
  def self.releases
    %x(git tag --list 'v*').lines.filter_map do |tag|
      match = tag.strip.match(RELEASE_TAG)
      Gem::Version.new(match[1]) unless match.nil?
    end
  end

  attr_reader :files

  # @param files [Array<String>] the Markdown files with a marked region
  # @param releases [Array<Gem::Version>] the released versions
  def initialize(files: self.class.files, releases: self.class.releases)
    @files = files
    @releases = releases
  end

  # Write the latest release up to +version+ into every marked region: +version+
  # itself when it is a release, otherwise the highest release below it. Before
  # the first release nothing is written.
  #
  # @param version [String]
  def write(version)
    release = latest_release(Gem::Version.new(version))
    return if release.nil?

    @files.each do |file|
      updated = File.read(file).gsub(REGION) do
        start, body, finish = Regexp.last_match.captures
        "#{start}#{body.gsub(SEMANTIC_VERSION, release.to_s)}#{finish}"
      end
      File.write(file, updated)
    end
  end

  private

  def latest_release(version)
    return version unless version.prerelease?

    @releases.select { |release| release < version }.max
  end
end
