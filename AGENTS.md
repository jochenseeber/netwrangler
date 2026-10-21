# netwrangler

MUST read `README.md` first. It is the reference for the architecture, the
custom resources and their fields, allocation, the agent's operation order, the
nftables layout, gateway routing, the protocol 110 tagging, development setup
and the Rake tasks. This file holds only what an agent needs beyond it.

## General

- MUST apply rules for Crystal, Ruby and Visual Studio Code
- Run builds, specs and linters through `rake` (`rake spec`, `rake lint`,
  `rake agent:test`, …), not `crystal spec`, `ameba` or `bundle exec rspec`
  directly. RuboCop has no rake task yet, so run `bundle exec rubocop` for it.

## Key Source Files

- `src/netwrangler_controller.cr`, `src/netwrangler_agent.cr` — entry points
- `src/controller/controller_hook.cr` — controller hook definition and entry
- `src/controller/controller_binding_context.cr` — parses the controller's
  binding context
- `src/controller/ip_allocator.cr` — allocation: distributes IPs across nodes
  by endpoint readiness and load, allocates marks, tables and priorities,
  disables overlapping VipNetworks, builds VipRoutes from VipGateways
- `src/model/` — Kubernetes resource models (Service, EndpointSlice, Pod,
  VipNetwork, VipAddress, VipConfig, VipGateway, VipRoute)
- `src/agent/agent_hook.cr` — agent hook; watches VipAddress, VipNetwork,
  VipConfig, VipRoute and VipGateway, and reconciles the node
- `src/agent/address_updater.cr` — VIP addresses on interfaces, gratuitous ARP
- `src/agent/nft_types.cr` — nftables descriptors (`NftObjectDescriptor`,
  `MarkRuleDescriptor`, `ClusterNetworksRuleDescriptor`) and enums
  (`NftDataType`, `NftMatchField`)
- `src/agent/nftables_updater.cr` — the `netwrangler` table: mark maps and
  their rules, SNAT, `cluster-networks` and `gateway-destinations` sets, and
  the removal of the verdict maps and mark chains of earlier versions
- `src/agent/routes_updater.cr` — policy rules and route tables for VIPs and
  gateways
- `src/agent/gateway_policy.cr` — `GatewayRuleEntry` and `GatewayPolicy`: which
  VipGateways a node applies, and which VIP source networks overlap gateway
  destinations
- `src/agent/wireguard_updater.cr` — WireGuard peer allowed IPs for gateway
  destinations reached through a WireGuard interface
- `src/agent/reported_errors.cr` — remembers logged conflicts across hook runs
  so a persisting one is logged as an error once
- `src/util/binding_context.cr` — agent snapshots (`VipAddressSnapshot`,
  `VipNetworkSnapshot`, `VipAddressConfigSnapshot`, `VipRouteSnapshot`,
  `VipGatewaySnapshot`)
- `src/util/command.cr` — external tool runner, the absolute tool paths, and
  `Util.nft`, the selected nft build, resolved on first use so a missing build
  fails a hook instead of the process at startup
- `src/util/nft_builds.cr`, `src/util/tool_version.cr` — the bundled
  `nft-<version>` builds and the `NETWRANGLER_NFT_VERSION` selection (latest by
  default)
- `src/util/kernel_version.cr` — the running kernel's release from
  `/proc/sys/kernel/osrelease`; the agent entry point refuses a kernel older
  than `MINIMUM_KERNEL` (6.13) before every hook, `--config` included
- `src/util/retry_policy.cr` — retries for external tools
- `src/util/container_terminator.cr` — stops the container on a failed hook
- `src/util/ipv4_address.cr`, `src/util/ipv4_network.cr` — typed IPv4 addresses
  and networks (Crystal has no stdlib `IPAddr`)
- `src/util/qualified_name.cr` — namespace/name pairs
- `deploy/charts/netwrangler/crds/` — CRD definitions
- `scripts/check-host-versions.sh` — POSIX `sh` report of a node's tool,
  package and kernel module versions; nodes have no Ruby, so it is not Ruby
- `rakelib/licenses.rake` (`rake licenses:update`) — fills
  `licenses/<software>/` with the license files of the bundled software, which
  the Dockerfiles copy into `/usr/share/licenses`. It is the project's own
  file; the rest of `rakelib/` comes from the vsrun facets.

## Tests

- When doing several work items in sequence, run the integration tests
  (`rake test`, `rake <component>:test`) only once, after the last of them.
  Each run rebuilds the images, redeploys to kind and takes many minutes; unit
  specs and lint still run per item
