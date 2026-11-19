# frozen_string_literal: true

require "ipaddr"
require "json"
require_relative "node_shell"

module KindCluster
  # A Docker network the demo attaches to every node, as the node's +interface+.
  # Docker hands out addresses from +ip_range+, which leaves the rest of the
  # subnet to the demo's virtual IPs.
  DockerNetwork = Data.define(:name, :subnet, :ip_range, :gateway, :interface)

  # The two networks the demo's VipNetworks use, and the code that attaches them
  # to the kind nodes under their fixed interface names.
  class DemoNetworks
    # The network of the VipNetwork `public`, which stands for the outside world.
    PUBLIC = DockerNetwork.new(name: "netwrangler-public", subnet: "10.89.1.0/24", ip_range: "10.89.1.0/25",
                               gateway: "10.89.1.1", interface: "eth1")

    # The network of the VipNetwork `private`.
    PRIVATE = DockerNetwork.new(name: "netwrangler-private", subnet: "10.89.2.0/24", ip_range: "10.89.2.0/25",
                                gateway: "10.89.2.1", interface: "eth2")

    NETWORKS = [PUBLIC, PRIVATE].freeze

    # @param shell [NodeShell]
    # @param output [IO] where progress goes
    def initialize(shell:, output: $stdout)
      @shell = shell
      @output = output
    end

    # Create the networks that are missing and attach every node to each one on
    # its interface, repairing a node that is detached or on another interface,
    # then check the result. Does nothing when everything is in place.
    def ensure
      NETWORKS.each { |network| create(network) }
      @shell.nodes.each { |node| attach(node) }
      verify
      @output.puts "kind networks ready"
    end

    private

    def create(network)
      configs = docker_ipam(network)
      if configs.nil?
        docker!("network", "create", "--subnet=#{network.subnet}", "--ip-range=#{network.ip_range}",
                "--gateway=#{network.gateway}", network.name)
        @output.puts "created network #{network.name}"
      else
        check_settings(network, configs)
      end
    end

    # Abort when an existing network does not have the demo's subnet, ip range and gateway.
    def check_settings(network, configs)
      config = configs.find { |entry| entry["Subnet"] == network.subnet }
      actual = config && { ip_range: config["IPRange"], gateway: config["Gateway"] }
      expected = { ip_range: network.ip_range, gateway: network.gateway }
      return if actual == expected

      found = configs.map { |entry| entry.values_at("Subnet", "IPRange", "Gateway").join(" ") }.join("; ")
      abort "network #{network.name} has subnet/ip-range/gateway #{found}, not " \
            "#{network.subnet} #{network.ip_range} #{network.gateway}; " \
            "remove it with `docker network rm #{network.name}` and run again"
    end

    # The IPAM configs of an existing Docker network, or nil when there is none.
    def docker_ipam(network)
      result = @shell.docker("network", "inspect", network.name, "--format", "{{json .IPAM.Config}}")
      return nil unless result.success?

      JSON.parse(result.stdout)
    end

    # Disconnect every network of the node that sits on the wrong interface first,
    # so a swapped pair does not hold each other's names, then connect what is
    # missing under its interface.
    def attach(node)
      placed = NETWORKS.to_h { |network| [network, interfaces_in(node, network)] }
      wrong = placed.reject { |network, found| (found.empty? && !member?(node, network)) || found == [network.interface] }
      wrong.each_key { |network| detach(node, network) }
      placed.each do |network, found|
        next if found == [network.interface]

        connect(node, network)
      end
    end

    def connect(node, network)
      docker!("network", "connect", "--driver-opt",
              "com.docker.network.endpoint.ifname=#{network.interface}", network.name, node)
      @output.puts "connected #{node} to #{network.name} as #{network.interface}"
    end

    def detach(node, network)
      docker!("network", "disconnect", network.name, node)
      @output.puts "disconnected #{node} from #{network.name}"
    end

    def member?(node, network)
      result = @shell.docker("network", "inspect", network.name, "--format",
                             "{{range .Containers}}{{.Name}} {{end}}")
      result.success? && result.stdout.split.include?(node)
    end

    # The names of the node's interfaces that have an address in the network's subnet.
    def interfaces_in(node, network)
      subnet = IPAddr.new(network.subnet)
      JSON.parse(@shell.run!(node, "ip -json addr show")).filter_map do |link|
        addresses = link.fetch("addr_info", []).select { |info| info["family"] == "inet" }
        link["ifname"] if addresses.any? { |info| subnet.include?(IPAddr.new(info["local"])) }
      end
    end

    def verify
      @shell.nodes.each do |node|
        NETWORKS.each do |network|
          found = interfaces_in(node, network)
          next if found == [network.interface]

          abort "#{node} has no address of #{network.subnet} on #{network.interface} " \
                "(found on: #{found.empty? ? "none" : found.join(", ")})"
        end
      end
    end

    def docker!(*args)
      result = @shell.docker(*args)
      raise "docker #{args.join(" ")} failed: #{result.stderr.strip}" unless result.success?

      result.stdout
    end
  end
end
