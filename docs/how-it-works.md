# How it works

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

## Controller

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

## Gateway Routing

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

1. Installs, for each VipGateway it applies (see the refusal rules in
   [Configuration](configuration.md#precedence-over-egress-marking)), the
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
`to` rules.

### WireGuard

A gateway pod on another node may be reached through a WireGuard interface. The
agent treats the device `ip route get <podIP>` returns as WireGuard when
`ip --json link show type wireguard` lists it. WireGuard only sends traffic to
a destination that a peer lists in its allowed IPs, so the agent adds the
gateway's `destinationCIDR` to the allowed IPs of the peer whose allowed IPs
contain the pod IP, and removes it from any other peer on that interface.
Without such a peer it logs a warning and changes nothing.

The agent records the destinations it added in
`/tmp/shell-operator/wireguard-managed.json`. When one is no longer wanted, it
removes it from every peer on every WireGuard interface. Allowed IPs it did not
add stay as they are.

## Agent

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
- **Mark chains** — Every VIP with a firewall mark gets a regular chain
  `netwrangler-mark-<mark>` in the `netwrangler-ipv4` table, `<mark>` its mark
  in eight lower-case hex digits. Its one rule sets the mark bits and keeps the
  others, then accepts the packet:
  `meta mark set meta mark & <inverted_mask> | <mark> accept`.
- **nftables mark maps** — Manages four verdict maps in the `netwrangler-ipv4`
  table that send a packet to its VIP's mark chain
  (`goto netwrangler-mark-<mark>`), used from the base chains
  `netwrangler-filter-prerouting` (prerouting hook) and
  `netwrangler-mangle-output` (output hook, for locally generated replies). Two
  specific maps (`type ipv4_addr . ipv4_addr : verdict; flags interval`) pair a
  target IP with a network CIDR: `netwrangler-ingress-marks` (keyed
  `ct original ip daddr . ct original ip saddr`) and `netwrangler-egress-marks`
  (keyed `ct original ip saddr . ct original ip daddr`, only when
  `egressEnabled` is true). Each VIP gets an entry for the network of its
  `virtualCIDR`, plus one for each `sourceCIDRs` CIDR. A VIP with
  `sourceCIDRs: ["0.0.0.0/0"]` goes into the two default maps instead
  (`netwrangler-ingress-marks-default` and `netwrangler-egress-marks-default`,
  `type ipv4_addr : verdict`). Conntrack matching ensures both directions of a
  connection are marked.
- **Mark rules** — One rule per map and chain looks the map up:
  `<key> vmap @<map>`. A packet whose key the map lacks falls through to the
  next rule, and one whose key it holds goes to the mark chain, which accepts
  it, so the first map that holds the key wins: ingress before egress, and the
  specific maps before the default ones.
- **Reply marking** — Locally generated replies, such as ICMP echo replies from
  the node itself, never pass the prerouting hook. The
  `netwrangler-mangle-output` chain (`type route hook output priority mangle`)
  looks up the ingress maps with `ip saddr . ip daddr vmap` (default maps:
  `ip saddr vmap`) and marks them, and its `route` type makes the kernel route
  the packet again after the mark changes, so the reply leaves through the
  VIP's table.
- **SNAT** — Every VipAddress with a firewall mark gets an entry in the
  `netwrangler-snat-addresses` map (`type mark . ifname : ipv4_addr`) that
  pairs its mark and interface with the virtual IP. One rule in the
  `netwrangler-nat-postrouting` chain (`type nat hook postrouting priority 90`,
  before the usual source NAT at 100) applies it:
  `snat to meta mark & <mask> . oifname map @netwrangler-snat-addresses fully-random`.
  A new connection whose first packet carries a VIP's mark and leaves through
  that VIP's interface, which in practice is marked egress traffic from the
  Service's endpoint pods, is source-NATted to the virtual IP.

The agent processes changes in a specific order to ensure dependencies are
satisfied:

1. **Gateways**: installs the policy rules and fallbacks of the applied
   VipGateways
2. **Removals**: stale mark map entries → VIP policy rules and route tables →
   SNAT entries → addresses
3. **Additions**: addresses → the `netwrangler-gateway-destinations` set → mark
   chains → mark map entries and their rules → deletion of the mark chains no
   entry goes to → SNAT entries → the `netwrangler-cluster-networks` set → VIP
   policy rules and routes
4. **Gateway routes**: WireGuard allowed IPs → removal of stale gateway rules
   and routes → gateway pod routes

A gateway's rule exists before its destination stops being marked, and a
removed destination is marked again before its rule goes. There are no separate
deletion handlers: when a VipAddress, VipGateway or VipRoute is removed, the
next run removes its mark map entries, mark chain, SNAT entry, policy rules and
routes in the order above. A mark chain exists before a map entry goes to it,
and goes only once no entry goes to it.

On an upgrade from an agent whose mark maps mapped to marks (`: mark`), the
first run finds such a map, deletes the whole `netwrangler-ipv4` table and
rebuilds it in the same run. Between the deletion and the rebuild, which takes
a moment, the node's VIP traffic is not marked and not source-NATted to the
VIPs. The old table's mark rules use a bitwise operation on two runtime values,
which nft before 1.1.2 cannot list, so the agent looks only at the map. nft
1.0.9 deletes such a table; nft 1.0.6 crashes on any set or map that nft 1.1.3
declared with a plain type, so on a node with nft 1.0.6 delete such a table
with a newer nft (`nft delete table ip netwrangler-ipv4`), or the agent stops
its container on every start.

The sets and maps above are written with their plain types. Through a node nft
of 1.1.2 or newer the agent declares them with `typeof` instead
(`typeof ip daddr . ip saddr : verdict`, `typeof meta mark . oifname : ip saddr`
and so on), which declares the same types: nft 1.1.3 and newer record a plain
type in a form that nft 1.0.6 crashes on, and every nft 1.0.6 command that
reads sets on the node then fails, kube-proxy's included. On a node whose nft
is 1.1.3 or newer, the first run after an upgrade from an agent that declared
plain types finds a set or map listed with one, deletes the whole table and
rebuilds it in the same run, with the same short gap in marking and source
NAT. On nft 1.1.2, which no tested distribution ships, the agent declares new
sets and maps with `typeof` but leaves an existing table as it is; delete
such a table by hand (`nft delete table ip netwrangler-ipv4`) and the next run
rebuilds it.

### Node tools

The image has no `nft`, `ip`, `wg` or `arping`. `/usr/local/sbin/` holds
symlinks to `/usr/libexec/node-tool`, which refuses calls the agent does not
make, enters the node's mount namespace through `/hostfs/proc/1/ns/mnt` and
execs the node's tool with only the capability that tool needs. The chart
mounts the node's `/proc` read-only at `/hostfs/proc` and always adds the
capabilities `NET_ADMIN`, `NET_RAW`, `SYS_ADMIN`, `SYS_CHROOT` and `SYS_PTRACE`
to those in `agent.securityContext.capabilities.add`, so a custom security
context cannot leave them out. Two settings break it:

- `allowPrivilegeEscalation: false` in `agent.securityContext` sets
  `no_new_privs`, which stops file capabilities. The wrapper then has none and
  refuses every call with
  `<tool>: cap_sys_admin is not permitted: add it to the container's capabilities and do not set allowPrivilegeEscalation: false`,
  so leave it unset.
- A security module policy that denies `ptrace` of the node's init (process 1)
  from the container stops the wrapper from opening `/hostfs/proc/1/ns/mnt`;
  the wrapper then reports `Permission denied` with the hint
  `(AppArmor or SELinux may deny ptrace of the node's init)`. containerd's
  default AppArmor profile allows `ptrace` only between processes under that
  same profile, so the chart runs the agent unconfined by AppArmor:

  ```yaml
  agent:
    securityContext:
      appArmorProfile:
        type: Unconfined
  ```

  `appArmorProfile` needs Kubernetes 1.30 or newer. On Kubernetes 1.29, the
  oldest release this chart supports, remove the field and use the annotation
  instead, in `agent.podAnnotations`: the shared `podAnnotations` also go to
  the controller pod, which has no container named `agent`, and the API server
  rejects the annotation there.

  ```yaml
  agent:
    podAnnotations:
      container.apparmor.security.beta.kubernetes.io/agent: unconfined
    securityContext:
      appArmorProfile: null
  ```

  On SELinux nodes, run the agent as the super-privileged container type, which
  may `ptrace` the node's init:

  ```yaml
  agent:
    securityContext:
      seLinuxOptions:
        type: spc_t
  ```

The agent's startup check reports a failing wrapper in the pod's log (see
[Startup check](#startup-check)).

### Startup check

Before every hook the agent checks the kernel. On `--config`, which
shell-operator runs once at startup, it also probes the node's tools through
the wrapper: `nft --version` reports 1.0.6 or newer and `nft -j list chains`
succeeds (a listing without rules and maps, which nft 1.0.6 and 1.0.9 read even
with the previous release's table on the node); `ip --json rule show` succeeds
and prints a JSON array; `arping -V` succeeds and names iputils; and
`wg --version` succeeds when `ip --json link show type wireguard` lists a link.
It logs every failing check at error level with the tool and the reason, then
stops the container, so the pod restarts and its log names the cause.