- Unit specs live in `spec/agent`, `spec/controller` and `spec/util`; the
  controller fixtures are in `spec/controller/fixtures.cr`
- Integration test helpers are in `test/support/` (`integration_test.rb`,
  `kubectl_helper.rb`, `kind_helper.rb`, `helmfile_helper.rb`, `setup.rb`)
- `kubectl` runs through `docker exec` on the kind control-plane container,
  because Docker Desktop's port proxy to kind fails intermittently under load
- The agent installs pod routes only for VipRoutes whose destination and table
  match a VipGateway it applied, so a test that creates a bare VipRoute must
  also create its VipGateway
- Gateway destinations must not overlap the kind node network, or the agent
  refuses the gateway. The specs use `198.51.100.0/24`, `192.0.2.0/24` and
  `198.19.0.0/24` (agent gateway spec), `198.18.1.0/24` (agent precedence
  spec), `203.0.113.0/24` (controller gateway spec) and `198.18.0.0/24` for a
  foreign rule; no two specs share a destination
- `ip route get <addr>` that hits an `unreachable` route fails with "RTNETLINK
  answers: No route to host", while an address without a matching route fails
  with "Network is unreachable". The tests use this to tell the gateway
  fallback from a missing route.

## Deployment

- After changing a bundled version or adding software to an image, run
  `rake licenses:update` and commit `licenses/`; add the software to the
  README's Bundled Software table, to the image's
  `org.opencontainers.image.licenses` expression, and, for the controller, to
  its `COPY licenses/<software>/` lines. The task reads the versions built from
  source from `Dockerfile.agent`; those from Alpine packages and base images
  are fixed upstream releases in `Licenses::UPSTREAM`. It lists
  shell-operator's Go modules with `go list -deps` in a `golang` container
  whose module cache is a host directory, and fails on a module without a
  license file.
- `.dockerignore` is an allowlist (`*`, then `!` entries): a Dockerfile that
  reads a new path from the build context needs it allowed there, or the build
  fails with the path not found
- `values.schema.json` validates Helm values at install and upgrade time
- When a CRD gains a required field, existing resources lack it. Apply the CRDs
  first, then the controller (it fills the field), and restart the agents last.
  If old resources cannot be deserialized, delete them and let the controller
  recreate them.
- `rake docker:push` must use `docker buildx build --push`: multi-arch
  manifests are not loaded into the local daemon, so a later `docker push`
  fails
- The `oras` CLI rejects absolute file paths unless given
  `--disable-path-validation`
- ArtifactHub OCI metadata uses the media types
  `application/vnd.cncf.artifacthub.config.v1+yaml` (config) and
  `application/vnd.cncf.artifacthub.repository-metadata.layer.v1.yaml` (layer)
- The agent image builds `nft`, `ip`, `wg` and `arping` statically in the
  `nettools-builder` stage, gives them file capabilities with `setcap`, and
  installs them in `/usr/local/sbin/`. `arping` comes from iputils: BusyBox
  `arping` lacks file capabilities and fails as non-root. `arping -U` exits 1
  when no reply comes, which is normal for a gratuitous ARP.
