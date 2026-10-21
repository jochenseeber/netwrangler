require "./spec_helper"

private def version(text : String) : Netwrangler::Util::ToolVersion
  parsed = Netwrangler::Util::ToolVersion.parse?(text)
  raise "#{text} is not a version" if parsed.nil?

  parsed
end

describe Netwrangler::Util::ToolVersion do
  describe ".parse?" do
    it "reads three and four part versions" do
      version("1.1.7").parts.should eq([1, 1, 7])
      version("1.0.6.1").parts.should eq([1, 0, 6, 1])
    end

    it "refuses text that is not dotted numbers" do
      Netwrangler::Util::ToolVersion.parse?("latest").should be_nil
      Netwrangler::Util::ToolVersion.parse?("1").should be_nil
      Netwrangler::Util::ToolVersion.parse?("1.1.x").should be_nil
      Netwrangler::Util::ToolVersion.parse?("v1.1.7").should be_nil
      Netwrangler::Util::ToolVersion.parse?("1..7").should be_nil
      Netwrangler::Util::ToolVersion.parse?("").should be_nil
    end
  end

  describe "#<=>" do
    it "orders numerically, not as text" do
      versions = ["1.1.10", "1.0.6.1", "1.1.2", "1.1.9"].map { |text| version(text) }

      versions.sort.map(&.to_s).should eq(["1.0.6.1", "1.1.2", "1.1.9", "1.1.10"])
    end

    it "treats equal versions as equal" do
      version("1.1.7").should eq(version("1.1.7"))
    end
  end

  describe "#to_s" do
    it "joins the parts with dots" do
      version("1.0.6.1").to_s.should eq("1.0.6.1")
    end
  end
end
