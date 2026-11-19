# Examples

Each directory holds one use case, and the project's kind cluster runs all of
them at once. `rake demo:deploy` applies the files in this directory as they
are and proves each example with real traffic.

| Example                                                  | Namespace                               | Addresses                                    | What it shows                                                      |
| -------------------------------------------------------- | --------------------------------------- | -------------------------------------------- | ------------------------------------------------------------------ |
| [`ingress`](ingress)                                     | `netwrangler-ingress`                   | `10.89.1.200`                                | A Service reachable on a virtual IP.                               |
| [`egress`](egress)                                       | `netwrangler-egress`                    | `10.89.1.201`                                | Pods that call out with the virtual IP as source address.          |
| [`several-networks`](several-networks)                   | `netwrangler-several-networks`          | `10.89.1.220`, `10.89.2.220`                 | One Service with virtual IPs in two VipNetworks on two interfaces. |
| [`failover`](failover)                                   | `netwrangler-failover`                  | `10.89.1.210` to `10.89.1.212`               | Virtual IPs that move to nodes with ready pods.                    |
| [`gateway-routing`](gateway-routing)                     | `netwrangler-gateway-routing`           | destination `10.90.1.0/24`, answered on `.1` | Traffic to a destination network routed through gateway pods.      |
| [`gateway-routing-wireguard`](gateway-routing-wireguard) | `netwrangler-gateway-routing-wireguard` | destination `10.90.2.0/24`, answered on `.1` | The same, with gateway pods reached through WireGuard.             |

## Running the demo

The demo needs Docker, kind, Ruby with Bundler and the project's Rake tasks
([development.md](../docs/development.md)). Create the cluster, then run every
example:

```sh
rake kind:start
rake demo:deploy
```

`rake demo:deploy` installs netwrangler, applies [`cluster/`](cluster) and then
each example in the order of the table. Every check prints one line, `✓` and
what it proved, or `✗` and why it failed. A failed example does not stop the
run: the next one starts, and a summary line per example closes the output. The
task fails when any example failed. The examples stay applied for you to look
at.

Run or rerun a single example with its directory name:

```sh
rake demo:deploy:failover
```

Remove the examples and the demo's cluster-wide objects:

```sh
rake demo:clean
```

The Docker networks and the WireGuard mesh stay; the integration tests use them
too. `rake test` runs `demo:clean` first, since the tests bring their own
VipConfig and VipNetworks.

The demo runs the images already on the cluster under the chart's `appVersion`
tag and builds and loads them only when a node lacks one. After changing the
code, run `rake kind:restart` to rebuild and roll out the images.

## The demo cluster

`rake kind:start` creates a control plane and two workers. `rake demo:deploy`
attaches two Docker networks to every node (`rake kind:networks`):

| Docker network        | Subnet         | Node interface | Virtual IPs from |
| --------------------- | -------------- | -------------- | ---------------- |
| `netwrangler-public`  | `10.89.1.0/24` | `eth1`         | `10.89.1.128/25` |
| `netwrangler-private` | `10.89.2.0/24` | `eth2`         | `10.89.2.128/25` |

Docker hands out the lower half of each subnet to containers, and the virtual
IPs come from the upper half. The VipNetworks `public` and `private` in
`cluster/` name these interfaces and networks.

`rake kind:wireguard` joins the nodes with a WireGuard mesh on the interface
`wg-demo`, port 51820. A node's peers allow the other nodes' pod networks and
their `eth0` addresses. Pod traffic does not use the mesh; only the
`gateway-routing-wireguard` example routes its gateway pod's IP through it.

macOS cannot reach the Docker networks, so the clients outside the cluster are
short-lived containers on `netwrangler-public` or `netwrangler-private`.

