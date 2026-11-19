# frozen_string_literal: true

require_relative "../project"

# Generic Homebrew formula updater, usable by any project. Sets the formula's
# version and the SHA256 of each release asset; an asset's basename must match
# the filename in a formula `url` line so its checksum lands in the right
# on_os/on_arch block.
#
# Only the facet block at the bottom contributes anything, and only for a
# project that ships a formula: whether `homebrew:formula:update` exists at
# all is decided once, from however many formulae Homebrew.formulae finds when
# the facet body runs. Everything above the facet block is inert until
# required, so any facet may read Homebrew::Formula without an `after:` edge
# to this one.
module Homebrew
  # Where a project keeps its formula(e), by convention.
  FORMULA_GLOB = "homebrew/*.rb"

  # One Homebrew formula this project ships, and what this facet does with it:
  # write the released version and the checksum of each release asset into it,
  # matching an asset by its basename against the formula's own `url` line so
  # the checksum lands in the matching on_os/on_arch block.
  Formula = Data.define(:path) do
    def write(version:, asset_paths:)
      abort "formula not found: #{path}" unless File.exist?(path)

      contents = with_version(File.read(path), version: version)
      contents = asset_paths.reduce(contents) { |acc, asset_path| with_checksum(acc, asset_path: asset_path) }

      File.write(path, contents)
      puts "Updated #{path} to #{version} for #{asset_paths.size} asset(s)"
    end

    private

    def with_version(contents, version:)
      updated = contents.sub(%r{^(\s*)version\s+"[^"]*"$}, "\\1version \"#{version}\"")
      abort "could not find version line in #{path}" if updated == contents

      updated
    end

    def with_checksum(contents, asset_path:)
      asset = File.basename(asset_path)
      digest = Digest::SHA256.file(asset_path).hexdigest
      pattern = %r{(url "[^"]*#{Regexp.escape(asset)}"\s*\n\s*sha256 )"[^"]*"}
      updated = contents.sub(pattern) { "#{Regexp.last_match(1)}\"#{digest}\"" }
      abort "could not find url/sha256 for asset #{asset} in #{path}" if updated == contents

      updated
    end
  end

  module_function

  # Every formula this project ships, in Dir.glob's stable order.
  def formulae = Dir.glob(FORMULA_GLOB).map { |path| Formula.new(path: path) }

  # The released version to write, or an abort. A manifest still carrying the
  # development suffix cannot be it: no release assets exist for a version
  # that was never released, so the task belongs on the release branch, where
  # the manifest holds the released version.
  #
  # Checked when the task runs rather than when the facet loads, so a mainline
  # manifest (which always carries a -dev suffix) still lists its tasks and
  # fails only when this one actually runs.
  def release_version(project)
    version = project.version.to_s
    abort "the project manifest carries no version" if version.empty?
    if version.end_with?("-dev")
      abort "#{version} is a development version, so no release assets can exist for it; " \
            "run this from the release branch, where the manifest holds the released version"
    end

    version
  end

  # Define `update` on +context+: write every formula's version and checksums
  # from the project's release assets, which only the language facet that
  # built them can name — read through its crystal slot, tolerating its
  # absence.
  def define_formula_update_task(context, project:, formulae:)
    context.desc "Update the Homebrew formula version/checksums from the project's release assets"
    context.task "update" do
      version = release_version(project)
      assets = project[:crystal]&.release_assets || []
      abort "no release assets to checksum; run `rake dist:package` first" if assets.empty?

      formulae.each { |formula| formula.write(version: version, asset_paths: assets) }
    end
  end
end

# Homebrew names no `after:`: it reads only the project's own version and,
# through the crystal facet's slot, the release assets it built — tolerating
# the absence of either — and defines nothing at all for a project with no
# formula to update.
facet :homebrew do
  formulae = Homebrew.formulae
  next if formulae.empty?

  namespace "homebrew" do
    namespace "formula" do
      Homebrew.define_formula_update_task(self, project: project, formulae: formulae)
    end
  end
end
