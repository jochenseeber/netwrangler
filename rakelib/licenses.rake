# frozen_string_literal: true

require "fileutils"
require "open-uri"
require "open3"
require "tmpdir"

# Fetches the license files of the third-party software the images bundle into
# docs/licenses/, one directory per component, which the Dockerfiles copy into
# /usr/share/licenses. The image builds download nothing for it; run
# `rake licenses:update` after changing a bundled version.
module Licenses
  DIRECTORY = "docs/licenses"
  DOCKERFILE = "Dockerfile.agent"

  # The names of a Go module's license, copying and notice files
  LICENSE_FILE = %r{\A(LICEN[CS]E|COPYING|NOTICE|PATENTS)}i

  # One component: its license files, as {URL => name in docs/licenses/<name>/}.
  # Each URL names a file in the project's repository at the release's tag.
  Component = Data.define(:name, :files)

  # The URL of +path+ in a GitHub repository at +ref+
  def self.github(repository, ref, path)
    "https://raw.githubusercontent.com/#{repository}/#{ref}/#{path}"
  end

  # Software from the Alpine packages and base images, whose exact versions move
  # with those images. Their license texts do not change between these
  # releases and the versions the images contain.
  UPSTREAM = [
    # BusyBox's own git server is gone, and its GitHub mirror stops before 1.37.0
    # with the same LICENSE
    Component.new(name: "busybox",
                  files: { github("mirror/busybox", "371fe9f71d445d18be28c82a2a6d82115c8af19d", "LICENSE") => "LICENSE" }),
    Component.new(name: "uclibc-ng",
                  files: { github("wbx-github/uclibc-ng", "v1.0.50", "COPYING.LIB") => "COPYING.LIB" }),
    Component.new(name: "musl",
                  files: { "https://git.musl-libc.org/cgit/musl/plain/COPYRIGHT?h=v1.2.5" => "COPYRIGHT" }),
    Component.new(name: "pcre2",
                  files: { github("PCRE2Project/pcre2", "pcre2-10.48", "LICENCE.md") => "LICENCE.md" }),
    # The Boehm GC states its license at the top of README.QUICK
    Component.new(name: "bdwgc",
                  files: { github("bdwgc/bdwgc", "v8.2.12", "README.QUICK") => "README.QUICK" }),
  ].freeze

  class << self
    def update
      Dir.mktmpdir("licenses") do |staging|
        components.each { |component| fetch(component, into: staging) }
        fetch_go_modules(into: File.join(staging, "shell-operator"))

        FileUtils.rm_rf(DIRECTORY)
        FileUtils.cp_r(staging, DIRECTORY)
      end
      puts "Updated #{DIRECTORY}/"
    end

    # The components the agent image builds from source, at the versions its
    # Dockerfile names, then those from Alpine packages and base images.
    def components
      args = dockerfile_args
      [
        Component.new(name: "crystal",
                      files: { github("crystal-lang/crystal", args.fetch("CRYSTAL_VERSION"), "LICENSE") => "LICENSE" }),
        Component.new(name: "shell-operator",
                      files: { github("flant/shell-operator", args.fetch("SHELL_OPERATOR_VERSION"), "LICENSE") => "LICENSE" }),
      ] + UPSTREAM
    end

    def dockerfile_args
      File.read(DOCKERFILE).scan(%r{^ARG (\w+)="?([^"\n]*)"?$}).to_h
    end

    private

    def fetch(component, into:)
      puts "Fetching the license of #{component.name}"
      target = File.join(into, component.name)
      FileUtils.mkdir_p(target)
      component.files.each do |url, name|
        File.binwrite(File.join(target, name), URI.parse(url).open(&:read))
      end
    end

    # The license files of Go and of every Go module the shell-operator binary
    # links, listed by `go list` in a Go container whose module cache is a host
    # directory. A module without a license file fails the update.
    def fetch_go_modules(into:)
      args = dockerfile_args
      puts "Fetching the licenses of shell-operator's Go modules"
      Dir.mktmpdir("go-modules") do |cache|
        listing = capture("docker", "run", "--rm", "--volume", "#{cache}:/go/pkg/mod",
                          "--env", "CGO_ENABLED=0", "--env", "GOOS=linux",
                          "golang:#{args.fetch("GO_VERSION")}-alpine", "sh", "-c", <<~SH)
                            set -eu
                            apk add --no-cache --quiet git
                            git clone --quiet --depth=1 --branch=#{args.fetch("SHELL_OPERATOR_VERSION")} https://github.com/flant/shell-operator.git /src
                            cd /src
                            cp "$(go env GOROOT)/LICENSE" /go/pkg/mod/GO-LICENSE
                            go list -deps -f '{{with .Module}}{{if not .Main}}{{.Path}} {{.Dir}}{{end}}{{end}}' ./cmd/shell-operator | sort -u
                          SH
        FileUtils.mkdir_p(File.join(into, "go"))
        FileUtils.cp(File.join(cache, "GO-LICENSE"), File.join(into, "go", "LICENSE"))
        copy_module_licenses(listing, cache: cache, into: File.join(into, "modules"))
      ensure
        FileUtils.chmod_R("u+w", cache)
      end
    end

    def copy_module_licenses(listing, cache:, into:)
      missing = listing.lines.filter_map do |line|
        path, dir = line.split
        host_dir = dir.sub(%r{\A/go/pkg/mod}, cache)
        files = Dir.children(host_dir).select { |name| name.match?(LICENSE_FILE) && File.file?(File.join(host_dir, name)) }
        next path if files.empty?

        FileUtils.mkdir_p(File.join(into, path))
        # The module cache is read-only; the copies are not
        files.each { |name| FileUtils.install(File.join(host_dir, name), File.join(into, path, name), mode: 0o644) }
        nil
      end
      raise "Go modules without a license file: #{missing.join(", ")}" unless missing.empty?
    end

    def capture(*command)
      stdout, stderr, status = Open3.capture3(*command)
      raise "#{command.first} failed: #{stderr.strip}" unless status.success?

      stdout
    end
  end
end

namespace :licenses do
  desc "Fetch the license files of the software the images bundle into docs/licenses/"
  task :update do
    Licenses.update
  end
end
