# gno-cluster

Spin up a local cluster of [gnoland](https://github.com/gnolang/gno) nodes with configurable network topology and integrated [watchtower](https://github.com/aeddi/gno-watchtower) monitoring.

Every `make create` produces a self-contained **run folder** under `runs/` (timestamped, kept on disk). A `runs/current` symlink points to whichever run is active. Past runs can be stopped and resumed, cloned (same config and keys with a fresh chain), or updated (rebuild their pinned images and restart). Run folders are immutable snapshots of configs and data; the tool never overwrites them in place.

## Prerequisites

- Docker + Docker Compose v2
- `bash`, `make`
- `git` — required to resolve `GNO_VERSION`/`WATCHTOWER_VERSION` refs to commits
- `jq` — required for genesis parsing and `make infos`
- `curl` or `wget` — required for `make status`; used for the optional GitHub compare on drift
- `sha256sum` (Linux) or `shasum` (macOS) — either works

## Quick Start

Bring up a fresh 4-node [mesh](#network-topology) cluster and verify it's producing blocks.

**1. Copy config files.**

```bash
cp cluster.env.example cluster.env
cp config.overrides.example config.overrides   # optional
```

Defaults bring up a 4-node [mesh](#network-topology). See the [cluster.env reference](#clusterenv-reference) for cluster config and the [config.overrides reference](#configoverrides-reference) for per-node gnoland config.

**2. Bootstrap the cluster.**

```bash
make create
```

On first invocation this builds the Docker images, generates node secrets, and prints each node's info.

If no `genesis.json` exists in the project root, it then prints a ready-to-paste `INITIAL_VALSET=(…)` block, waits for you to generate it, and to copy it.

```bash
# open another terminal to generate genesis.json with the printed INITIAL_VALSET

cp /path/to/your/genesis.json .

# back in the 'make create' terminal: press Enter, confirm with y
```

`make create` then writes the run folder — see [Run folders & build state](#run-folders--build-state).

**3. Start the cluster.**

```bash
make start
```

See [Architecture](#architecture) for what gets launched.

**4. Verify.**

```bash
make infos
make status watch=3
```

`make infos` prints the static info while `make status` shows live heights, peer counts, and reachability. `watch=3` refreshes every 3 seconds.  
See the [Makefile reference](#makefile-reference).

**5. Open Grafana** at [http://localhost:3000](http://localhost:3000) for logs, metrics, and dashboards (anonymous Viewer access).

To stop without discarding data: `make stop`. To resume: `make start`.

## Cloning a run

Use `make clone` when you want a **fresh blockchain** from the same validators and configs — for example, to reset state for a new test iteration without re-generating keys or editing genesis.json.

```bash
make clone                              # clone current run → points runs/current at the clone
make clone run=2026-04-15_09-12-34_...  # clone a specific past run instead
make start                              # bring the clone up
```

What gets preserved vs dropped:

| Kept                        | Dropped                     |
| --------------------------- | --------------------------- |
| genesis.json                | Chain database (db/)        |
| cluster.env                 | Write-ahead log (wal/)      |
| config.overrides            | Validator signing state     |
| docker-compose.yml          | Loki log data               |
| Watchtower/sentinel configs | VictoriaMetrics metric data |
| Validator and node keys     | Grafana dashboard state     |

Use `make clone-full` for a **bit-for-bit copy** including chain db, WAL, validator signing state, and all monitoring data. The clone resumes at the source's height on next `make start`.

> ⚠️ Don't run a full clone and its source simultaneously. They share `priv_validator_key.json`, so both producing blocks means double-signing.

See [Run folders & build state](#run-folders--build-state) for what lives inside a run folder.

## Updating a run

Use `make update` when a run's **pinned image state has drifted** from what your current env / source files specify. This happens when you bump `GNO_VERSION`, edit the `Dockerfile`, or `master` has moved since the run was created.

```bash
# After bumping GNO_VERSION in cluster.env or editing internal/Dockerfile:
make update
```

`make update` shows the drift (files / commits changed), rebuilds the affected images, refreshes the run's `.build-state` pin, and restarts.

`make start` boots a pinned run and never rebuilds when `.build-state` is present. If it detects drift, it prints a summary telling you either to `make update` (adopt the change) or `make clone` (try the new build on a copy and keep this run pristine).

What triggers drift: any change in the hashed image inputs (`internal/Dockerfile` + `internal/docker/**` + `internal/scripts/parse-overrides.sh`) **or** a different resolved commit for `GNO_VERSION` / `WATCHTOWER_VERSION`. See [Run folders & build state](#run-folders--build-state) for how `.build-state` records what was pinned.

---

# Reference

## Makefile reference

Run `make help` for the full list. Targets fall into three groups:

**Run lifecycle** — manage the set of runs on disk:

| Target | Description |
| ------ | ----------- |
| `make create [yes=1]` | Create a new run. `yes=1` skips the genesis confirmation prompt. Builds any missing images. |
| `make clone [run=<folder>]` | Clone a run with fresh chain state. `run=` targets a past run, otherwise current. |
| `make clone-full [run=<folder>]` | Bit-for-bit clone including chain db, WAL, signing state, and all monitoring data. Resumes at the source's height. |
| `make update [run=<folder>]` | Rebuild drifted images and restart the run. `run=` targets a past run, otherwise current. No-op if nothing drifted. |

**Cluster ops** — operate on a specific run:

| Target | Description |
| ------ | ----------- |
| `make list` | List all runs with state, config, heights, and on-disk sizes. |
| `make start [run=<folder>]` | Start a run. `run=` switches `runs/current` to a past run. Won't rebuild a pinned run — surfaces drift instead and suggests update/clone. |
| `make stop` | Stop the current run. Data stays on disk in the run folder. |
| `make restart [run=<folder>]` | Stop then start. Useful with `run=` to switch and restart in one step. |
| `make infos [run=<folder>]` | Full report: state, heights, sizes, cluster config, genesis info, node identities, P2P/RPC endpoints. |
| `make status [watch=<sec>]` | Per-node heights, peer counts, reachability. `watch=<sec>` refreshes every N seconds. |
| `make logs svc=<service>` | Follow logs for a service (e.g. `node-1`, `sentinel-1`, `watchtower`, `grafana`). |

**Cleanup** — free disk and Docker resources:

| Target | Description |
| ------ | ----------- |
| `make clean-imgs [yes=1]` | Remove all `gno-cluster-*` Docker images. Prompts unless `yes=1`. |
| `make clean-runs [yes=1]` | Remove all run folders. Prompts unless `yes=1`; refuses in non-TTY without `yes=1`. Stops any running cluster first. |
| `make clean [yes=1]` | `clean-runs` then `clean-imgs`. |

`make build [force=1]` is called internally by `create` and `update`. It skips targets whose content-addressed tag already exists; `force=1` rebuilds unconditionally.

## cluster.env reference

Copy `cluster.env.example` to `cluster.env`. All settings have sensible defaults.

| Variable                | Default                | Description                                         |
| ----------------------- | ---------------------- | --------------------------------------------------- |
| `GNO_VERSION`           | `master`               | Git ref (branch, tag, or commit) for gno            |
| `GNO_REPO`              | `gnolang/gno`          | GitHub repo for gno (`owner/repo`)                  |
| `WATCHTOWER_VERSION`    | `main`                 | Git ref for watchtower/sentinel                     |
| `WATCHTOWER_REPO`       | `aeddi/gno-watchtower` | GitHub repo for watchtower/sentinel                 |
| `NUM_NODES`             | `4`                    | Number of nodes in the cluster                      |
| `TOPOLOGY`              | `mesh`                 | Network topology — `mesh`, `star`, or `ring`. See [Network topology](#network-topology). |
| `GNOLAND_RPC_PORT_BASE` | `26657`                | Host RPC port for node-1 (increments per node)      |
| `GNOLAND_P2P_PORT_BASE` | `26670`                | Host P2P port for node-1 (increments per node)      |
| `GRAFANA_PORT`          | `3000`                 | Host port for the Grafana UI                        |

At `make create` time, `cluster.env` is copied into the run folder and becomes the run's own pinned config. Editing the project-root `cluster.env` later affects future `make create` invocations, not existing runs — use `make update` to apply version bumps to an existing run.

## config.overrides reference

Optional file for tuning gnoland node config. Copy `config.overrides.example` to `config.overrides` and edit. The example file also lists the keys the system hardcodes on every start (which cannot be overridden).

Lines before any section header apply to all nodes. Section headers target specific nodes:

```toml
# Applied to all nodes
consensus.timeout_commit = "3s"
mempool.size = 10000

# Applied only to node-1
[node-1]
consensus.timeout_commit = "5s"

# Applied to node-2 and node-3
[node-2, node-3]
mempool.size = 5000
```

Rules:

- Global (unheaded) section must be first — can't re-enter it after a `[section]`.
- Last-match wins if the same key is set for a node in multiple sections.
- A few keys are always overridden by the system (P2P/RPC bind addresses, persistent peers list) — see `config.overrides.example` for the full list.

Overrides are applied by `internal/docker/gnoland-entrypoint.sh` on every container start, before the hardcoded settings.

## Network topology

Three topologies are available, controlling which nodes can communicate over P2P.

![Mesh, star, and ring topologies](.topology.svg)

- **mesh** (default) — every node connects to every other node.
- **star** — `node-1` is the hub; all other nodes connect only through `node-1`.
- **ring** — each node connects to its two neighbors in a circle.

Enforcement at the Docker network layer:

- **mesh** — all nodes share a single bridge network (`gno-cluster_net-mesh`). Per-edge isolation would just waste address-pool slots when every pair is allowed.
- **star** / **ring** — each allowed link gets its own bridge network, so Docker enforces which nodes can reach which.

A separate sidecar network per node wires each gnoland instance to its sentinel for monitoring. All runs use the fixed compose project name `gno-cluster`, so only one run can be live at a time (host ports collide) and `make stop` releases networks reliably regardless of which run folder owned them.

Before starting, `make start` runs a preflight against Docker's `default-address-pools`. If the declared pool can't fit the topology's networks, it fails with options: reduce `NUM_NODES`, switch `TOPOLOGY`, free unused networks (`docker network prune`), or extend `~/.docker/daemon.json` with a wider pool.

## Run folders & build state

Each `make create` produces a timestamped folder under `runs/`:

```
runs/2026-04-16_12-53-57_gnolang-gno_master_4-nodes_4-vals_9-bals_78-txs/
├── cluster.env              # Snapshot of the project-root env at create time
├── config.overrides         # Snapshot (if present)
├── genesis.json             # Snapshot
├── docker-compose.yml       # Generated
├── watchtower.toml          # Generated
├── sentinel-N-config.toml   # Generated, one per node
├── grafana-provisioning/    # Generated monitoring config
├── gnoland-data-N/          # Per-node data (chain, WAL, secrets copy)
├── loki-data/               # Logs collected by Loki
├── victoria-data/           # Metrics collected by VictoriaMetrics
├── grafana-data/            # Grafana storage
└── .build-state             # Pinned build inputs — see below
```

`runs/current` is a symlink to the active run.

**`.build-state`** is written by `make create` (and refreshed by `make update`). It records:

- resolved `GNO_COMMIT` and `WATCHTOWER_COMMIT`
- image tags (`<short-commit>-<content-hash>`)
- per-file sha256 of all files that go into images (`internal/Dockerfile`, `internal/docker/**`, `internal/scripts/parse-overrides.sh`)
- `BUILD_DATE`

`make start` reads `.build-state`, re-resolves commits and recomputes the content hash, and — if anything changed — prints a drift summary with `make clone` / `make update` suggestions. It then boots with the pinned images without rebuilding. Writes are atomic (temp file + rename) so an interrupted build doesn't leave a corrupted state.

## Architecture

For a 4-node mesh cluster, `make start` runs:

- **4 gnoland nodes** (`node-1` .. `node-4`) — RPC + P2P
- **4 sentinels** (`sentinel-1` .. `sentinel-4`) — one per node, collects RPC data, logs, resource metrics
- **1 watchtower** — receives data from all sentinels
- **1 VictoriaMetrics** — metrics storage (Prometheus-compatible)
- **1 Loki** — log storage
- **1 Grafana** — dashboards

Network isolation:

- **mesh** — one shared bridge for all nodes; connectivity governed by `persistent_peers`.
- **star** / **ring** — one bridge per allowed node pair; other links are unreachable at the Docker layer.
- Each node and its sentinel share a private sidecar network.
- Sentinels, watchtower, and the monitoring stack share a watchtower network.
- Nodes never join the watchtower network directly.

Docker images are tagged with `<short-commit>-<content-hash>` (e.g. `gno-cluster-gnoland:26dc377ab634-f26bc34e`) so `make build` is idempotent. `:latest` is maintained as an alias that compose files reference.
