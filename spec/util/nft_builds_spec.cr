require "./spec_helper"

# A directory laid out like the image's nft builds, next to files discovery
# must skip: another tool, a bare nft, and nft- without a version
private def with_nft_builds(versions : Array(String), &)
  directory = File.tempname("nft-builds-spec")
  Dir.mkdir(directory)
  versions.each { |version| File.write(File.join(directory, "nft-#{version}"), "") }
  ["ip", "nft", "nft-latest"].each { |name| File.write(File.join(directory, name), "") }

  begin
    yield Netwrangler::Util::NftBuilds.discover(Path.posix(directory)), Path.posix(directory)
  ensure
    FileUtils.rm_rf(directory)
  end
end

describe Netwrangler::Util::NftBuilds do
  describe ".discover" do
    it "lists the versions in numerical order and skips other files" do
      with_nft_builds(["1.1.7", "1.0.6.1", "1.1.10"]) do |builds, _|
        builds.versions.map(&.to_s).should eq(["1.0.6.1", "1.1.7", "1.1.10"])
      end
    end

    it "finds no builds in a directory that does not exist" do
      builds = Netwrangler::Util::NftBuilds.discover(Path.posix("/nonexistent/sbin"))

      builds.versions.should be_empty
    end
  end

  describe "#path" do
    it "runs the latest build when no version is requested" do
      with_nft_builds(["1.1.7", "1.0.6.1", "1.1.10"]) do |builds, directory|
        builds.path(requested: nil).should eq(directory / "nft-1.1.10")
      end
    end

    it "runs the requested build" do
      with_nft_builds(["1.1.7", "1.0.6.1"]) do |builds, directory|
        builds.path(requested: "1.0.6.1").should eq(directory / "nft-1.0.6.1")
      end
    end

    it "names the available builds when the requested one is missing" do
      with_nft_builds(["1.1.7", "1.1.6"]) do |builds, _|
        expect_raises(Netwrangler::Util::NftBuildNotFoundError,
          "NETWRANGLER_NFT_VERSION=1.1.3 names no bundled nft build, available: 1.1.6, 1.1.7") do
          builds.path(requested: "1.1.3")
        end
      end
    end

    it "refuses a request that is not a version" do
      with_nft_builds(["1.1.7"]) do |builds, _|
        expect_raises(Netwrangler::Util::NftBuildNotFoundError, /NETWRANGLER_NFT_VERSION=latest/) do
          builds.path(requested: "latest")
        end
      end
    end

    it "reports an image without nft builds" do
      builds = Netwrangler::Util::NftBuilds.discover(Path.posix("/nonexistent/sbin"))

      expect_raises(Netwrangler::Util::NftBuildNotFoundError, "No nft builds found") do
        builds.path(requested: nil)
      end
    end
  end
end
