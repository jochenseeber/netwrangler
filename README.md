# netwrangler

Kubernetes operator for managing virtual IP assignments on cluster nodes.
Automatically distributes virtual IPs across nodes running service endpoints,
and configures each node's network stack with the necessary addresses, routing
tables, and nftables rules.

It covers three use cases:

- **Ingress** — Clients reach a Service through a virtual IP that [netwrangler]
  places on the nodes running the Service, and the replies go back the way the
  requests came, with the virtual IP as source.
- **Egress** — Pods behind a Service reach other networks with the Service's
  virtual IP as their source address, so the other side sees one stable address
  instead of node addresses.
- **Routing through pods** — Traffic for a remote network, such as a site
  behind a VPN, is routed through gateway pods from every node, also across a
  WireGuard mesh between the nodes. While no gateway pod runs, the remote
  network is unreachable instead of leaking out through the default route.

Two properties carry through all of them:

- **Failover and load distribution** — Virtual IPs move to healthy nodes when a
  node or its pods fail, are spread across nodes in proportion to the pods, and
  are announced to the network on every move. On bare metal, this takes the
  place of a cloud load balancer.
- **Several networks per node** — Each virtual IP belongs to a network with its
  own interface and gateway, such as a DMZ or a second uplink, and its traffic
  leaves through that network instead of the node's default route.

