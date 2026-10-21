# frozen_string_literal: true

require "fileutils"
require "open-uri"
require "open3"
require "tmpdir"

# Fetches the license files of the third-party software the images bundle into
# licenses/, one directory per component, which the Dockerfiles copy into
# /usr/share/licenses. The image builds download nothing for it; run
# `rake licenses:update` after changing a bundled version.
module Licenses
  DIRECTORY = "licenses"
  DOCKERFILE = "Dockerfile.agent"

  # The names of a Go module's license, copying and notice files
  LICENSE_FILE = %r{\A(LICEN[CS]E|COPYING|NOTICE|PATENTS)}i

  # One component: the release archive it comes from and the files to take,
  # as {path in the archive => name in licenses/<name>/}. A file maps to nil
  # when only a part of it is the license, which +extract+ picks out.
  Component = Data.define(:name, :url, :files, :extract) do
    def initialize(name:, url:, files:, extract: nil)
      super
    end
  end

  # Software from the Alpine packages and base images, whose exact versions move
  # with those images. Their license texts do not change between these
  # releases and the versions the images contain.
  UPSTREAM = [
    Component.new(name: "busybox", url: "https://busybox.net/downloads/busybox-1.37.0.tar.bz2",
                  files: { "LICENSE" => "LICENSE" }),
    Component.new(name: "uclibc-ng", url: "https://downloads.uclibc-ng.org/releases/1.0.50/uClibc-ng-1.0.50.tar.xz",
                  files: { "COPYING.LIB" => "COPYING.LIB" }),
    Component.new(name: "musl", url: "https://musl.libc.org/releases/musl-1.2.5.tar.gz",
                  files: { "COPYRIGHT" => "COPYRIGHT" }),
    Component.new(name: "libmnl", url: "https://netfilter.org/projects/libmnl/files/libmnl-1.0.5.tar.bz2",
                  files: { "COPYING" => "COPYING" }),
    Component.new(name: "jansson", url: "https://github.com/akheron/jansson/releases/download/v2.14.1/jansson-2.14.1.tar.gz",
                  files: { "LICENSE" => "LICENSE" }),
    Component.new(name: "pcre2", url: "https://github.com/PCRE2Project/pcre2/releases/download/pcre2-10.48/pcre2-10.48.tar.bz2",
                  files: { "LICENCE.md" => "LICENCE.md" }),
    # The Boehm GC states its license at the top of README.QUICK
    Component.new(name: "bdwgc", url: "https://github.com/ivmai/bdwgc/releases/download/v8.2.12/gc-8.2.12.tar.gz",
                  files: { "README.QUICK" => "README.QUICK" }),
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
    # Dockerfile names, then those from Alpine packages and base images. The
    # nft and libnftnl releases share one license file each, so the newest
    # stands for all.
    def components
      args = dockerfile_args
      nftables, libnftnl = args.fetch("NFTABLES_BUILDS").split.last.split(":")
      iputils = args.fetch("IPUTILS_VERSION")
      [
        Component.new(name: "nftables", url: "https://netfilter.org/projects/nftables/files/nftables-#{nftables}.tar.xz",
                      files: { "COPYING" => "COPYING" }),
        Component.new(name: "mini-gmp", url: "https://netfilter.org/projects/nftables/files/nftables-#{nftables}.tar.xz",
                      files: { "src/mini-gmp.c" => "NOTICE" }, extract: ->(text) { "#{text[%r{\A/\*.*?\*/}m]}\n" }),
        Component.new(name: "libnftnl", url: "https://netfilter.org/projects/libnftnl/files/libnftnl-#{libnftnl}.tar.xz",
                      files: { "COPYING" => "COPYING" }),
        Component.new(name: "iproute2",
                      url: "https://mirrors.edge.kernel.org/pub/linux/utils/net/iproute2/iproute2-#{args.fetch("IPROUTE2_VERSION")}.tar.xz",
                      files: { "COPYING" => "COPYING" }),
        Component.new(name: "wireguard-tools",
                      url: "https://git.zx2c4.com/wireguard-tools/snapshot/wireguard-tools-#{args.fetch("WIREGUARD_TOOLS_VERSION")}.tar.xz",
                      files: { "COPYING" => "COPYING" }),
        Component.new(name: "iputils", url: "https://github.com/iputils/iputils/archive/refs/tags/#{iputils}.tar.gz",
                      files: { "LICENSE" => "LICENSE", "Documentation/LICENSE.GPL2" => "LICENSE.GPL2" }),
        Component.new(name: "shell-operator",
                      url: "https://github.com/flant/shell-operator/archive/refs/tags/#{args.fetch("SHELL_OPERATOR_VERSION")}.tar.gz",
                      files: { "LICENSE" => "LICENSE" }),
      ] + UPSTREAM
    end

    def dockerfile_args
      File.read(DOCKERFILE).scan(%r{^ARG (\w+)="?([^"\n]*)"?$}).to_h
    end

    private

    def fetch(component, into:)
      puts "Fetching the license of #{component.name}"
      Dir.mktmpdir("license-archive") do |dir|
        archive = File.join(dir, File.basename(component.url))
        URI.parse(component.url).open { |download| File.binwrite(archive, download.read) }
        top = capture("tar", "-tf", archive).lines.first.split("/").first

        target = File.join(into, component.name)
        FileUtils.mkdir_p(target)
        component.files.each do |path, name|
          text = capture("tar", "-xOf", archive, "#{top}/#{path}")
          text = component.extract.call(text) if component.extract
          File.write(File.join(target, name), text)
        end
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
  desc "Fetch the license files of the software the images bundle into licenses/"
  task :update do
    Licenses.update
  end
end
