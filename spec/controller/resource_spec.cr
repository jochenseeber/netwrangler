require "./spec_helper"
require "./fixtures"

describe Netwrangler::Model::Resource do
  describe "#reference" do
    it "returns an ObjectReference with the correct fields" do
      vip_address = ControllerFixtures.vip_address(
        name: "my-svc-1",
        namespace: "prod",
      )

      reference = vip_address.reference

      reference.kind.should eq("VipAddress")
      reference.api_version.should eq("netwrangler.dev/v1")
      reference.name.should eq("my-svc-1")
      reference.namespace.should eq("prod")
    end
  end
end
