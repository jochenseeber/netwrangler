# netwrangler

MUST read `README.md` first, then `INSTALL.md` and the files in `docs/`:
`configuration.md`, `reference.md`, `how-it-works.md`, `development.md` and
`dependencies.md`. They are the reference for the architecture, the custom
resources and their fields, allocation, the agent's operation order, the
nftables layout, gateway routing, the protocol 110 tagging, development setup
and the Rake tasks. This file holds only what an agent needs beyond them.

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
  `MarkRuleDescriptor`, `MarkChainDescriptor`, `ClusterNetworksRuleDescriptor`)
  and enums (`NftDataType`, `NftTypeofExpr`, `NftMatchField`), and
  `Agent::MINIMUM_NFT`, the oldest node nft (1.0.6), `Agent::TYPEOF_NFT`
  (1.1.2), the first one the agent declares sets and maps with `typeof`
  through, and `Agent::TYPEOF_LISTED_NFT` (1.1.3), the first one it migrates a
  table of plain types through
- `src/agent/nftables_updater.cr` — the `netwrangler-ipv4` table: mark maps,
  per-VIP mark chains and the rules that look the maps up, SNAT,
  `netwrangler-cluster-networks` and `netwrangler-gateway-destinations` sets
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
- `src/util/command.cr` — external tool runner and the absolute tool paths
  (`Util::IP`, `WG`, `ARPING`, `NFT`), which are `node-tool` symlinks in
  `/usr/local/sbin`
- `src/privileged_runner.cr`, `src/privileged_runner/` —
  `Netwrangler::PrivilegedRunner`, the `node-tool` shard target behind
  `/usr/libexec/node-tool` (specs in `spec/node-tool/`, named after the
  target): runs the node's `nft`, `ip`, `wg` and `arping` in the node's mount
  namespace
- `src/util/kernel_version.cr` — the running kernel's release from
  `/proc/sys/kernel/osrelease`; the agent entry point refuses a kernel older
  than `MINIMUM_KERNEL` (5.6) before every hook, `--config` included
- `src/util/nft_version.cr` — `Util::NftVersion`, an nft release as
  `nft --version` prints it
- `src/util/tool_runner.cr`, `src/agent/node_requirements.cr` — the startup
  check: `NodeRequirements` probes the node's tools through an injected
  `ToolRunner` (`CommandToolRunner` in production) and returns the
  `RequirementFailure`s; `Agent.check_node_tools` runs it on `--config` only. A
  tool killed by a signal yields exit code 128 plus the signal, as in
  `Util::Command`. The nft probe is `nft -j list chains`, which reads neither
  rules nor maps: `list tables` aborts on nft 1.0.9 with the previous agent's
  table and segfaults on nft 1.0.6 with any set or map that nft 1.1.3 declared
  with a plain type, and the startup check would stop the container before the
  first run deletes the table. `NodeRequirements#nft_version` reads the node's
  nft for every hook run (`Agent.node_nft_version` in the entry point), through
  `Util::Command` with the tools' retry policy, and `AgentHook` passes it to
  `NftablesUpdater`. `--config` reads it only in the startup check:
  `AgentHook.print_config` and `.config_json` are class methods that need no
  hook. `Util::Command` takes an optional `ToolRunner`, through which
  `NftablesUpdater` and `NodeRequirements#nft_version` run their tools in specs
  (`spec/support/fake_tool_runner.cr`); without one it starts the process
  itself.
- `src/util/retry_policy.cr` — retries for external tools
- `src/util/container_terminator.cr` — stops the container on a failed hook
- `src/util/ipv4_address.cr`, `src/util/ipv4_network.cr` — typed IPv4 addresses
  and networks (Crystal has no stdlib `IPAddr`)
- `src/util/qualified_name.cr` — namespace/name pairs
- `deploy/charts/netwrangler/crds/` — CRD definitions
- `scripts/check-host-versions.sh` — POSIX `sh` report of a node's tool,
  package and kernel module versions; nodes have no Ruby, so it is not Ruby
- `rakelib/licenses.rake` (`rake licenses:update`) — fills
  `docs/licenses/<software>/` with the license files of the bundled software,
  which the Dockerfiles copy into `/usr/share/licenses`. It, `demo.rake`,
  `demo/` and `kind_cluster/` are the project's own; `rakelib/facets/` comes
  from the vsrun facets.
