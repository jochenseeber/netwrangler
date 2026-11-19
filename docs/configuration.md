# Configuration

After installing the chart, create the required custom resources before the
controller can allocate IPs. For complete manifests, see the
[examples](../examples/README.md).

## 1. VipConfig

A cluster-scoped singleton resource defining the global firewall mark, route
table, and routing policy rule priority configuration. Create one named
`default`:

```yaml
apiVersion: netwrangler.dev/v1
kind: VipConfig
metadata:
  name: default
spec:
  firewallMark: 0x01
  firewallMarkMask: 0x7F
  routeTable: 20001
  routingPriority: 20001
  maxAddressCount: 127
  clusterCIDRs:
    - 10.244.0.0/16
    - 10.96.0.0/12
```

| Field              | Description                                                                                                                                                                         |
| ------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `firewallMark`     | Base firewall mark value for per-IP allocation (immutable). Each VipAddress receives a unique mark from the range [firewallMark, firewallMark + maxAddressCount - 1].               |
| `firewallMarkMask` | Bitmask determining which firewall mark bits are used (immutable)                                                                                                                   |
| `routeTable`       | Base route table ID for per-IP allocation (immutable, min 1). The controller allocates a unique route table from a range starting at this value for each VipAddress.                |
| `routingPriority`  | Base routing preference / `ip rule` priority for per-IP allocation (immutable). The controller allocates a unique priority from a range starting at this value for each VipAddress. |
| `maxAddressCount`  | Maximum number of virtual IPs supported across all networks                                                                                                                         |
| `clusterCIDRs`     | Cluster-internal networks (optional). Traffic whose source and destination both lie in these networks is never marked, and a VipGateway whose destination overlaps one is refused.  |

Each VipAddress receives its own `firewallMark`, `routeTable`, and
`routingPriority` allocated by the controller from the base values defined on
the VipConfig. All VipAddresses share the same `firewallMarkMask`.

Without a VipConfig the controller assigns no virtual IPs. It places at most
`min(maxAddressCount, 2^popcount(firewallMarkMask) - 1)` virtual IPs of one
Service on a node; the example's mask `0x7F` has 7 bits, so the limit is 127.
The limit applies when the controller keeps existing VipAddresses on their
nodes, assigns new ones and rebalances.

## 2. VipNetwork

A cluster-scoped resource defining the network interface, gateway, and network
addressing for a set of virtual IPs. Create one per VIP network:

```yaml
apiVersion: netwrangler.dev/v1
kind: VipNetwork
metadata:
  name: public
spec:
  interface: eth0
  gatewayIP: 192.168.111.254
  networkCIDR: 192.168.111.0/24
  sourceCIDRs:
    - 10.0.0.0/8
```

| Field         | Description                                        |
| ------------- | -------------------------------------------------- |
| `interface`   | Network interface name (immutable)                 |
| `gatewayIP`   | Gateway address for routing                        |
| `networkCIDR` | Network in CIDR notation (e.g., 192.168.111.0/24)  |
| `sourceCIDRs` | Additional source CIDRs for mark map entries (opt) |

Use `sourceCIDRs: ["0.0.0.0/0"]` for a catch-all network that marks all traffic
regardless of source. When `0.0.0.0/0` is present, other entries are ignored.
Within one VipNetwork, an entry that lies inside a broader entry or inside
`networkCIDR` is ignored with a warning. Source CIDRs of different VipNetworks
may overlap.

## 3. Service

Label your Service to opt in to virtual IP management:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: my-service
  labels:
    netwrangler.dev/ingress: enabled
    netwrangler.dev/egress: enabled
spec:
  type: ClusterIP
  externalIPs:
    - 203.0.113.10
    - 203.0.113.11
  ports:
    - port: 80
      protocol: TCP
  selector:
    app: my-app
```

Requirements:

- Label `netwrangler.dev/ingress: enabled` opts the service into virtual IP
  management
- Label `netwrangler.dev/egress: enabled` enables egress marking for pods
  behind this service (optional, default: disabled)
- `externalIPs` must list valid IPv4 addresses — each IP is automatically
  matched to a VipNetwork by CIDR. IPs may belong to different VipNetworks.
- VipNetwork CIDRs must not overlap. Overlapping networks are automatically
  disabled, preferring to keep networks with existing VipAddresses or more
  specific (longer prefix) networks.

## 4. VipGateway

A cluster-scoped resource defining a gateway routing policy. The VipGateway
selects Pods directly via `podSelector.matchLabels`. Pods must have the label
`netwrangler.dev/gateway: enabled` to be watched by the controller. For each
matching running Pod with a podIP, the controller creates a VipRoute resource,
and the agent installs routes on every node.

```yaml
apiVersion: netwrangler.dev/v1
kind: VipGateway
metadata:
  name: my-gateway