Written in [Crystal](https://crystal-lang.org/), deployed via
[shell-operator](https://github.com/flant/shell-operator).

## Overview

The operator consists of two components:

- **Controller** (Deployment) — Watches Services, EndpointSlices, and custom
  resources. When a Service is labelled with
  `netwrangler.dev/ingress: enabled`, the controller matches each externalIP to
  a VipNetwork by CIDR and allocates IPs to nodes that have ready endpoints,
  creating VipAddress resources. Also watches VipGateway resources and Pods
  labelled with `netwrangler.dev/gateway: enabled`, selecting matching Pods via
  the gateway's `podSelector` to create VipRoute resources for gateway routing.
- **Agent** (DaemonSet) — Runs on every node. Reads VipAddress and VipNetwork
  resources assigned to its node and configures IP addresses (`ip addr`),
  policy routing (`ip rule`, `ip route`), nftables sets, and firewall mark
  rules accordingly. Also watches VipGateway and VipRoute resources: installs
  each gateway's policy rule and fail-closed fallback on all nodes, and routes
  to the gateway pods, resolved dynamically via `ip route get`. Cleans up
  configuration when VipAddresses, VipGateways or VipRoutes are removed.

## Prerequisites

- Kubernetes cluster (v1.29+)
- Helm 3
- Nodes must run Linux on amd64 or arm64 (the agent image bundles statically
  compiled binaries)
- Nodes that run the agent need Linux 6.13 or newer, for nftables bitwise
  operations on two runtime values. On an older kernel the agent logs
  `Linux <version> is not supported` and stops its container, so the pod
  restarts and its log names the cause.

## Installation

Install the Helm chart from the OCI registry:

```sh
helm install netwrangler \
  oci://registry-1.docker.io/jochen/netwrangler \
  --namespace netwrangler \
  --create-namespace
```

**Note:** Helm does not update CRDs on chart upgrades. When CRD schemas change,
apply them manually:

```sh
helm show crds oci://registry-1.docker.io/jochen/netwrangler | kubectl apply --server-side --filename -
```

## Configuration

After installing the chart, create the required custom resources before the
controller can allocate IPs.

### 1. VipConfig

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

### 2. VipNetwork

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

### 3. Service

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

### 4. VipGateway

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
`gateway-destinations`, so it is still not marked. The other nodes route
through the Pod as usual.

#### Precedence over egress marking

Traffic from an egress-enabled endpoint to a gateway destination always takes
the gateway path, whatever the routing priorities. The agent keeps every
gateway destination in the nftables set `gateway-destinations`, and both egress
mark rules skip packets whose original destination is in that set. These
packets carry no VIP mark and are never SNATed to a VIP. Replies to clients
that connected to a VIP still carry the mark and follow the VIP's route table.

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

### Verification

Once configured, the controller creates VipAddress resources automatically:

```sh
kubectl get vipaddresses --all-namespaces
```

```text
NAMESPACE   NAME           NETWORK   NODE     VIRTUAL IP        TABLE   PRIORITY   AGE
default     my-service-1   public    node-1   203.0.113.10/24   20001   20001      5m
default     my-service-2   public    node-2   203.0.113.11/24   20002   20002      5m
```

## Custom Resources Reference

All custom resources use API group `netwrangler.dev/v1`.

| Resource   | Scope      | Short Name | Description                                                         |
| ---------- | ---------- | ---------- | ------------------------------------------------------------------- |
| VipConfig  | Cluster    | `vc`       | Global firewall mark, route table, and routing policy configuration |
| VipNetwork | Cluster    | `vn`       | Network interface, gateway, and network addressing                  |
| VipAddress | Namespaced | `va`       | Individual IP assignment to a node (managed by controller)          |
| VipGateway | Cluster    | `vg`       | Gateway routing policy (destination, table, priority, pod selector) |
| VipRoute   | Namespaced | `vr`       | Individual route to a gateway pod (managed by controller)           |

### VipAddress

VipAddress resources are created and managed by the controller. Every field is
**immutable**; when a value changes, the controller deletes the VipAddress and
creates it again.

| Field             | Description                                                        |
| ----------------- | ------------------------------------------------------------------ |
| `network`         | Name of the VipNetwork (required)                                  |
| `nodeName`        | Node the virtual IP is assigned to (required)                      |
| `virtualCIDR`     | Virtual IP with its network prefix, e.g. `10.0.1.10/24` (required) |
| `interface`       | Network interface, from the VipNetwork (required)                  |
| `gatewayIP`       | Gateway address, from the VipNetwork                               |
| `sourceCIDRs`     | Source networks, from the VipNetwork after overlap pruning         |
| `firewallMark`    | Firewall mark allocated by the controller                          |
| `routeTable`      | Route table ID allocated by the controller                         |
| `routingPriority` | Policy rule priority allocated by the controller                   |
| `egressEnabled`   | Whether egress marking is enabled (from the Service label)         |
| `endpointIPs`     | Pod IPs of the Service's ready endpoints on the node               |
| `ports`           | Service ports with protocol                                        |

VipAddress names follow the pattern `{serviceName}-{index}` (e.g.,
`my-service-1`). The index is a 1-based integer allocated per service, ensuring
unique names within a namespace.

Labels set by the controller:

- `netwrangler.dev/managed-by: netwrangler`
- `netwrangler.dev/namespace: <service-namespace>`
- `netwrangler.dev/network: <vipnetwork-name>`
- `netwrangler.dev/service: <service-name>`
- `netwrangler.dev/node-name: <node-name>`

Each VipAddress has two owner references: its Service (as controller) and its
VipNetwork, both with `blockOwnerDeletion`. Deleting either one lets Kubernetes
garbage-collect the VipAddress.

The controller only manages VipAddresses and VipRoutes whose
`netwrangler.dev/managed-by` label matches its manager name. The name is
`netwrangler` unless the controller's `NETWRANGLER_MANAGER_NAME` environment
variable sets another; the chart does not set it.

### VipRoute

VipRoute resources are created and managed by the controller for each matching
Pod selected by a VipGateway. One VipRoute is created per Pod.

| Field             | Description                                |
| ----------------- | ------------------------------------------ |
| `destinationCIDR` | Destination network CIDR (from VipGateway) |
| `gatewayNode`     | Node the gateway pod runs on               |
| `podIP`           | Pod IP address of the gateway pod          |
| `routeTable`      | Linux routing table number                 |
| `routingPriority` | Policy rule priority                       |

All fields are required and immutable.

VipRoute names follow the pattern `{podName}-{gatewayName}` (e.g.,
`my-pod-my-gateway`).

Labels set by the controller:

- `netwrangler.dev/managed-by: netwrangler`
- `netwrangler.dev/gateway: <gateway-name>`

## How It Works

### Controller

The controller runs as a shell-operator hook, triggered by changes to Services,
EndpointSlices, VipNetworks, VipConfigs, VipAddresses, VipGateways, VipRoutes,
and Pods labelled `netwrangler.dev/gateway: enabled`. It also resyncs every 30
seconds.

For each managed Service, the controller:

1. Takes the Service's `externalIPs` and matches each IP to a VipNetwork by
   CIDR
2. Collects nodes with ready endpoints from EndpointSlices
3. Claims existing VipAddresses on their current nodes
4. Assigns remaining IPs to the most undersupplied nodes (proportional to
   endpoint count)
5. Rebalances IPs across nodes to minimize quota deviation

### Gateway Routing

The controller also handles gateway routing for Pods labelled with
`netwrangler.dev/gateway: enabled`:

1. For each VipGateway, selects Pods whose labels match the gateway's
   `podSelector.matchLabels`
2. Filters to Running Pods that have a podIP
3. Creates one VipRoute per matching Pod with the VipGateway's destination IP,
   the pod IP, route table, and routing priority
4. Diffs desired VipRoutes against existing ones (filtered by `managed-by`
   label) and emits Create/Delete operations

The agent watches all VipGateway and VipRoute resources (not filtered by node)
and on every node:

1. Installs, for each VipGateway it applies (see the refusal rules above), the
   policy rule
   `ip rule add to <dest> fwmark 0/<mask> table <table> priority <priority> protocol 110`
   and the fallback `unreachable <dest> metric 4294967295` in its table
2. For each VipRoute whose destination and table match an applied gateway,
   resolves the route to the pod via `ip route get <podIP>` to discover the
   outgoing interface, next hop and source address, then installs:
   `ip route replace <dest> via <next_hop> dev <resolved_dev> src <resolved_src> table <table> proto 110`.
   The next hop is the kernel's gateway towards the pod, or the pod IP when the
   pod is directly reachable
3. Removes a gateway's rule and fallback when the VipGateway is deleted or
   refused, and a pod route when its VipRoute is deleted
4. Re-resolves pod routes every 30 seconds, so routes self-heal when pods
   reschedule or the CNI reconfigures

Every policy rule and route the agent adds carries routing protocol `110`
(`ip rule ... protocol 110`, `ip route ... proto 110`; `ip rule show` and
`ip route show` print `proto 110`, their `--json` forms `"protocol": "110"`).
The agent treats only rules with that tag as its own, so it never removes rules
other software installs, such as WireGuard's `fwmark` rules or another router's
`to` rules. Rules and routes from agent versions before the tag are replaced
while they are still wanted; ones that are no longer wanted stay and have to be
removed by hand (for example `ip rule del table <table>` and
`ip route flush table <table>`).

#### WireGuard

A gateway pod on another node may be reached through a WireGuard interface. The
agent treats the device `ip route get <podIP>` returns as WireGuard when
`wg show <dev>` accepts it. WireGuard only sends traffic to a destination that
a peer lists in its allowed IPs, so the agent adds the gateway's
`destinationCIDR` to the allowed IPs of the peer whose allowed IPs contain the
pod IP, and removes it from any other peer on that interface. Without such a
peer it logs a warning and changes nothing.

The agent records the destinations it added in
`/tmp/shell-operator/wireguard-managed.json`. When one is no longer wanted, it
removes it from every peer on every WireGuard interface. Allowed IPs it did not
add stay as they are.

### Agent

The agent runs as a shell-operator hook on each node, triggered by changes to
VipAddresses assigned to its node, VipNetworks, VipConfigs, VipGateways, and
VipRoutes. It also resyncs every 30 seconds. Every run sees all five resource
kinds and reconciles the node against them.

The agent reads everything a VIP needs from its VipAddress: `interface`,
`virtualCIDR`, `gatewayIP`, `sourceCIDRs` and the per-IP values
(`firewallMark`, `routeTable`, `routingPriority`). It skips a VipAddress whose
VipNetwork does not exist or whose interface is not up. The VipConfig provides
the firewall mark mask. For each VipAddress, the agent configures:

- **Addresses** — Adds the virtual IP on the interface with the correct network
  prefix and a `vip:` label prefix. Detects and replaces addresses with
  mismatched prefix lengths. After adding an address, it sends three gratuitous
  ARP announcements (`arping -U -c 3`) on the interface so upstream ARP caches
  learn the new location at once. An address that is already in place is not
  announced again.
- **Routing** — Creates a per-IP policy routing rule
  (`ip rule add fwmark <mark>/<mask> table <table> priority <priority> protocol 110`),
  a connected network route for the VIP's network, and routes for each
  configured source network via the gateway — all with the virtual IP as
  preferred source. Stale routes are removed automatically when source networks
  change.
- **nftables mark maps** — Manages four maps in the `netwrangler` table that
  map a packet's addresses to the VIP's firewall mark, used from the base
  chains `filter-prerouting` (prerouting hook) and `mangle-output` (output
  hook, for locally generated replies). Two specific maps
  (`type ipv4_addr . ipv4_addr : mark; flags interval`) pair a target IP with a
  network CIDR: `ingress-marks-ipv4` (keyed
  `ct original ip daddr . ct original ip saddr`) and `egress-marks-ipv4` (keyed
  `ct original ip saddr . ct original ip daddr`, only when `egressEnabled` is
  true). Each VIP gets an entry for the network of its `virtualCIDR`, plus one
  for each `sourceCIDRs` CIDR. A VIP with `sourceCIDRs: ["0.0.0.0/0"]` goes
  into the two default maps instead (`ingress-marks-default-ipv4` and
  `egress-marks-default-ipv4`, `type ipv4_addr : mark`). Conntrack matching
  ensures both directions of a connection are marked.
- **Mark rules** — One rule per map and chain sets the mark bits from the map
  and keeps the others, then accepts the packet:
  `meta mark set meta mark & <inverted_mask> | (<key> map @<map>) accept`. A
  packet whose key the map lacks skips the rule, so the first map that holds
  the key wins: ingress before egress, and the specific maps before the default
  ones. This form of rule needs the patched nft builds of the agent image and
  Linux 6.13 or newer. Earlier versions of the agent dispatched verdict maps to
  a chain per VIP (`mark-<fwmark>`); the agent replaces those rules, maps and
  chains on its first run.
- **Reply marking** — Locally generated replies, such as ICMP echo replies from
  the node itself, never pass the prerouting hook. The `mangle-output` chain
  (`type route hook output priority mangle`) looks up the ingress maps with
  `ip saddr . ip daddr` (default maps: `ip saddr`) and marks them, and its
  `route` type makes the kernel route the packet again after the mark changes,
  so the reply leaves through the VIP's table.
- **SNAT** — Every VipAddress with a firewall mark gets an entry in the
  `snat-addresses` map (`type mark . ifname : ipv4_addr`) that pairs its mark
  and interface with the virtual IP. One rule in the `nat-postrouting` chain
  (`type nat hook postrouting priority 90`, before the usual source NAT at 100)
  applies it:
  `snat to meta mark & <mask> . oifname map @snat-addresses fully-random`. A
  new connection whose first packet carries a VIP's mark and leaves through
  that VIP's interface, which in practice is marked egress traffic from the
  Service's endpoint pods, is source-NATted to the virtual IP.

The agent processes changes in a specific order to ensure dependencies are
satisfied:

1. **Gateways**: installs the policy rules and fallbacks of the applied
   VipGateways
2. **Removals**: stale mark map entries → VIP policy rules and route tables →
   SNAT entries → addresses
3. **Additions**: addresses → the `gateway-destinations` set → mark map entries
   and their rules → the mark chains of earlier versions, which no map
   references any more → SNAT entries → the `cluster-networks` set → VIP policy
   rules and routes
4. **Gateway routes**: WireGuard allowed IPs → removal of stale gateway rules
   and routes → gateway pod routes

A gateway's rule exists before its destination stops being marked, and a
removed destination is marked again before its rule goes. There are no separate
deletion handlers: when a VipAddress, VipGateway or VipRoute is removed, the
next run removes its mark map entries, SNAT entry, policy rules and routes in
the order above.

## Helm Values

Key configurable values (see
[values.yaml](deploy/charts/netwrangler/values.yaml) for the full reference):

| Value                                  | Default                         | Description                                  |
| -------------------------------------- | ------------------------------- | -------------------------------------------- |
| `controller.replicaCount`              | `1`                             | Number of controller replicas                |
| `controller.debug`                     | `false`                         | Enable debug mode                            |
| `controller.logLevel`                  | `info`                          | `debug`, `info`, `warn`, `error`             |
| `controller.image.repository`          | `jochen/netwrangler-controller` | Controller image                             |
| `controller.image.tag`                 | Chart appVersion                | Image tag                                    |
| `controller.image.pullPolicy`          | `IfNotPresent`                  | Image pull policy                            |
| `controller.resources.requests.cpu`    | `10m`                           | CPU request                                  |
| `controller.resources.requests.memory` | `64Mi`                          | Memory request                               |
| `controller.resources.limits.cpu`      | `100m`                          | CPU limit                                    |
| `controller.resources.limits.memory`   | `128Mi`                         | Memory limit                                 |
| `controller.nodeSelector`              | Linux control-plane nodes       | Nodes the controller may run on              |
| `agent.enabled`                        | `true`                          | Deploy the agent DaemonSet                   |
| `agent.debug`                          | `false`                         | Enable debug mode                            |
| `agent.retry.count`                    | `3`                             | Attempts per external tool call (at least 1) |
| `agent.retry.delaySeconds`             | `2`                             | Seconds between attempts (at least 0)        |
| `agent.nftVersion`                     | `""` (latest)                   | Bundled nft build to run (see below)         |
| `agent.image.repository`               | `jochen/netwrangler-agent`      | Agent image                                  |
| `agent.image.tag`                      | Chart appVersion                | Image tag                                    |
| `agent.image.pullPolicy`               | `IfNotPresent`                  | Image pull policy                            |
| `agent.resources.requests.cpu`         | `10m`                           | CPU request                                  |
| `agent.resources.requests.memory`      | `64Mi`                          | Memory request                               |
| `agent.resources.limits.cpu`           | `100m`                          | CPU limit                                    |
| `agent.resources.limits.memory`        | `128Mi`                         | Memory limit                                 |
| `agent.serviceAccount.create`          | `true`                          | Create the agent's account                   |
| `agent.serviceAccount.name`            | `""`                            | Override the agent's account                 |
| `agent.serviceAccount.automount`       | `true`                          | Mount the agent's account token              |
| `agent.serviceAccount.annotations`     | `{}`                            | Annotations on the agent's account           |
| `serviceAccount.create`                | `true`                          | Create the controller's account              |
| `serviceAccount.name`                  | `""`                            | Override the controller's account            |
| `serviceAccount.automount`             | `true`                          | Mount the controller's account token         |
| `serviceAccount.annotations`           | `{}`                            | Annotations on the controller's account      |
| `imagePullSecrets`                     | `[]`                            | Pull secrets for both images                 |
| `podAnnotations`                       | `{}`                            | Annotations on the controller and agent pods |
| `podLabels`                            | `{}`                            | Labels on the controller and agent pods      |

The agent uses its own ServiceAccount, whose ClusterRole can only read the
[netwrangler] resources; write access stays with the controller's account. The
agent runs with `NET_ADMIN` and `NET_RAW` capabilities and `hostNetwork: true`.
Both the agent and the controller run as non-root (`runAsUser: 1000`).

The agent image bundles static builds of `nft`, `ip`, `wg` and `arping` in
`/usr/local/sbin`. A host whose `nft` disagrees with the agent's, for example
one that cannot print the ruleset the agent wrote, can be matched by running
another bundled nft build.

The image carries every nft release from 1.1.2 on, each as `nft-<version>` and
linked against the libnftnl that release requires: 1.1.2, 1.1.3, 1.1.4, 1.1.5,
1.1.6 and 1.1.7. 1.1.2 is the first release that can combine two runtime values
in one bitwise operation, which needs Linux 6.13 or newer to run. Each build
carries a patch from [`patches/nftables`](patches/nftables) that also accepts a
map lookup in parentheses as an operand of `&`, `|` and `^`, as in
`meta mark set meta mark & 0xffffff80 | (ip daddr . ip saddr map @marks)`. No
nftables release supports this yet. The agent runs the latest build unless
`agent.nftVersion` names another, which becomes the `NETWRANGLER_NFT_VERSION`
environment variable:

```yaml
agent:
  nftVersion: 1.1.3
```

A version the image does not carry fails the agent's first nft call with an
error that lists the bundled versions. The `NFTABLES_BUILDS` argument in
[`Dockerfile.agent`](Dockerfile.agent) lists the builds.

From 1.1.6 on, `nft list` warns that a table "was created by a newer version of
nftables" when the nft that created it is newer than its own. To keep a host's
nft quiet, set `agent.nftVersion` to the host's version, or to the newest
bundled one below it.

[`scripts/check-host-versions.sh`](scripts/check-host-versions.sh) records a
node's versions of these tools, their packages and libraries, and the kernel
modules the agent's ruleset uses, one `name: value` line each, so two nodes or
two points in time can be compared with `diff`. It needs only POSIX `sh`:

```sh
sh check-host-versions.sh > "$(hostname).versions"
```

`controller.nodeSelector` defaults to `kubernetes.io/os: linux` and
`node-role.kubernetes.io/control-plane: ""`. Helm merges an override into these
maps instead of replacing them, so to run the controller on worker nodes, set
the control-plane key to `null`. The default tolerations let the controller run
on tainted control-plane nodes.

`agent.retry.count` and `agent.retry.delaySeconds` become the agent's
`NETWRANGLER_RETRY_COUNT` and `NETWRANGLER_RETRY_DELAY` environment variables.
When an agent hook fails, for example because a call to `nft`, `ip`, `wg` or
`arping` still fails after the last attempt, the agent runs the whole
reconciliation once more: each run is complete and idempotent, so a run that
something changed under, such as another process deleting the agent's nftables
table between two commands, succeeds on the second pass. If that pass fails
too, the agent stops its container by signalling the process that supervises
it. The kubelet then restarts the pod, so the failure shows as a restart
instead of a hook that keeps running with its changes half applied.

## Development

### Prerequisites

- **Crystal** >= 1.21.0, < 1.22
- **Ruby** (for Rake build system and integration tests)
- **Bundler** (`gem install bundler`, then `bundle install`)
- **Docker** with buildx (for container image builds)
- **kind** (for local Kubernetes cluster)
- **Helm** and **Helmfile** (for deployment)

### Building

```sh
# Install Crystal dependencies
rake deps

# Build all targets for the preferred debug profile of this host
rake debug

# Build every profile this host supports, in both modes
rake build

# Build one specific profile and mode
rake build:debug:darwin-arm64-system-dynamic

# List the build profiles available on this host
rake profiles
```

Build profiles are configured per OS in `.project.yaml` under
`crystal.profiles`, named `<ostype>-<arch>-<libc>-<linkage>`. Only the profiles
matching the current host are offered as tasks.

### Testing

**Unit tests** (Crystal specs):

```sh
rake spec              # All unit tests
rake controller:spec   # Controller unit tests only
rake agent:spec        # Agent unit tests only
rake util:spec         # Shared utility unit tests only
```

Every `spec` and `test` task takes the same two optional arguments, `files` and
`pattern` — quote the whole argument in zsh, or the brackets glob:

```sh
# Compile only these spec paths (space-separated for more than one)
rake 'spec[spec/util]'
rake 'spec[spec/util spec/agent]'

# Run only examples whose full name contains the pattern
rake 'spec[,IPv4Network]'

# Both: compile only spec/util, run only its IPv4Network examples
rake 'spec[spec/util,IPv4Network]'

# Same arguments on a component task, confined to its own spec directory
rake 'agent:spec[spec/agent/nftables_updater_spec.cr]'
```

`files` narrows what compiles, `pattern` narrows what runs.

`util` is a _virtual_ component: it is declared under `crystal.components` in
`.project.yaml` with `virtual: true`, so it takes part in the unit-test and
coverage tasks without a shards target or a binary of its own.

**Integration tests** (Ruby/RSpec against a kind cluster):

```sh
rake test                # Build, deploy, and run all integration tests
rake controller:test     # Controller integration tests only
rake agent:test          # Agent integration tests only
```

The `files` and `pattern` arguments work here too. `files` additionally accepts
rspec's single-example addressing, `<file>:<line>` and `<file>[1:2]`:

```sh
rake 'test[test/agent/agent_spec.rb]'
rake 'test[test/agent/agent_spec.rb:42]'
rake 'test[,announces the VIP]'
```

`rake test` always delegates to the component tasks, splitting `files` by the
component that owns each path, so the build-and-deploy steps hooked onto
`<component>:test` still run — narrowing the selection never tests a stale
deployment. A path under `test/` that no component owns (`test/support/…`) is
an error rather than a silent no-op.

Integration tests require a running kind cluster (see below).

### Local Development with kind

```sh
# Create a 3-node kind cluster
rake kind:start

# Build images, load into kind, and deploy via Helmfile
rake kind:deploy

# Rebuild and restart after code changes
rake kind:restart

# Delete the cluster
rake kind:delete
```

### Rake Tasks

| Task                                                       | Description                                                      |
| ---------------------------------------------------------- | ---------------------------------------------------------------- |
| `rake setup`                                               | Set up the project (install dependencies)                        |
| `rake deps`                                                | Install Crystal dependencies                                     |
| `rake debug`                                               | Build the preferred debug profile for this host                  |
| `rake build`                                               | Build every host profile, debug and release                      |
| `rake build:debug`, `rake build:release`                   | Build every debug or release profile for this host               |
| `rake profiles`                                            | List the build profiles available on this host                   |
| `rake dist:package`                                        | Package every built release profile into `dist/`                 |
| `rake lint`                                                | Run every linter                                                 |
| `rake lint:crystal`                                        | Run Ameba over the Crystal sources                               |
| `rake spec`                                                | Run all unit tests                                               |
| `rake cover`                                               | Run all unit tests with coverage                                 |
| `rake test`                                                | Run all integration tests                                        |
| `rake <component>:spec`                                    | Run one component's unit tests (`controller`, `agent`, `util`)   |
| `rake <component>:cover`                                   | Run one component's unit tests with coverage                     |
| `rake <component>:test`                                    | Build, deploy, and run one component's integration tests         |
| `rake <component>:run`                                     | Run the controller or agent locally in debug mode                |
| `rake licenses:update`                                     | Fetch the bundled software's license files into licenses/        |
| `rake docker:build`                                        | Build every image for all platforms (build cache only)           |
| `rake docker:load`                                         | Build every image for this host and load it into the daemon      |
| `rake docker:push`                                         | Build and push every multi-arch image                            |
| `rake <component>:docker:build`, `:load`, `:push`          | The same for one image                                           |
| `rake <component>:docker:run`                              | Run one image in a container                                     |
| `rake kind:start`                                          | Create the 3-node kind cluster                                   |
| `rake kind:deploy`                                         | Deploy to the kind cluster                                       |
| `rake kind:redeploy`                                       | Deploy and restart every workload so reloaded images take effect |
| `rake kind:restart`                                        | Redeploy and wait for every rollout                              |
| `rake kind:sync`                                           | Load every image and sync the release to kind                    |
| `rake kind:upload`                                         | Load every image into kind                                       |
| `rake <component>:kind:upload`                             | Load one image into kind                                         |
| `rake kind:kubeconfig`                                     | Export the kind cluster's kubeconfig                             |
| `rake kind:crds`                                           | Apply the CRDs to the kind cluster                               |
| `rake kind:delete`                                         | Delete the kind cluster                                          |
| `rake helm:package`                                        | Package the Helm chart into `dist/`                              |
| `rake helm:push`                                           | Push the Helm chart to the OCI registry                          |
| `rake helm:push:metadata`                                  | Push the Artifact Hub metadata to the OCI registry               |
| `rake helm:netwrangler:package`, `:push`, `:push:metadata` | The same for the `netwrangler` chart by name                     |
| `rake version:lint`                                        | Report manifests whose version differs from the project's        |
| `rake version:update`                                      | Write the project version into every manifest                    |
| `rake changelog`                                           | Update `CHANGELOG.md` for the manifest's version                 |
| `rake release[yes]`                                        | Cut a release: branch from `main`, tag, bump dev versions        |
| `rake notary:setup`                                        | Store the notarytool keychain profile                            |
| `rake clean`, `rake clobber`                               | Remove temporary or all generated files                          |

### Project Structure

```text
src/
  controller/          # Controller: allocation logic, shell-operator hook
  agent/               # Agent: address, routes, and nftables updaters
  model/               # Data models for Kubernetes resources
  util/                # Shared utilities (binding context, commands)
spec/                  # Crystal unit tests
test/                  # Ruby integration tests (RSpec)
scripts/               # check-host-versions.sh for a node's tool versions
patches/nftables/      # Patches to each bundled nft release
licenses/              # License files of the bundled software (rake licenses:update)
deploy/
  charts/              # Helm chart with CRDs and templates
  kind-config.yaml     # kind cluster configuration
  helmfile.yaml.gotmpl # Helmfile for multi-environment deployment
```

## Bundled Software

The agent and controller images bundle third-party software, each under its own
license. The Dockerfiles build the network tools, shell-operator and the
[netwrangler] binaries from the source releases of their projects; the patches
to nftables are in [`patches/nftables`](patches/nftables). Versions without a
number come from the Alpine packages of the build images, which move with those
images.

Each image carries the license files of what it contains in
`/usr/share/licenses/<software>/`, and [netwrangler]'s own in
`/usr/share/licenses/netwrangler/`. They come from [`licenses/`](licenses),
which `rake licenses:update` fills from the source releases of the bundled
versions, so the image builds download no license files. shell-operator's
directory holds those of Go and of every Go module its binary links, in
`modules/<module path>/`. Two of those modules are under MPL-2.0; their source
is on the Go module proxy, `https://proxy.golang.org/<module path>/@v/`.

| Software                                                         | Version                    | Where                                                | License                                         |
| ---------------------------------------------------------------- | -------------------------- | ---------------------------------------------------- | ----------------------------------------------- |
| [BusyBox](https://busybox.net/)                                  | 1.37.0                     | base image `busybox:1.37.0-uclibc`, with uClibc-ng   | GPL-2.0-only; uClibc-ng LGPL-2.1                |
| [shell-operator](https://github.com/flant/shell-operator)        | v1.14.2                    | `/shell-operator`, built with Go 1.24                | Apache-2.0; Go modules under their own licenses |
| [Crystal](https://crystal-lang.org/) standard library            | 1.21.0                     | compiled into the [netwrangler] binaries in `/hooks` | Apache-2.0 WITH Swift-exception                 |
| [Boehm GC](https://github.com/bdwgc/bdwgc)                       | from the Crystal image     | linked into the [netwrangler] binaries               | Boehm-GC (MIT-style)                            |
| [PCRE2](https://github.com/PCRE2Project/pcre2)                   | Alpine package             | linked into the [netwrangler] binaries               | BSD-3-Clause WITH PCRE2-exception               |
| [nftables](https://netfilter.org/projects/nftables/)             | 1.1.2 to 1.1.7, patched    | `/usr/local/sbin/nft-<version>`                      | GPL-2.0-only, some files GPL-2.0-or-later       |
| [libnftnl](https://netfilter.org/projects/libnftnl/)             | 1.2.9, 1.3.0, 1.3.1, 1.3.2 | linked into `nft`                                    | GPL-2.0-or-later                                |
| mini-gmp, part of [GMP](https://gmplib.org/)                     | shipped with nftables      | linked into `nft`                                    | LGPL-3.0-or-later OR GPL-2.0-or-later           |
| [Jansson](https://github.com/akheron/jansson)                    | Alpine 3.22 package        | linked into `nft`                                    | MIT                                             |
| [libmnl](https://netfilter.org/projects/libmnl/)                 | Alpine 3.22 package        | linked into `nft` and `ip`                           | LGPL-2.1-or-later                               |
| [iproute2](https://wiki.linuxfoundation.org/networking/iproute2) | 6.19.0                     | `/usr/local/sbin/ip`                                 | GPL-2.0-or-later                                |
| [wireguard-tools](https://www.wireguard.com/)                    | v1.0.20250521              | `/usr/local/sbin/wg`                                 | GPL-2.0-only, some files also MIT               |
| [iputils](https://github.com/iputils/iputils)                    | 20250605                   | `/usr/local/sbin/arping`                             | GPL-2.0-or-later (arping)                       |
| [musl](https://musl.libc.org/)                                   | Alpine packages            | C library linked into every binary but BusyBox       | MIT                                             |

## License

MIT License, copyright (c) 2026 Jochen Seeber. See [LICENSE.txt](LICENSE.txt)
for the full text.

The patches in [`patches/nftables`](patches/nftables) change nftables source
files and are under the licenses of those files, not under the MIT License:
GPL-2.0-only, and GPL-2.0-or-later for `src/parser_json.c`. See
[`patches/LICENSE.txt`](patches/LICENSE.txt).

[netwrangler]: https://github.com/jochenseeber/netwrangler