- `Rakefile` — `kind:node_tools`, `kind:networks` and `kind:wireguard` (all
  three prerequisites of `kind:restart`), and `demo:clean` as the first
  prerequisite of every `<component>:test`
- `rakelib/kind_cluster/` — `NodeShell` (commands in the kind nodes, `kubectl`
  in the control plane), `DemoNetworks` (`kind:networks`; the interface names
  are checked on every run and repaired), `WireguardMesh` (`kind:wireguard`;
  rebuilt when a node lacks it or a peer's endpoint is stale)
- `rakelib/demo.rake`, `rakelib/demo/` — the demo tasks of
  `docs/development.md`: `Demo::Suite` runs the examples of `Demo::EXAMPLES`,
  `demo:deploy:<example>` too with one example; `Demo::Example#run` applies
  one, waits for its rollout and runs its `Demo::Checks` class into a
  `Demo::Report`; `Demo::Deployment` installs netwrangler for `demo:install`
  (`demo:deploy` is the task that runs the examples) and `Demo::Cleanup`
  removes the demo for `demo:clean`. An exception outside a check (apply,
  rollout, image pull) escapes the `Report`; `Demo::Suite` rescues it per
  example and prints it as a ✗ line

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
- The kind node image has no `wg` and no iputils `arping`, and the agent's
  startup check stops the container without `arping`; `kind:node_tools` (a
  prerequisite of `kind:restart`, run before the redeploy) installs both with
  `apt-get`. A freshly created cluster needs it before the agents can start.
- The demo (`examples/README.md`) runs on the same cluster as the integration
  tests. The tests bring their own VipConfig and VipNetworks, so
  `<component>:test` runs `demo:clean` first; it is a no-op on a cluster
  without the demo or the CRDs. `test/agent/wireguard_spec.rb` uses the demo's
  `wg-demo` mesh rather than its own interface: it adds its pod CIDR to a
  peer's allowed IPs, restores the saved list afterwards and never deletes the
  link (`wg set … allowed-ips` replaces the whole list)
- The `wg-demo` mesh (`kind:wireguard`) gives each node's interface its `eth0`
  address as a /32 (a second `local` entry in the local table, no route) and
  sets `rp_filter` 2 on `wg-demo` and `eth0`. With `rp_filter` on, strict or
  loose, the kernel drops a packet that arrives on an interface without an IPv4
  address unless its source routes back through that interface
  (`TcpExtIPReversePathFilter` in `nstat` counts the drops); the masqueraded
  node addresses route through `eth0`. The answer to a packet sent through the
  mesh comes back on `eth0`. The kind nodes have no `tcpdump`;
  `nft monitor trace` with a `meta nftrace set 1` rule in a scratch table shows
  where a packet ends.
- `kind:wireguard` sets `rp_filter` 2 (loose) on `eth0` of every kind node, so
  the integration tests run with loose reverse-path filtering on `eth0`: an
  asymmetric reply that a node with strict filtering would drop is accepted
  there
- The agent installs pod routes only for VipRoutes whose destination and table
  match a VipGateway it applied, so a test that creates a bare VipRoute must
  also create its VipGateway
- Gateway destinations must not overlap the kind node network, or the agent
  refuses the gateway. The specs use `198.51.100.0/24`, `192.0.2.0/24` and
  `198.19.0.0/24` (agent gateway spec), `198.18.1.0/24` (agent precedence
  spec), `203.0.113.0/24` (controller gateway spec) and `198.18.0.0/24` for a
  foreign rule; no two specs share a destination. The demo uses `10.89.0.0/16`
  for its Docker networks and virtual IPs and `10.90.0.0/16` for its gateway
  destinations
- `ip route get <addr>` that hits an `unreachable` route fails with "RTNETLINK
  answers: No route to host", while an address without a matching route fails
  with "Network is unreachable". The tests use this to tell the gateway
  fallback from a missing route.

## Deployment

- `rake release` writes the version into `.project.yaml`, `shard.yml` and
  `Chart.yaml` (the facets' version writers). `MarkedVersions`
  (`rakelib/marked_versions.rb`, registered in the `Rakefile`) writes the
  latest release into every version between `<!-- release-version -->` and
  `<!-- /release-version -->`, each on a line of its own, in the tracked
  Markdown files: the released version itself, and for the development versions
  after it the highest `v*` tag below them. The release branch and `main` get
  their development commits from the commit before the release, so without that
  `main` would keep the old version. The comments go around a code block, not
  inside it, where they would show. `Netwrangler::VERSION` reads `shard.yml` at
  compile time. Mark a new Markdown mention of the project version, or the
  release leaves it behind; anything else that names it needs a writer of its
  own.
- After changing a bundled version or adding software to an image, run
  `rake licenses:update` and commit `docs/licenses/`; add the software to
  `docs/dependencies.md` (a section under Linked components when the binaries
  link it, otherwise under Bundled in the images, linking the online license),
  to the image's `org.opencontainers.image.licenses` expression, and, for the
  controller, to its `COPY docs/licenses/<software>/` lines. The task reads the
  versions built from source from `Dockerfile.agent`; those from Alpine
  packages and base images are fixed upstream releases in `Licenses::UPSTREAM`.
  It fetches each license file from the project's repository at the release's
  tag, not from a release archive. BusyBox's git server answers 404 and its
  GitHub mirror `mirror/busybox` stops at 1.36.1, so BusyBox's LICENSE comes
  from the mirror's last commit. It lists shell-operator's Go modules with
  `go list -deps` in a `golang` container whose module cache is a host
  directory, and fails on a module without a license file.
- `.dockerignore` is an allowlist (`*`, then `!` entries): a Dockerfile that
  reads a new path from the build context needs it allowed there, or the build
  fails with the path not found
- `values.schema.json` validates Helm values at install and upgrade time
- `deploy/charts/netwrangler/README.md` is a symlink to `README.md`, which
  Artifact Hub shows without the repository, so the README links to other files
  of the repository with absolute
  `https://github.com/jochenseeber/netwrangler/blob/main/...` URLs
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
- The agent image's `crystal-builder` stage builds `node-tool` after the agent,
  in its own
  `shards build node-tool --production --release --static
  --link-flags "-static" -Dgc_none`,
  asserts with `scanelf` that it has no dynamic dependencies, strips it (to
  about 0.72 MB; the agent binary is not stripped) and gives it
  `cap_net_admin,cap_net_raw,cap_sys_admin,cap_sys_chroot,cap_sys_ptrace=p`
  with `setcap`, asserted with `getcap`; the runtime image installs it as
  `/usr/libexec/node-tool` with `nft`, `ip`, `wg` and `arping` symlinks in
  `/usr/local/sbin/` and an empty `/hostfs/proc`. The unit specs run in
  `rake spec`, not in the image build. `arping -U` exits 1 when no reply comes,
  which is normal for a gratuitous ARP.
- node-tool is built without a garbage collector (`-Dgc_none`): the Boehm GC
  starts a marker thread per CPU at startup, which cost 3 to 10 ms of CPU per
  call (10 CPUs) against about 0.35 ms without, and the agent runs the tools
  dozens of times per reconciliation under `cpu: 100m`. Nothing is ever freed,
  so node-tool must stay allocation-light: no reading of large files, no
  growing buffers, no loops that allocate per item of unbounded input. It must
  not rely on finalizers either, which never run. The unit specs still run with
  the GC; only the image build passes `-Dgc_none`. Two threads remain, so
  `unshare(CLONE_FS)` before `setns` stays.
- node-tool is built without PCRE2: it uses no `Regex`. `strings` on the binary
  still shows `LibPCRE2` type-name entries from Crystal's type table, while
  `nm` shows no PCRE2 symbols, so check for linked PCRE2 with `nm`.
- node-tool exits 126 for every failure of its own, unhandled exceptions
  included (`PrivilegedRunner#run` rescues `Exception`), so the agent never
  mistakes one for the tool's exit 1 (`arping -U`, `nft -j list`).
- The chart's `netwrangler.agentSecurityContext` helper always adds node-tool's
  five capabilities to the values' `capabilities.add`, so
  `helm upgrade --reuse-values` with an older release's values keeps them.
  `agent.securityContext.appArmorProfile` (Kubernetes 1.30+) defaults to
  `Unconfined`. The AppArmor annotation for 1.29 goes in
  `agent.podAnnotations`, never the shared `podAnnotations`: the API server
  rejects `container.apparmor.security.beta.kubernetes.io/agent` on the
  controller pod ("container not found").
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
- `per_node_cap` (`docs/configuration.md` § VipConfig) is set on each
  `NodeInfo`, and `collect_service_nodes` builds those per Service, so the cap
  limits one Service's VIPs on a node, not the node's total

## Agent Notes

- `AgentHook#process_vip_addresses` is split into helpers to stay within
  Ameba's complexity limit (`collect_vip_address_state`, `collect_nft_entries`,
  `collect_default_nft_entries`, `collect_specific_nft_entries`,
  `log_gateway_overlaps`, `collect_route_table`, `remove_stale_resources`,
  `add_missing_resources`, `add_mark_resources`). `NftDesiredState` carries the
  mark map entries, gateways and SNAT entries between them, and the marks that
  need a chain.
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
  (`MarkRuleDescriptor`, `MarkChainDescriptor`,
  `ClusterNetworksRuleDescriptor`, `SnatRuleDescriptor`) build each rule's
  `expr` as `nft -j list` prints it. `ensure_rule` compares after
  `NftJson.normalize`: nft 1.0.6 to 1.1.3 list a single statement flag as a
  string (`"fully-random"`), 1.1.7 as a list, and both take the list; and nft
  lists `x & a | b` of constants with b's bits set in a
  (`meta mark & 0xff00ffff | 0x00040000` comes back as `& 0xff04ffff`), which
  `normalize` clears again.
- `spec/agent/fixtures/nft-<version>.json` hold `nft -j list ruleset` of the
  whole table as nft 1.0.6 (Debian 12), 1.0.9 (Ubuntu 24.04) and 1.1.3 (Alpine
  3.22) list it; the descriptor specs compare against each. `nft-1.1.3.json`
  holds the sets and maps declared with plain types (the migration specs),
  `nft-1.1.3-typeof.json` declared with typeof, as the agent declares them
  through nft 1.1.3; nft 1.0.6 and 1.0.9 list a typeof-declared table exactly
  as their fixtures show. To capture another release, apply the agent's
  objects, chains, elements and rules with `nft -j '<document>'` in a container
  with `--cap-add NET_ADMIN` and list the ruleset.
- `NftablesUpdater#ensure_nft_object` compares a listed object with its
  descriptor (`NftObjectDescriptor#matches?`: type, value type, flags,
  auto-merge when listed, not the comment) and flushes and recreates one that
  differs, since nftables cannot change a map's type in place. nftables refuses
  to delete an object a rule uses ("Device or resource busy"), so that
  recreation fails for a map with rules.
- Never create a set or map with a plain `type` through nft 1.1.2 or newer: it
  breaks every older nft on the node, kube-proxy's included. nft 1.1.3 and
  newer store a plain `type` key or value in the set's userdata as a typeof
  record of a value expression (`EXPR_VALUE`), for which nft 1.0.6 has no
  userdata parser: `set_make_key` calls a NULL function pointer, so every nft
  1.0.6 command that loads sets segfaults (`list tables`, kube-proxy's syncs;
  `list chains` still works), and nft 1.1.1's `-j list ruleset` does too. nft
  1.1.1 and older write no such record. A JSON `typeof` declaration of real
  expressions makes nft 1.1.3 write the userdata byte for byte as nft 1.0.6
  does, which every release reads.
- The version gate: `NftObjectDescriptor.typeof?` is true from
  `Agent::TYPEOF_NFT` (1.1.2) on, and `to_json_object` then declares the key as
  `{"typeof": <expr>}` (`ip daddr`, `ip daddr . ip saddr` or
  `meta mark . meta oifname`, `NftTypeofExpr`) and a map's value as
  `{"typeof": {"accept": null}}` (verdict; nft rejects `{"typeof": "verdict"}`)
  or `{"typeof": <ip saddr>}`. Below it the agent declares plain types: nft
  1.1.1 and older reject JSON typeof and write safe userdata. 1.1.2 is untested
  (no distribution ships it); it gets typeof, and should it reject it the hook
  fails loudly, which is preferred to breaking kube-proxy silently. Key and
  value both need typeof: a typeof key with a plain `"map": "verdict"` still
  writes an `EXPR_VALUE` record for the value.
- `NftObjectDescriptor#matches?` accepts both listings of `type`: the plain
  form and `{"typeof": <key expr>}`. nft 1.0.6 and 1.0.9 list a typeof-declared
  object plain (verified: their listings equal their fixtures), nft 1.1.3 lists
  it by its typeof declaration; nft 1.1.1 lists the typeof-declared table
  without crashing, its listing not compared, and 1.1.0 and 1.1.2 are untested.
  `map` matches in both forms too: every release verified lists it as a string
  (`"verdict"`, `"ipv4_addr"`), and a later one listing
  `{"typeof": <value expr>}` must not make the agent recreate a map rules use.
  `previous_agent_table?` therefore looks only at a value listed as a string.
- `AgentHook#run` calls `NftablesUpdater#remove_outdated_table` before anything
  else per context. It deletes the whole table in one transaction, and the run
  rebuilds it, when
  - the previous agent left it (mark maps `: mark`, mark rules
    `meta mark & <mask> | (<key> map @<map>)`, a bitwise or of two registers),
    which is not migrated in place: nft before 1.1.2 aborts on any listing that
    includes those rules (`BUG: invalid bitwise operation`, 1.0.9) and
    `ensure_base_chain` lists a chain first thing. It lists only
    `netwrangler-ingress-marks` (`PREVIOUS_AGENT_TABLE_PROBE`) and checks
    `NftablesUpdater.previous_agent_table?`: a value type other than `verdict`.
  - the node's nft is 1.1.3 or newer (`Agent::TYPEOF_LISTED_NFT`,
    `NftablesUpdater.migrates_plain_types?`) and
    `NftablesUpdater.plain_type_table?` finds a set or map listed with a plain
    type, as the agent declared them through nft 1.1.3 before the gate. The
    migration starts at 1.1.3, not at `TYPEOF_NFT`: it relies on nft listing a
    typeof-declared object by its declaration, which 1.1.3 does and the
    untested 1.1.2 might not, and a 1.1.2 that listed it plain would delete and
    rebuild the table on every run. It lists each of `SETS_AND_MAPS` by name
    (`list map|set ip netwrangler-ipv4 <name>`; the ingress mark map's listing
    serves both checks): with `strace`, nft 1.0.9 and 1.1.3 send no
    `NFT_MSG_GETRULE` for it, while `list table` does; `list maps table` is a
    syntax error on nft 1.0.6 to 1.1.1, and `list sets table` leaves the maps
    out.

  nft 1.0.6 segfaults on every listing or deletion that touches a set or map
  that nft 1.1.3 declared with a plain type, so such a table goes only through
  a newer nft. To reproduce the previous agent's table, create it with Alpine's
  nft in one container and run the older nft in another with
  `--network container:<id>`; the Docker VM's kernel must be 6.13 or newer. The
  stock nft 1.1.3 of `alpine:3.22` refuses the old mark rule, in JSON too
  ("Expression type map not allowed in context").