spec:
  destinationCIDR: 10.0.0.0/8
  routeTable: 200
  routingPriority: 100
  podSelector:
    matchLabels:
      app: my-gateway-app
```

| Field             | Description                                      |
| ----------------- | ------------------------------------------------ |
| `destinationCIDR` | Destination network in CIDR notation             |
| `routeTable`      | Linux routing table number (immutable, min 1)    |
| `routingPriority` | Policy rule priority for `ip rule` (min 1)       |
| `podSelector`     | Pod selector with `matchLabels` for gateway pods |

All four fields are required.

Pods selected by a VipGateway must carry the label
`netwrangler.dev/gateway: enabled` so the controller watches them. The
`podSelector.matchLabels` on the VipGateway further narrows which of those Pods
are associated with this particular gateway.

The `destinationCIDR` field specifies the destination network CIDR for the
routes created by this gateway. The controller finds matching running Pods and
creates one VipRoute per Pod, storing the Pod's IP address.

The agent installs the gateway's policy rule on every node as soon as the
VipGateway exists, whether or not a gateway Pod is running:

```sh
ip rule add to <destinationCIDR> fwmark 0/<firewallMarkMask> table <routeTable> priority <routingPriority> protocol 110
```

The rule matches only packets without a VIP firewall mark. For each VipRoute,
the agent resolves the route to the pod IP via `ip route get <podIP>` to find
the outgoing interface and source address, and adds a route through the pod to
the gateway's table. The resolution runs every 30 seconds, so routes heal
themselves when pods reschedule or the CNI reconfigures.

A gateway Pod whose IP is an address of its own node, such as a Pod on the host
network, makes that node the gateway: it reaches the destination through its
own routing tables. On that node the agent sets up neither the gateway's policy
rule nor its routes, and removes them if they exist; the destination stays in
`netwrangler-gateway-destinations`, so it is still not marked. The other nodes
route through the Pod as usual.

### Precedence over egress marking

Traffic from an egress-enabled endpoint to a gateway destination always takes
the gateway path, whatever the routing priorities. The agent keeps every
gateway destination in the nftables set `netwrangler-gateway-destinations`, and
both egress mark rules skip packets whose original destination is in that set.
These packets carry no VIP mark and are never SNATed to a VIP. Replies to
clients that connected to a VIP still carry the mark and follow the VIP's route
table.

While no gateway Pod runs, traffic to the destination is unreachable on every
node. The gateway table holds `unreachable <destinationCIDR> metric 4294967295`
next to the pod routes.

The agent refuses a VipGateway on a node when:

- its `destinationCIDR` overlaps a VipConfig `clusterCIDRs` network or any IPv4
  network on a node interface (address and prefix length), so `0.0.0.0/0` is
  always refused
- its `routeTable` is reserved (0, 253, 254 or 255) or is the route table of a
  VipAddress on the node
- its `routingPriority` is 32766 or later, so the main table rule would come
  first
- another VipGateway has the same `destinationCIDR` and `routeTable`; both are
  refused

A refused gateway gets no rule, route, set entry or WireGuard allowed IP on
that node, and the agent logs an error that names the conflict. The check runs
on each node separately.

For an egress-enabled VipAddress, the agent logs an error for each
`sourceCIDRs` entry that overlaps a gateway destination, once while the overlap
lasts and at debug level on later runs. The gateway still takes precedence for
that traffic.

A gateway whose destination overlaps a VIP network is handled per node. A node
that holds a VIP address of that network has the network on an interface, so it
refuses the gateway like any other node network. Nodes without an address in
that network apply it.

Creating or deleting a VipGateway moves egress traffic to its destination
between the VIP path and the gateway path. A connection that is open during the
switch keeps the source NAT that conntrack chose for its first packet, and has
to reconnect.

## Verification

Once configured, the controller creates VipAddress resources automatically:

```sh
kubectl get vipaddresses --all-namespaces
```

```text
NAMESPACE   NAME           NETWORK   NODE     VIRTUAL IP        TABLE   PRIORITY   AGE
default     my-service-1   public    node-1   203.0.113.10/24   20001   20001      5m
default     my-service-2   public    node-2   203.0.113.11/24   20002   20002      5m
```
