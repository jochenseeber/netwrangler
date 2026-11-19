require "../spec_helper"

describe Netwrangler::Agent::ReportedErrors do
  it "reports a message once per run and not again in the next run" do
    path = File.tempname("reported-errors", ".json")
    begin
      first = Netwrangler::Agent::ReportedErrors.new(path)
      first.fresh?("overlap").should be_true
      first.fresh?("overlap").should be_false
      first.save

      Netwrangler::Agent::ReportedErrors.new(path).fresh?("overlap").should be_false
    ensure
      File.delete?(path)
    end
  end

  it "reports a message again once a run went by without it" do
    path = File.tempname("reported-errors", ".json")
    begin
      first = Netwrangler::Agent::ReportedErrors.new(path)
      first.fresh?("overlap")
      first.save

      second = Netwrangler::Agent::ReportedErrors.new(path)
      second.fresh?("other").should be_true
      second.save

      Netwrangler::Agent::ReportedErrors.new(path).fresh?("overlap").should be_true
    ensure
      File.delete?(path)
    end
  end

  it "reports every message when the file does not parse" do
    path = File.tempname("reported-errors", ".json")
    begin
      File.write(path, "not json")
      Netwrangler::Agent::ReportedErrors.new(path).fresh?("overlap").should be_true
    ensure
      File.delete?(path)
    end
  end
end