- nft is built once per entry of `NFTABLES_BUILDS` (`<nftables>:<libnftnl>`,
  the libnftnl being that release's `configure.ac` minimum), each libnftnl in
  its own prefix under `/opt/libnftnl`, and installed as `nft-<version>`. The
  builds are stripped (6 MB to 1.3 MB each); adding a release means adding an
  entry and a port of the patches, nothing in the agent changes. Release dates
  are on netfilter.org/news.html: the file listings return 403 and the web view
  of git.netfilter.org sits behind a bot challenge, but cloning
  https://git.netfilter.org/nftables works.
- `patches/nftables/<version>/*.patch` apply to that release's tarball before
  `configure`, and a release without a directory fails the build. The patch
  that allows a map lookup as a bitwise operand is a port per release of a
  patch against nftables master: the concatenation check in `evaluate.c` is an
  `if` up to 1.1.3 and a `switch` from 1.1.4. The tarballs ship a generated
  `parser_bison.c`; the build deletes it and installs `bison`, or make would
  keep the unpatched parser. 1.0.6.1 lacks the two-register bitwise support
  (nftables commit `54bfc38c`, first in 1.1.2) that the patch needs.
- nft 1.1.6 and later store their version and build time in each table they
  create, and `nft list` warns "created by a newer version of nftables" when
  either is newer than its own; equal versions are decided by the build time.
  The builds therefore use a build time of 0 (`MAKE_STAMP=0` for 1.1.6,
  `SOURCE_DATE_EPOCH=0` from 1.1.7), or even a matching bundled build makes a
  distribution's nft warn.
- The runtime image is BusyBox: its applets live in `/bin`, not `/usr/sbin`.

## Shell-operator

- The controller's snapshots wrap objects as `{"object": ...}` (events) or
  `{"objects": [...]}` (synchronization); `ControllerBindingContext` reads both
- All agent bindings share the group `vip_address_agent`. Grouped bindings
  arrive as `"type":"Group"` contexts without `watchEvent` or `filterResult`,
  so per-event handlers would never run: the full reconciliation on every event
  is the agent's only cleanup path, deletions included. Grouped bindings
  receive every snapshot of the group, so their `includeSnapshotsFrom` is
  redundant; an ungrouped binding gets only its own snapshot without it.
- jqFilter field names must match the CRD's exactly (`.spec.networkCIDR`); a
  wrong name yields `null` silently. The controller uses `.spec` as its filter
  and maps fields in the Crystal models.
- Shell-operator logs hook stderr at `info` and splits a backtrace into one
  entry per line. The entry points log failures with `Log.error` as one line. A
  failed agent reconciliation runs once more (`AgentHook.with_attempts`,
  `RECONCILE_ATTEMPTS`), which repairs a table deleted under it; only a second
  failure stops the container through `Util::ContainerTerminator`, so the
  kubelet restarts the pod instead of leaving state half-applied.

## Controller Notes

- Mark, table and priority allocation shares the `@claimed_*` sets across all
  services, and `carry_over_route_allocations` re-allocates an existing
  VipAddress whose values collide
- `per_node_cap` (README § VipConfig) is set on each `NodeInfo`, and
  `collect_service_nodes` builds those per Service, so the cap limits one
  Service's VIPs on a node, not the node's total

## Agent Notes

- `AgentHook#process_vip_addresses` is split into helpers to stay within
  Ameba's complexity limit (`collect_vip_address_state`, `collect_nft_entries`,
  `collect_default_nft_entries`, `collect_specific_nft_entries`,
  `log_gateway_overlaps`, `collect_route_table`, `remove_stale_resources`,
  `add_missing_resources`). `NftDesiredState` carries the mark map entries,
  gateways and SNAT entries between them.
- Stale state is judged against all interfaces at once: VIP policy rules are
  node-wide, so `AgentHook.desired_route_tables` collects the tables of every
  interface (judged per interface, two interfaces removed each other's tables
  on every resync), and `AgentHook.address_targets` empties an interface that
  lost its last VipAddress
- Interfaces must exist and be UP (`ip --json link show`,
  `AgentHook.parse_active_interfaces`) or their VipAddresses are skipped
- `AddressUpdater` adds a VIP with the prefix length of its `virtualCIDR`,
  replaces an address whose prefix differs, and sends the gratuitous ARP only
  when it actually adds the address
- `RouteTableInfo` carries `network_cidr` (derived from `virtualCIDR` with
  `IPv4Network#first_address`) and `source_cidrs`; the VIP table gets a
  connected route for the network and routes via the gateway for each source
  network
- `RoutesUpdater` finds its gateway tables through `discover_destination_rules`
  (tagged `to` rules with or without the fwmark selector), so stale gateway
  routes go even when no route is desired
- The agent reads and writes nftables only through `nft -j` and policy rules
  only through `ip --json rule show`; no code parses their text output.
  `NftJson` holds the shared helpers, and the rule descriptors
  (`MarkRuleDescriptor`, `ClusterNetworksRuleDescriptor`, `SnatRuleDescriptor`)
  build each rule's `expr` as `nft -j list` prints it. `ensure_rule` compares
  after `NftJson.normalize`: nft 1.1.2 lists a single statement flag as a
  string (`"fully-random"`), 1.1.7 as a list, and both take the list.
- `NftablesUpdater#ensure_nft_object` compares a listed object with its
  descriptor (`NftObjectDescriptor#matches?`: type, value type, flags,
  auto-merge, not the comment) and flushes and recreates one that differs,
  since nftables cannot change a map's type in place, nor delete a map a rule
  references; `add_marks` therefore deletes a map's old `vmap` rules before
  recreating it, and `remove_legacy_mark_chains` runs after all maps, once no
  verdict map element references the chains.
