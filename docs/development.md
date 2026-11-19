# Development

## Prerequisites

- **Crystal** >= 1.21.0, < 1.22
- **Ruby** (for Rake build system and integration tests)
- **Bundler** (`gem install bundler`, then `bundle install`)
- **Docker** with buildx (for container image builds)
- **kind** (for local Kubernetes cluster)
- **Helm** and **Helmfile** (for deployment)

## Building

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

## Testing

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

Integration tests require a running kind cluster (see
[Local Development with kind](#local-development-with-kind)).

## Local Development with kind

```sh
# Create a 3-node kind cluster
rake kind:start

# Install the node tools the agent runs (wireguard-tools, iputils-arping)
rake kind:node_tools

# Build images, load into kind, and deploy via Helmfile
rake kind:deploy

# Rebuild and restart after code changes (installs the node tools first)
rake kind:restart

# Delete the cluster
rake kind:delete
```

`rake kind:restart` also attaches the demo's Docker networks
`netwrangler-public` (`eth1`) and `netwrangler-private` (`eth2`) to every node
(`rake kind:networks`) and joins the nodes with the WireGuard mesh `wg-demo`
(`rake kind:wireguard`). Both tasks change nothing on a cluster that has them.

## Demo

`rake demo:deploy` applies every example in `examples/` to the kind cluster and
checks each with real traffic; `rake demo:deploy:<example>` runs one, and
`rake demo:clean` removes them. [examples/README.md](../examples/README.md)
describes the demo, its networks and what the checks prove. The integration
test tasks run `demo:clean` first.

## Continuous integration

Two GitHub Actions workflows live in `.github/workflows/`.

`ci.yml` runs on every push to `main`, on every pull request, every Monday at
05:00 UTC and on demand. Its `check` job installs the Crystal version in
`.project.yaml` and the Ruby version in `.ruby-version`, then runs `rake deps`,
`rake spec`, `rake lint`, `bundle exec rubocop` and
`helm lint deploy/charts/netwrangler`. The `integration` job runs only on the
weekly schedule and on demand. It creates a kind cluster with `rake kind:start`
and runs `rake test`, then `rake demo:deploy`, which also runs after failed
tests. Neither job reads a secret, so pull requests from forks run the same
checks.

The weekly run uses the newest Crystal release instead of the version in
`.project.yaml`, so a release that breaks the build shows before the project
moves to it. The `check` job passes the version it installed to the
`integration` job, which builds the images with it through the
`CRYSTAL_VERSION` build argument. A run started by hand takes the version from
its `crystal` input: `project` (the default) or `latest`.

Pushing a `v*` tag, such as the one `rake release` creates, starts
`release.yml`. It calls `ci.yml` to run the `check` and `integration` jobs, the
demo included, with the Crystal version in `.project.yaml`, and stops when one
fails. The `check` job first stops a run for a tag that does not name the
version in `.project.yaml`. The release workflow then pushes the images, the
Helm chart and the chart's Artifact Hub metadata to Docker Hub, and creates a
GitHub release. The release notes are the tag's section of `CHANGELOG.md`, or
notes GitHub generates when the file has no such section.

The release workflow reads two repository secrets:

- `DOCKERHUB_USERNAME` is the Docker Hub account that owns the `jochen`
  namespace (`docker.repository` in `.project.yaml`)
- `DOCKERHUB_TOKEN` is an access token of that account with read and write
  access

## Rake Tasks

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
| `rake licenses:update`                                     | Fetch the bundled software's license files into docs/licenses/   |
| `rake docker:build`                                        | Build every image for all platforms (build cache only)           |
| `rake docker:load`                                         | Build every image for this host and load it into the daemon      |
| `rake docker:push`                                         | Build and push every multi-arch image                            |
| `rake <component>:docker:build`, `:load`, `:push`          | The same for one image                                           |
| `rake <component>:docker:run`                              | Run one image in a container                                     |
| `rake kind:start`                                          | Create the 3-node kind cluster                                   |
| `rake kind:deploy`                                         | Deploy to the kind cluster                                       |
| `rake kind:redeploy`                                       | Deploy and restart every workload so reloaded images take effect |
| `rake kind:restart`                                        | Redeploy and wait for every rollout                              |
| `rake kind:node_tools`                                     | Install `wg` and iputils `arping` in the kind nodes              |
| `rake kind:networks`                                       | Attach the demo's Docker networks to the kind nodes              |
| `rake kind:wireguard`                                      | Build the WireGuard mesh `wg-demo` between the kind nodes        |
| `rake demo:deploy`                                         | Apply every example to kind and check it with real traffic       |
| `rake demo:deploy:<example>`                               | Apply one example and check it                                   |
| `rake demo:install`                                        | Install on kind, building the images only when a node lacks one  |
| `rake demo:cluster`                                        | Apply the demo's VipConfig and VipNetworks (`examples/cluster/`) |
| `rake demo:clean`                                          | Remove the examples; the networks and the mesh stay              |
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

## Project Structure

```text
src/
  controller/          # Controller: allocation logic, shell-operator hook
  agent/               # Agent: address, routes, and nftables updaters
  model/               # Data models for Kubernetes resources
  util/                # Shared utilities (binding context, commands)
  privileged_runner.cr # node-tool: runs the node's nft, ip, wg and arping (own binary)
  privileged_runner/   # node-tool: argument checks, capabilities, namespace entry
spec/                  # Crystal unit tests, node-tool's in spec/node-tool/
test/                  # Ruby integration tests (RSpec)
scripts/               # check-host-versions.sh for a node's tool versions
docs/
  licenses/            # License files of the bundled software (rake licenses:update)
deploy/
  charts/              # Helm chart with CRDs and templates
  kind-config.yaml     # kind cluster configuration
  helmfile.yaml.gotmpl # Helmfile for multi-environment deployment
examples/              # One manifest set per use case, run by rake demo:deploy
rakelib/
  demo.rake            # The demo tasks
  demo/                # The demo's examples, checks and cleanup
  kind_cluster/        # The demo networks and the WireGuard mesh on the kind nodes
  licenses.rake        # rake licenses:update
  facets/              # Build, test and release tasks (vsrun-managed)
```