- Mark maps are verdict maps: each element pairs a key with
  `goto netwrangler-mark-<mark>` (`MarkChainDescriptor`, eight lower-case hex
  digits), a regular chain whose one rule is
  `meta mark set meta mark & <inverted mask> | <mark> accept`, constants only,
  so a stock nft loads it. `add_mark_chains` creates a chain and its rule in
  one transaction before any element goes to it; `remove_mark_chains` deletes
  the chains no element or rule goes to
  (`NftablesUpdater.unreferenced_mark_chains`), after `add_marks`, so a VIP
  whose mark changed loses its old chain in the same run. nftables refuses to
  delete a chain an element still goes to.
- A rule's `expr` compares as `JSON::Any`, which ignores key order.
  `MarkRuleDescriptor#expr` builds a rule exactly as `nft -j list` prints it,
  and `ensure_rule` replaces a differing rule by handle, which keeps its
  position. An element key spells a network the way nft lists it: no host bits,
  and a /32 as a plain address, or every resync would rewrite it.
- The mark rules are `<key> vmap @<map>` and the mark chains `accept`, so the
  rules' order decides which map wins: the agent adds them in the order of the
  `add_marks` calls, and a key the map lacks falls through to the next rule.
- The `netwrangler-gateway-destinations` and `netwrangler-cluster-networks`
  sets are flushed and refilled in one `nft` transaction, so they are never
  briefly empty. `NftablesUpdater.outermost_networks` drops a network inside
  another first: an interval set rejects it without auto-merge, which nft 1.0.6
  and 1.0.9 do not keep with the set.
