![netwrangler: virtual IPs for Kubernetes][banner]

# netwrangler

netwrangler is a Kubernetes operator that places virtual IPs on the nodes that
run a Service's pods. On each node it sets up the addresses, policy routes and
nftables rules that route each virtual IP's traffic through its network's
interface and gateway.

- **Ingress.** Clients reach a Service through a virtual IP on the nodes that
  run its pods, and replies go back the way the requests came, with the virtual
  IP as source.
- **Egress.** Pods behind a Service reach other networks with the Service's
  virtual IP as source address, so the other side sees one stable address
  instead of node addresses.
- **Routing through pods.** Every node routes traffic for a remote network,
  such as a site behind a VPN, through gateway pods, also across a WireGuard
  mesh between the nodes. While no gateway pod runs, the remote network is
  unreachable instead of leaking out through the default route.
- **Failover and load distribution.** Virtual IPs move to healthy nodes when a
  node or its pods fail, spread across nodes in proportion to the pods, and are
  announced with gratuitous ARP on every move. On bare metal, this takes the
  place of a cloud load balancer.
- **Several networks per node.** Each virtual IP belongs to a network with its
  own interface and gateway, such as a DMZ or a second uplink, and its traffic
  leaves through that network instead of the node's default route.

netwrangler is written in [Crystal](https://crystal-lang.org/) and runs on
[shell-operator](https://github.com/flant/shell-operator).

## Usage

A VipNetwork names the network the virtual IPs come from and the node interface
that carries them:

```yaml
apiVersion: netwrangler.dev/v1
kind: VipNetwork
metadata:
  name: public
spec:
  interface: eth0
  gatewayIP: 192.0.2.1
  networkCIDR: 192.0.2.0/24
```

A Service opts in with the `netwrangler.dev/ingress` label and lists its
virtual IPs as `externalIPs`:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: whoami
  labels:
    netwrangler.dev/ingress: enabled
spec:
  type: ClusterIP
  selector:
    app: whoami
  ports:
    - port: 80
      protocol: TCP
  externalIPs:
    - 192.0.2.10
```

The controller places `192.0.2.10` on a node with a ready `whoami` pod and
moves it when that pod goes away. `kubectl get vipaddresses --all-namespaces`
shows the node.

The cluster also needs one VipConfig, which sets the firewall marks, route
tables and rule priorities the controller hands out.
[`examples/cluster/`][cluster] has the VipConfig and the VipNetworks; apply it,
then the [ingress example][ingress], which has the Service with its Deployment.
[`examples/`][examples] has one example per use case. `rake demo:deploy` runs
all of them on the project's kind cluster and proves each one with real
traffic; [`examples/`][examples] explains how.

## Installation

Install the Helm chart from the OCI registry:

<!-- release-version -->

```sh
helm install netwrangler \
  oci://registry-1.docker.io/jochen/netwrangler \
  --version 1.0.0-dev \
  --namespace netwrangler \
  --create-namespace
```

<!-- /release-version -->

The agent runs the node's own nftables, iproute2 and iputils `arping`, and
needs Linux 5.6 or newer. [INSTALL.md][install] lists the prerequisites and
covers CRD updates and upgrades.

## Documentation

- [Installation][install]: prerequisites, the chart, upgrades
- [Configuration][configuration]: VipConfig, VipNetwork, Services and
  VipGateway
- [Reference][reference]: the custom resources and the Helm values
- [How it works][how-it-works]: the controller, the agent, gateway routing and
  the node tools
- [Development][development]: building, testing, the kind cluster and the Rake
  tasks
- [Dependencies][dependencies]: the bundled software and its licenses
- [Examples][examples]: one manifest set per use case
- [Code of conduct][code-of-conduct]

## License

MIT License, copyright (c) 2026 Jochen Seeber. See [LICENSE.md][license] for
the full text.

<!-- Absolute links: the chart's README.md links to this file, and Artifact Hub
shows it without the repository around it. -->

[banner]: https://raw.githubusercontent.com/jochenseeber/netwrangler/main/artwork/netwrangler-banner.jpg
[cluster]: https://github.com/jochenseeber/netwrangler/tree/main/examples/cluster
[code-of-conduct]: https://github.com/jochenseeber/netwrangler/blob/main/CODE_OF_CONDUCT.md
[configuration]: https://github.com/jochenseeber/netwrangler/blob/main/docs/configuration.md
[dependencies]: https://github.com/jochenseeber/netwrangler/blob/main/docs/dependencies.md
[development]: https://github.com/jochenseeber/netwrangler/blob/main/docs/development.md
[examples]: https://github.com/jochenseeber/netwrangler/blob/main/examples/README.md
[how-it-works]: https://github.com/jochenseeber/netwrangler/blob/main/docs/how-it-works.md
[ingress]: https://github.com/jochenseeber/netwrangler/tree/main/examples/ingress
[install]: https://github.com/jochenseeber/netwrangler/blob/main/INSTALL.md
[license]: https://github.com/jochenseeber/netwrangler/blob/main/LICENSE.md
[reference]: https://github.com/jochenseeber/netwrangler/blob/main/docs/reference.md
