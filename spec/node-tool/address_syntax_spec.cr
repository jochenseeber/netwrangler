require "./spec_helper"

private def ipv4?(text : String) : Bool
  valid = Netwrangler::PrivilegedRunner::AddressSyntax.ipv4?(text)

  valid
end

private def ipv6?(text : String) : Bool
  valid = Netwrangler::PrivilegedRunner::AddressSyntax.ipv6?(text)

  valid
end

describe Netwrangler::PrivilegedRunner::AddressSyntax do
  describe ".ipv4?" do
    it "accepts dotted decimal addresses" do
      %w[0.0.0.0 10.0.0.5 255.255.255.255 198.51.100.0].each do |text|
        {text, ipv4?(text)}.should eq({text, true})
      end
    end

    it "refuses what Rust's Ipv4Addr refuses" do
      ["", "10.0.0", "10.0.0.0.0", "10.0.0.256", "010.0.0.1", "10.0.0.01", "1000.0.0.1",
       "10.0.0.-1", "+10.0.0.1", " 10.0.0.1", "10.0.0.1 ", "10..0.1", "0x0a.0.0.1", "10.0.0.1/8",
       "host.example"].each do |text|
        {text, ipv4?(text)}.should eq({text, false})
      end
    end
  end

  describe ".ipv6?" do
    it "accepts the forms Rust's Ipv6Addr accepts" do
      %w[:: ::1 fd00:: fd00::1 1:2:3:4:5:6:7:8 1:2:3:4:5:6:7:: ::2:3:4:5:6:7:8 FD00::ABCD
        ::ffff:10.0.0.1 1:2:3:4:5:6:10.0.0.1 0001:0002::0003].each do |text|
        {text, ipv6?(text)}.should eq({text, true})
      end
    end

    it "refuses what Rust's Ipv6Addr refuses" do
      ["", ":", ":1", "1:", ":::", "1::2::3", "1:2:3:4:5:6:7:8:9", "1:2:3:4:5:6:7", "12345::",
       "fd00::g", "10.0.0.1", "10.0.0.1::", "1:2:3:4:5:6:7:10.0.0.1", "::ffff:010.0.0.1",
       "fe80::1%eth0", "[::1]", "fd00::/64"].each do |text|
        {text, ipv6?(text)}.should eq({text, false})
      end
    end
  end
end
