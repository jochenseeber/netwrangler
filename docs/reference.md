# Reference

## Custom Resources

All custom resources use API group `netwrangler.dev/v1`.

| Resource   | Scope      | Short Name | Description                                                         |
| ---------- | ---------- | ---------- | ------------------------------------------------------------------- |
| VipConfig  | Cluster    | `vc`       | Global firewall mark, route table, and routing policy configuration |
| VipNetwork | Cluster    | `vn`       | Network interface, gateway, and network addressing                  |
| VipAddress | Namespaced | `va`       | Individual IP assignment to a node (managed by controller)          |
| VipGateway | Cluster    | `vg`       | Gateway routing policy (destination, table, priority, pod selector) |
| VipRoute   | Namespaced | `vr`       | Individual route to a gateway pod (managed by controller)           |

The sections below list the fields of VipAddress and VipRoute. For VipConfig,
VipNetwork and VipGateway, see [Configuration](configuration.md).

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

## Helm Values

Key configurable values (see
[values.yaml](../deploy/charts/netwrangler/values.yaml) for the full
reference):

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
| `agent.image.repository`               | `jochen/netwrangler-agent`      | Agent image                                  |
| `agent.image.tag`                      | Chart appVersion                | Image tag                                    |
| `agent.image.pullPolicy`               | `IfNotPresent`                  | Image pull policy                            |
| `agent.podAnnotations`                 | `{}`                            | Annotations on the agent pods only           |
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
agent runs with the capabilities `NET_ADMIN`, `NET_RAW`, `SYS_ADMIN`,
`SYS_CHROOT` and `SYS_PTRACE`, the node's `/proc` mounted read-only at
`/hostfs/proc`, and `hostNetwork: true`. Both the agent and the controller run
as non-root (`runAsUser: 1000`).

The agent image bundles none of `nft`, `ip`, `wg` and `arping`: they are the
node's. `/usr/local/sbin/{nft,ip,wg,arping}` in the image are symlinks to
`/usr/libexec/node-tool`, a small static program that enters the node's mount
namespace (`/hostfs/proc/1/ns/mnt`) and runs the node's tool there, so the
node's versions and configuration apply. The agent pod therefore needs the
node's `/proc` mounted at `/hostfs/proc`. Without it, or without a tool on the
node, the call fails with exit code 126 or 127 and a one-line reason on stderr.

[`scripts/check-host-versions.sh`](../scripts/check-host-versions.sh) records a
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

[netwrangler]: https://github.com/jochenseeber/netwrangler
