# Installation

## Prerequisites

- Kubernetes cluster (v1.29+)
- Helm 3.8 or newer (Helm 4 works), for `oci://` installs
- Nodes must run Linux on amd64 or arm64 (the agent image bundles statically
  compiled binaries)
- Nodes that run the agent need Linux 5.6 or newer, for nftables sets with
  concatenated interval keys. On an older kernel the agent logs
  `Linux <version> is not supported` and stops its container, so the pod
  restarts and its log names the cause.
- The agent runs the node's own tools, so the nodes must have nftables 1.0.6 or
  newer, iproute2 with JSON output (`ip --json`), and iputils `arping` (BusyBox
  `arping` does not work). Nodes with a WireGuard link also need
  wireguard-tools. At startup the agent checks them (see
  [Startup check](docs/how-it-works.md#startup-check)).
- The agent pod needs `SYS_ADMIN`, `SYS_CHROOT` and `SYS_PTRACE` besides
  `NET_ADMIN` and `NET_RAW`, and the node's `/proc` (see
  [Node tools](docs/how-it-works.md#node-tools)).
- The chart's default `agent.securityContext.appArmorProfile` needs Kubernetes
  1.30 or newer. On 1.29, set `appArmorProfile: null` and put the AppArmor
  annotation in `agent.podAnnotations`. On nodes with SELinux, set the agent's
  SELinux type to `spc_t`. Both are described under
  [Node tools](docs/how-it-works.md#node-tools).

## Installing the chart

Install the Helm chart from the OCI registry:

<!-- release-version -->

```sh
helm install netwrangler \
  oci://registry-1.docker.io/jochen/netwrangler \
  --version 1.0.0 \
  --namespace netwrangler \
  --create-namespace
```

<!-- /release-version -->

**Note:** Helm does not update CRDs on chart upgrades. When CRD schemas change,
apply them manually:

<!-- release-version -->

```sh
helm show crds oci://registry-1.docker.io/jochen/netwrangler --version 1.0.0 | kubectl apply --server-side --filename -
```

<!-- /release-version -->

[Helm Values](docs/reference.md#helm-values) lists the chart's settings. The
controller assigns no virtual IPs until you create the custom resources that
[Configuration](docs/configuration.md) describes.

## Upgrading from early 1.0.0-dev images

Docker Hub has `1.0.0-dev` images from before the 1.0.0 release. The earlier of
them bundled `nft`, `ip`, `wg` and `arping` in the agent image. The agent now
runs the node's own (see [Node tools](docs/how-it-works.md#node-tools)), so
before upgrading from such an image:

- Install nftables 1.0.6 or newer, iproute2 with JSON output and iputils
  `arping` on every node, and wireguard-tools on nodes with WireGuard links.
  Otherwise the agent's startup check stops its container.
- The chart now mounts the node's `/proc` at `/hostfs/proc` and adds
  `SYS_ADMIN`, `SYS_CHROOT` and `SYS_PTRACE` to the agent's capabilities. The
  template adds all five capabilities whatever the values say, so
  `helm upgrade --reuse-values` with the old release's values is safe for them.
  It is not for the new `agent.securityContext.appArmorProfile` default, which
  the old values lack: pass
  `--set agent.securityContext.appArmorProfile.type=Unconfined` on AppArmor
  nodes, or upgrade with `--reset-then-reuse-values`.
- The first run of the new agent finds the old `netwrangler-ipv4` table, whose
  mark maps map to marks, deletes it and rebuilds it in the same run. Until the
  rebuild, a moment later, the node's VIP traffic is neither marked nor
  source-NATted.
- nft 1.0.6 (Debian 12) crashes on any map a newer nft created, so it cannot
  delete the old table. On such a node delete it with a newer nft before
  upgrading (`nft delete table ip netwrangler-ipv4`), or the agent stops its
  container on every start.
