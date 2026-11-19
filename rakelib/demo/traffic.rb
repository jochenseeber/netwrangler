# frozen_string_literal: true

require "json"
require_relative "../kind_cluster/demo_networks"
require_relative "../kind_cluster/node_shell"

module Demo
  # Requests the checks send: from a short-lived container on one of the demo's
  # Docker networks, which stands for a client outside the cluster, or from a pod
  # inside it.
  class Traffic
    # The image of the client containers. The example pods that send requests use
    # the same one.
    CURL_IMAGE = "curlimages/curl:8.11.1"

    # The container on the public network that the egress example sends its
    # requests to, its image, network and address.
    SERVER = "netwrangler-demo-server"
    SERVER_IMAGE = "traefik/whoami:v1.10.3"
    SERVER_NETWORK = KindCluster::DemoNetworks::PUBLIC.name
    SERVER_ADDRESS = "10.89.1.100"

    # How long one request may take, in seconds.
    MAX_TIME = 5

    # @param shell [KindCluster::NodeShell]
    def initialize(shell:)
      @shell = shell
    end

    # Pull the client image unless Docker has it, so a slow first pull does not
    # eat into the time a check gives its requests.
    def ensure_client_image
      return if @shell.docker("image", "inspect", CURL_IMAGE).success?

      result = @shell.docker("pull", "--quiet", CURL_IMAGE)
      raise "docker pull #{CURL_IMAGE} failed: #{result.stderr.strip}" unless result.success?
    end

    # Run the server container that answers the egress example's requests with
    # the address it sees them from. A container of that name with another
    # image or address, or one that does not run, is replaced.
    def ensure_server
      return if server_current?

      if @shell.docker("container", "inspect", SERVER).success?
        result = @shell.docker("rm", "--force", SERVER)
        raise "docker rm #{SERVER} failed: #{result.stderr.strip}" unless result.success?
      end
      result = @shell.docker("run", "--detach", "--name", SERVER, "--network", SERVER_NETWORK,
                             "--ip", SERVER_ADDRESS, SERVER_IMAGE)
      raise "docker run #{SERVER} failed: #{result.stderr.strip}" unless result.success?
    end

    # Request +url+ from a new container on the Docker network +network+.
    #
    # @return [KindCluster::CommandResult]
    def from_network(network, url)
      @shell.docker("run", "--rm", "--network", network, CURL_IMAGE, *curl_flags, url)
    end

    # Request +url+ from inside the pod +pod+ in +namespace+, which must have curl.
    #
    # @return [KindCluster::CommandResult]
    def from_pod(namespace, pod, url)
      @shell.kubectl("exec", "--namespace", namespace, pod, "--", "curl", *curl_flags, url)
    end

    # Why a request did not give the expected answer, for a check's failure line.
    #
    # @param result [KindCluster::CommandResult]
    # @return [String]
    def self.describe(result)
      return "answered #{result.stdout.strip.lines.first.to_s.strip.inspect}" if result.success?

      "failed with exit code #{result.exit_code}: #{result.stderr.strip.lines.last.to_s.strip}"
    end

    private

    # Whether the server container runs with the image, network and address it
    # should have.
    def server_current?
      result = @shell.docker("container", "inspect", SERVER)
      return false unless result.success?

      container = JSON.parse(result.stdout).first
      networks = container.dig("NetworkSettings", "Networks") || {}
      container.dig("State", "Running") == true && container.dig("Config", "Image") == SERVER_IMAGE &&
        networks.keys == [SERVER_NETWORK] &&
        networks.dig(SERVER_NETWORK, "IPAMConfig", "IPv4Address") == SERVER_ADDRESS
    end

    def curl_flags = ["--silent", "--show-error", "--max-time", MAX_TIME.to_s]
  end
end
