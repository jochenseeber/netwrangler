require "./spec_helper"

private PUBLIC_KEY = "xTIBA5rboUvnH4htodjb6e697QjLERt1NAB4mZqp8Dg="

# `nft -j` and one document, which may hold spaces
private def nft_document(document : String) : Array(String)
  arguments = ["-j", document]

  arguments
end

private def nft_refusal(arguments : Array(String)) : String?
  refusal = PrivilegedRunnerSpecs.refusal_of(arguments) { |given| Netwrangler::PrivilegedRunner::Arguments.check_nft(given) }

  refusal
end

describe Netwrangler::PrivilegedRunner::Arguments do
  describe ".check_ip" do
    it "accepts the agent's calls" do
      PrivilegedRunnerSpecs.accepts_all([
        "--json rule show",
        "rule add fwmark 0x40000/0xff0000 table 10900 priority 10900 protocol 110",
        "rule del priority 100 to 198.51.100.0/24 fwmark 0/0xff0000",
        "route replace 198.51.100.0/24 via 10.0.0.1 dev eth0 src 10.0.0.5 table 10 proto 110",
        "route replace unreachable 198.51.100.0/24 table 10 metric 4294967295",
        "route del unicast 198.51.100.0/24 table 10",
        "route flush table 10",
        "--json route get 10.244.1.5",
        "--json route show table 10 198.51.100.0/24",
        "addr add 10.0.0.5/24 dev eth0 label eth0:vip",
        "addr del 10.0.0.5/24 dev eth0",
        "--json addr show dev eth0",
        "--json link show",
        "--json link show type wireguard",
        "-V",
      ]) { |arguments| Netwrangler::PrivilegedRunner::Arguments.check_ip(arguments) }
    end

    it "refuses other calls" do
      PrivilegedRunnerSpecs.refuses_all([
        "netns list",
        "netns exec x sh",
        "-batch f",
        "-n x route show",
        "link set eth0 down",
        "route add -x",
        "addr show $(id)",
        "route replace 198.51.100.0/24 encap seg6 mode encap segs fc00::1 dev eth0",
        "",
      ]) { |arguments| Netwrangler::PrivilegedRunner::Arguments.check_ip(arguments) }
    end

    it "names what it refuses" do
      PrivilegedRunnerSpecs.refusal_of(PrivilegedRunnerSpecs.call("netns list")) { |arguments| Netwrangler::PrivilegedRunner::Arguments.check_ip(arguments) }
        .should eq("argument not allowed: netns")
      PrivilegedRunnerSpecs.refusal_of(PrivilegedRunnerSpecs.call("")) { |arguments| Netwrangler::PrivilegedRunner::Arguments.check_ip(arguments) }
        .should eq("needs an object and a verb")
    end

    it "refuses an argument that is not UTF-8" do
      arguments = ["link", "show", String.new(Bytes[0x65, 0x74, 0x68, 0xff])]

      PrivilegedRunnerSpecs.refusal_of(arguments) { |given| Netwrangler::PrivilegedRunner::Arguments.check_ip(given) }
        .should eq("argument not allowed: eth�")
    end
  end

  describe ".check_wg" do
    it "accepts the agent's calls" do
      PrivilegedRunnerSpecs.accepts_all([
        "--version",
        "show wg0 allowed-ips",
        "set wg0 peer #{PUBLIC_KEY} allowed-ips 198.51.100.0/24,10.0.0.0/8",
      ]) { |arguments| Netwrangler::PrivilegedRunner::Arguments.check_wg(arguments) }
    end

    it "accepts IPv6 allowed IPs" do
      PrivilegedRunnerSpecs.accepts_all([
        "set wg0 peer #{PUBLIC_KEY} allowed-ips fd00::/64",
        "set wg0 peer #{PUBLIC_KEY} allowed-ips fd00::1",
        "set wg0 peer #{PUBLIC_KEY} allowed-ips ::/0",
        "set wg0 peer #{PUBLIC_KEY} allowed-ips 198.51.100.0/24,fd00::/64,10.0.0.1,fd00::1/128",
      ]) { |arguments| Netwrangler::PrivilegedRunner::Arguments.check_wg(arguments) }
    end

    it "refuses malformed allowed IPs" do
      PrivilegedRunnerSpecs.refuses_all([
        "set wg0 peer #{PUBLIC_KEY} allowed-ips fd00::/129",
        "set wg0 peer #{PUBLIC_KEY} allowed-ips 10.0.0.0/33",
        "set wg0 peer #{PUBLIC_KEY} allowed-ips fd00::/+64",
        "set wg0 peer #{PUBLIC_KEY} allowed-ips fd00::g/64",
        "set wg0 peer #{PUBLIC_KEY} allowed-ips 10.0.0.0/8,,fd00::/64",
      ]) { |arguments| Netwrangler::PrivilegedRunner::Arguments.check_wg(arguments) }
    end

    it "accepts empty allowed IPs" do
      arguments = PrivilegedRunnerSpecs.call("set wg0 peer #{PUBLIC_KEY} allowed-ips") << ""

      PrivilegedRunnerSpecs.refusal_of(arguments) { |given| Netwrangler::PrivilegedRunner::Arguments.check_wg(given) }.should be_nil
    end

    it "refuses other calls" do
      PrivilegedRunnerSpecs.refuses_all([
        "set wg0 private-key /etc/shadow",
        "set wg0 peer #{PUBLIC_KEY} remove",
        "show wg0",
        "show wg0 dump",
        "show wg0 private-key",
        "show interfaces dump x",
        "genkey",
        "set wg0 peer short= allowed-ips 10.0.0.0/8",
      ]) { |arguments| Netwrangler::PrivilegedRunner::Arguments.check_wg(arguments) }
    end
  end

  describe ".check_arping" do
    it "accepts the agent's calls" do
      PrivilegedRunnerSpecs.accepts_all([
        "-U -c 3 -I eth0 10.0.0.5",
        "-I eth0 -c 3 -U 10.0.0.5",
        "-V",
      ]) { |arguments| Netwrangler::PrivilegedRunner::Arguments.check_arping(arguments) }
    end

    it "refuses other calls" do
      PrivilegedRunnerSpecs.refuses_all([
        "-U -U -c 3 -I eth0 10.0.0.5",
        "-f -I eth0 10.0.0.5",
        "-c x -I eth0 10.0.0.5",
        "-U -c 3 -I eth0 host.example",
      ]) { |arguments| Netwrangler::PrivilegedRunner::Arguments.check_arping(arguments) }
    end
  end

  describe ".check_nft" do
    it "accepts the agent's calls" do
      PrivilegedRunnerSpecs.accepts_all([
        "-j list tables",
        "-j list map ip netwrangler-ipv4 netwrangler-snat-addresses",
        %(-j {"nftables":[]}),
        "--version",
        "-v",
      ]) { |arguments| Netwrangler::PrivilegedRunner::Arguments.check_nft(arguments) }
    end

    it "refuses other calls" do
      PrivilegedRunnerSpecs.refuses_all([
        "-f /etc/nftables.conf",
        "-j -f x",
        %(-j {"nftables":[]} {"nftables":[]}),
        "list ruleset",
        "-I /tmp -j list tables",
      ]) { |arguments| Netwrangler::PrivilegedRunner::Arguments.check_nft(arguments) }
    end

    it "accepts JSON documents" do
      [
        %({"nftables":[{"list":{"table":{"family":"ip","name":"t"}}}]}),
        %( { "comment" : "say \\"hi\\" \\\\ \\u00e9\\n", "nested" : [[1, -2.5e3, [true, false, null]], {}, []] } ),
      ].each do |document|
        {document, nft_refusal(nft_document(document))}.should eq({document, nil})
      end
    end

    it "refuses JSON that is not JSON" do
      calls = [
        %({;include "/etc/passwd"),
        %({"a":}),
        %({"a":1}}),
        %({"a":01}),
        %({"a":"\\u0000"}),
        %({"a":"\\ud800"}),
        %({"a":99999999999999999999}),
        %(["not","an","object"]),
        %({"a":"line\nbreak"}),
      ].map { |document| nft_document(document) }
      calls << (nft_document(%({"a":1})) << "x")
      calls << nft_document(%({"a":#{"[" * 100}#{"]" * 100}}))

      calls.each do |arguments|
        {arguments, nft_refusal(arguments).nil?}.should eq({arguments, false})
      end
    end
  end
end