- WireGuard: when `resolve_pod_route` returns a `dev` that the output of
  `ip --json link show type wireguard` lists, the destination is added to the
  allowed IPs of the peer whose allowed IPs contain the pod IP. The `wg`
  wrapper allows only `wg show <interface> allowed-ips` and
  `wg set ... allowed-ips`, so peers come from the former and the interfaces
  from `ip`.
- `ip --json route get` resolves an address of the node itself as
  `"type": "local"` through `lo`, without a gateway; a route via that address
  and `dev lo` fails with "Nexthop has invalid gateway". `AgentHook#run`
  therefore resolves the VipRoutes before `add_gateways`, and
  `GatewayPolicy.local_gateways` takes a gateway with a local pod out of the
  routed gateways, so `remove_stale_gateway_routes` clears its rule and table
  on that node.
- Integration specs reach the agent container with `kubectl exec`
  (`agent_exec`), which retries an exec that cannot reach a restarting
  container. The agent's `ip`, `nft`, `wg` and `arping` are node-tool and
  refuse what the agent does not call, so test setup runs the node's own tools
  through `kind_exec` (`wg_exec`, `node_shell!`, which raises on failure); a
  spec that ignores a setup result can lose its setup.

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
- A stock nft refuses a map lookup as the operand of `|`
  (`meta mark & <inverted mask> | (<key> map @<map>)`; Linux 6.13 and a patched
  nft run it), so the agent sends a packet through a verdict map to a chain per
  mark instead. A `goto` to a chain that ends in `accept` accepts the packet
  for the base chain, as the old rule's `accept` did.
