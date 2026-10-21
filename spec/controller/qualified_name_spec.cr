require "./spec_helper"

describe Netwrangler::Util::QualifiedName do
  describe "#to_s" do
    it "returns namespace/name" do
      qualified_name = Netwrangler::Util::QualifiedName.new(name: "my-resource", namespace: "my-namespace")
      qualified_name.to_s.should eq("my-namespace/my-resource")
    end
  end
end