With Docker Desktop,
[docker-mac-net-connect](https://github.com/chipmk/docker-mac-net-connect)
routes the Docker networks to macOS through a WireGuard tunnel, so the virtual
IPs and the demo's containers answer from the Mac directly:

```sh
brew install chipmk/tap/docker-mac-net-connect
sudo brew services start chipmk/tap/docker-mac-net-connect
curl http://10.89.1.200
```

The demo's checks do not need it.

## What the checks prove

| Example                     | Checks                                                                                                                                                                                                                                                 |
| --------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `ingress`                   | The VipAddress for `10.89.1.200` names a node, and a client on `netwrangler-public` gets an answer from a `whoami` pod on that address.                                                                                                                |
| `egress`                    | The VipAddress has `egressEnabled: true`, and the server container `netwrangler-demo-server` (`10.89.1.100`) sees a request from the pod on the node holding the address come from `10.89.1.201`.                                                      |
| `several-networks`          | Clients on both networks get answers from `10.89.1.220` and `10.89.2.220`, whose VipAddresses name the networks `public` and `private`.                                                                                                                |
| `failover`                  | All three addresses answer. After a node holding one of them is cordoned and its pods deleted, no VipAddress names the node any more and all three answer again. The node is uncordoned afterwards.                                                    |
| `gateway-routing`           | A VipRoute names the gateway pod's IP, and the client pod on another node gets the gateway pod's answer from `10.90.1.1`.                                                                                                                              |
| `gateway-routing-wireguard` | The gateway pod's IP routes through `wg-demo` on the other nodes, a VipRoute names it, the agents add `10.90.2.0/24` to the WireGuard peer's allowed IPs, and the client pod's request to `10.90.2.1` gets the gateway pod's answer through `wg-demo`. |

The agents re-resolve the gateway pod's route on events or on their 30-second
resync, so the WireGuard check waits up to 90 seconds for the allowed IPs.

## Applying an example by hand

Install the chart, then apply the cluster-wide objects, the VipConfig and the
VipNetworks, once:

```sh
kubectl apply -f examples/cluster/
```

Each other directory holds one example in its own namespace
`netwrangler-<directory>`. Apply the namespace first, then the rest:

```sh
kubectl apply -f examples/ingress/namespace.yaml
kubectl apply -f examples/ingress/
```

Delete an example with `kubectl delete -f examples/<directory>/`.

## Checking an example by hand

For the ingress, egress, several-networks and failover examples, the controller
creates one VipAddress per external IP:

```sh
kubectl get vipaddresses --all-namespaces
```

Each row names the node that holds the address. On that node, `ip addr show`
lists it on the VipNetwork's interface.

Reach a virtual IP from a container on the Docker network `netwrangler-public`:

```sh
docker run --rm --network netwrangler-public curlimages/curl:8.11.1 -s http://10.89.1.200
```

The egress example's server container `netwrangler-demo-server` (`10.89.1.100`)
shows the source address of a pod's request.

For the gateway examples, the controller creates one VipRoute per running
gateway pod:

```sh
kubectl get vipgateways,viproutes --all-namespaces
```

On a node, `ip rule show` lists the gateway's rule (protocol 110) and
`ip route show table <routeTable>` lists the route through the pod and the
`unreachable` fallback. The gateway pod answers on the `.1` address of its
destination network; the client pod, which runs on another node, reaches it:

```sh
kubectl exec -n netwrangler-gateway-routing deploy/client -- curl -s http://10.90.1.1
kubectl exec -n netwrangler-gateway-routing-wireguard deploy/client -- curl -s http://10.90.2.1
```

On the client pod's node, `wg show wg-demo allowed-ips` lists `10.90.2.0/24`
for the peer of the gateway pod's node.

## On a real cluster

- In `cluster/vipnetworks.yaml`, name your nodes' interfaces, networks and
  gateway addresses.
- In `cluster/vipconfig.yaml`, list your cluster's pod and service networks as
  `clusterCIDRs`.
- In the examples, use addresses from your networks as `externalIPs` and as
  gateway destinations. A destination must not overlap a node network or a
  `clusterCIDRs` entry, or the agent refuses the gateway.
- The pods run on worker nodes only; drop the node affinity if your control
  plane nodes run workloads.
- The WireGuard example needs a WireGuard interface whose peers reach the
  gateway pods; the demo's host route through `wg-demo` stands in for one.