- `add element` with an existing key and another value fails with "File
  exists"; delete and add the element in one `nft` invocation
- `add map` of an existing map with another type fails with "File exists"
- Interval maps reject overlapping entries
- `nft -j` lists a set or interval map element as `{"prefix": {"addr", "len"}}`
  for a network and as a plain address for a /32; a concatenated key as
  `{"concat": [...]}`, with a mark as a number; a verdict map value as
  `{"goto": {"target": "<chain>"}}`
- nft 1.0.6 to 1.1.3 list no `comment` on maps and sets the agent creates:
  nft's JSON parser drops a set's `comment`, so the userdata holds none (text
  input keeps it). 1.0.6 and 1.0.9 list no `auto-merge` either, 1.1.3 does
- `insert rule` adds a rule at the top of a chain (`add rule` at the end); the
  `netwrangler-cluster-networks` exclusion relies on it
- A data map keyed `mark . ifname` works with a masked key:
  `snat to meta mark & <mask> . oifname map @netwrangler-snat-addresses fully-random`.
  Priority 90 shows as `srcnat - 10` and runs before the standard srcnat chains
  at 100.
- Locally generated replies (such as ICMP echo replies) skip PREROUTING, and
  `fwmark_reflect` is 0 by default, so the `netwrangler-mangle-output` chain
  (`type route hook output`) marks them; `type route` makes the kernel re-route
  after the mark changes