- Mark maps and mark rules go through `nft -j`: each map element is a pair of
  key and mark, and a rule's `expr` compares as `JSON::Any`, which ignores key
  order. `MarkRuleDescriptor#expr` builds a rule exactly as `nft -j list`
  prints it (`spec/agent/nft_types_spec.cr` holds listed fixtures), and
  `ensure_rule` replaces a differing rule by handle, which keeps its position.
  An element key spells a network the way nft lists it: no host bits, and a /32
  as a plain address, or every resync would rewrite it.
- The mark rules `accept`, so their order decides which map wins: the agent
  adds them in the order of the `add_marks` calls, and a miss skips the whole
  rule, `accept` included.
- The `gateway-destinations` and `cluster-networks` sets are flushed and
  refilled in one `nft` transaction, so they are never briefly empty
- WireGuard: when `resolve_pod_route` returns a `dev` that answers `wg show`,
  the destination is added to the allowed IPs of the peer whose allowed IPs
  contain the pod IP
- `ip --json route get` resolves an address of the node itself as
  `"type": "local"` through `lo`, without a gateway; a route via that address
  and `dev lo` fails with "Nexthop has invalid gateway". `AgentHook#run`
  therefore resolves the VipRoutes before `add_gateways`, and
  `GatewayPolicy.local_gateways` takes a gateway with a local pod out of the
  routed gateways, so `remove_stale_gateway_routes` clears its rule and table
  on that node.
- Integration specs reach the agent container with `kubectl exec`
  (`agent_exec`, `wg_exec`, `agent_shell!`). They retry an exec that cannot
  reach a restarting container, and `agent_shell!` raises when the command
  keeps failing; a spec that ignores an exec result can lose its setup.

## Tool Gotchas

### iproute2

- `ip --json route show` names the preferred source `"prefsrc"`, not `"src"`
- `ip --json route show table <id> ...` exits 255 when the table does not
  exist; allow 255 in `allowed_exit_codes`
- `ip --json rule show` leaves out what has its default: `fwmask` for a full
  mask, `dstlen` for a host destination, `protocol` for an untagged rule; an
  inverted rule carries `"not": null`, and `table` and `protocol` are strings.
  It ignores a `protocol` filter; `ip rule del … protocol 110` deletes only a
  tagged rule. `ip route replace` without `proto` resets a route's tag.
- The kernel treats metric 0 in a route delete as any metric, so pod routes are
  deleted as `ip route del unicast ...` to spare the `unreachable` fallback

### nftables

- `ct original daddr` needs the family: `ct original ip daddr`
- Map element values cannot carry `mark/mask`; apply the mask in the rule
- A map lookup as `|` operand needs parentheses, the patched nft builds and
  Linux 6.13: `meta mark & <inverted mask> | (<key> map @<map>)`. An unpatched
  nft lists such a rule without the parentheses, which does not load back,
  while its `-j` output matches the patched one.
- `add element` with an existing key and another value fails with "File
  exists"; delete and add the element in one `nft` invocation
- Interval maps reject overlapping entries
- `nft -j` lists a set or interval map element as `{"prefix": {"addr", "len"}}`
  for a network and as a plain address for a /32; a concatenated key as
  `{"concat": [...]}`, with a mark as a number
- `insert rule` adds a rule at the top of a chain (`add rule` at the end); the
  `cluster-networks` exclusion relies on it
- A data map keyed `mark . ifname` works with a masked key:
  `snat to meta mark & <mask> . oifname map @snat-addresses fully-random`.
  Priority 90 shows as `srcnat - 10` and runs before the standard srcnat chains
  at 100.
- Locally generated replies (such as ICMP echo replies) skip PREROUTING, and
  `fwmark_reflect` is 0 by default, so the `mangle-output` chain
  (`type route hook output`) marks them; `type route` makes the kernel re-route
  after the mark changes

### Crystal and linters

- `~` on an `Int32` mask goes negative and `Int32#to_u32` raises on negative
  values; firewall mark masks are `UInt32` throughout
- Ameba's `Style/NegatedConditionsInUnless` flags `unless` with `!` or `!=`
  inside; rewrite as `if` with De Morgan (`unless a && !b` → `if !a || b`)
- RuboCop `Exclude` patterns with `**` skip dot-directories (`File.fnmatch?`
  needs `FNM_DOTMATCH`); list `.vscode/Gemfile` next to `**/Gemfile`

### Kubernetes

- Label and annotation keys allow one `/`; `netwrangler.dev/gateway/foo` is
  invalid. Use one key with comma-separated values instead.
- `kubectl logs` has no `--field-selector`; find the pod with
  `kubectl get pods --field-selector=spec.nodeName=<node>` first

## Learnings
