require "./spec_helper"

private def nft(major : Int32, minor : Int32, patch : Int32) : Netwrangler::Util::NftVersion
  Netwrangler::Util::NftVersion.new(major: major, minor: minor, patch: patch)
end

describe Netwrangler::Util::NftVersion do
  describe ".parse?" do
    it "reads the version nft --version prints" do
      Netwrangler::Util::NftVersion.parse?("nftables v1.0.6 (Lester Gooch #5)").should eq(nft(1, 0, 6))
      Netwrangler::Util::NftVersion.parse?("nftables v1.0.9 (Old Doc Yak #3)\n").should eq(nft(1, 0, 9))
      Netwrangler::Util::NftVersion.parse?("nftables v1.1.3 (Commodore Bullmoose #4)").should eq(nft(1, 1, 3))
    end

    it "ignores a fourth number" do
      Netwrangler::Util::NftVersion.parse?("nftables v1.0.6.1 (Lester Gooch #6)").should eq(nft(1, 0, 6))
    end

    it "rejects text without a version" do
      Netwrangler::Util::NftVersion.parse?("").should be_nil
      Netwrangler::Util::NftVersion.parse?("nftables v1.0").should be_nil
      Netwrangler::Util::NftVersion.parse?("nft: the node has no nft").should be_nil
    end
  end

  describe "#<=>" do
    it "compares each number as a number" do
      (nft(1, 0, 6) < nft(1, 0, 9)).should be_true
      (nft(1, 0, 9) < nft(1, 0, 10)).should be_true
      (nft(1, 0, 10) < nft(1, 1, 0)).should be_true
      (nft(0, 9, 8) < nft(1, 0, 6)).should be_true
      (nft(1, 0, 6) >= nft(1, 0, 6)).should be_true
    end
  end

  describe "#to_s" do
    it "prints the three numbers" do
      nft(1, 0, 6).to_s.should eq("1.0.6")
    end
  end
end