### Crystal and linters

- `~` on an `Int32` mask goes negative and `Int32#to_u32` raises on negative
  values; firewall mark masks are `UInt32` throughout
- Ameba's `Style/NegatedConditionsInUnless` flags `unless` with `!` or `!=`
  inside; rewrite as `if` with De Morgan (`unless a && !b` → `if !a || b`)
- RuboCop `Exclude` patterns with `**` skip dot-directories (`File.fnmatch?`
  needs `FNM_DOTMATCH`); list `.vscode/Gemfile` next to `**/Gemfile`
- The Crystal runtime sets `O_NONBLOCK` on piped standard descriptors before
  `main`, and ignores SIGPIPE. Both belong to state that survives `execve` (the
  open file description, the signal disposition), so a Crystal program that
  execs another must undo them first: node-tool clears `O_NONBLOCK` on fds 0 to
  2 at the start of `PrivilegedRunner#run` and resets SIGPIPE just before
  `execve`. With the flag left on, a tool writing more than a pipe holds (64
  KiB) to a slow reader gets `EAGAIN` and loses output while it exits 0.

### Kubernetes

- Label and annotation keys allow one `/`; `netwrangler.dev/gateway/foo` is
  invalid. Use one key with comma-separated values instead.
- `kubectl logs` has no `--field-selector`; find the pod with
  `kubectl get pods --field-selector=spec.nodeName=<node>` first

## Learnings
