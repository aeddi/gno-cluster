# gno-cluster

Spin up a local cluster of [gnoland](https://github.com/gnolang/gno) nodes with configurable network topology and integrated [watchtower](https://github.com/aeddi/gno-watchtower) monitoring.

## Prerequisites

- Docker and Docker Compose v2
- bash, make, jq
- curl or wget (for `make status`)

## Quick Start

```bash
# 1. Configure
cp cluster.env.example cluster.env              # edit if needed (defaults work for 4 nodes)
cp config.overrides.example config.overrides    # optional: customize node settings

# 2. Create the cluster
#    First run: bootstraps images, generates node keys, prints validator info,
#    then prompts you to provide genesis.json (or uses one already at ./genesis.json).
make create

# 3. Start it
make start
```

`make create` does not start the cluster — it prepares a run folder. `make start`
is the separate step that brings containers up (and rebuilds images if the run
pins a version that isn't present locally).

Check that everything is running:

```bash
make status
```

```
Node       Status       Height   Latest Block             Peers
----       ------       ------   ------------             -----
node-1     running      42       2026-04-16T12:00:03      3
node-2     running      42       2026-04-16T12:00:03      3
node-3     running      42       2026-04-16T12:00:03      3
node-4     running      42       2026-04-16T12:00:03      3
```

Open Grafana at [http://localhost:3000](http://localhost:3000) (anonymous access, Viewer role).

## Commands

| Command | Description |
|---------|-------------|
| `make help` | Show available commands |
| `make build [force=1]` | Build Docker images. Skips each image whose content-addressed tag already exists; `force=1` rebuilds unconditionally. |
| `make create [yes=1]` | Create a new run: ensures node secrets exist, prints validator info, inspects `genesis.json` (prompts unless `yes=1` or non-TTY), writes the run folder. Does not start containers. Bootstrap-builds images if none exist. |
| `make start [run=<folder>]` | Start the current run, or switch to and start a past run. Re-runs `make build` against the run's pinned versions, so switching between runs with different `GNO_VERSION` works correctly. |
| `make stop` | Stop the cluster (data is preserved in the run folder). |
| `make status [watch=<sec>]` | Show each node's block height, peer count, and status. With `watch=` the display refreshes every N seconds. |
| `make logs svc=<service>` | Follow logs for a specific service (e.g. `node-1`, `sentinel-1`, `watchtower`, `grafana`). |
| `make infos` | Print node addresses, pubkeys, ports, and IDs. |
| `make clone [run=<folder>]` | Duplicate the current (or specified) run with fresh chain state. |
| `make update [force=1]` | Rebuild images and restart the cluster. |
| `make clean-imgs` | Remove all `gno-cluster-*` Docker images. |
| `make clean-runs [yes=1]` | Remove all run folders. Prompts unless `yes=1`; refuses in non-TTY mode without `yes=1`. |
| `make clean [yes=1]` | `clean-runs` then `clean-imgs`. |

## Configuration

### cluster.env

Copy `cluster.env.example` to `cluster.env`. All settings have sensible defaults.

| Variable | Default | Description |
|----------|---------|-------------|
| `GNO_VERSION` | `master` | Git tag or branch of gno to build |
| `GNO_REPO` | `gnolang/gno` | GitHub repo for gno (`owner/repo`) |
| `WATCHTOWER_VERSION` | `main` | Git tag or branch of watchtower to build |
| `WATCHTOWER_REPO` | `aeddi/gno-watchtower` | GitHub repo for watchtower (`owner/repo`) |
| `NUM_NODES` | `4` | Number of nodes in the cluster |
| `TOPOLOGY` | `mesh` | Network topology (`mesh`, `star`, or `ring`) |
| `GNOLAND_RPC_PORT_BASE` | `26657` | Host RPC port for node-1 (increments per node) |
| `GNOLAND_P2P_PORT_BASE` | `26670` | Host P2P port for node-1 (increments per node) |
| `GRAFANA_PORT` | `3000` | Host port for the Grafana UI |

### config.overrides

Optional file for customizing gnoland node configuration. Copy `config.overrides.example` for syntax reference.

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
- Global section is top-only (cannot be re-entered after a `[section]`)
- Last-match wins if the same key is set for a node in multiple sections
- Some config keys are hardcoded and cannot be overridden (P2P/RPC bind addresses, peer list)

## Network Topology

Three topologies are available, controlling which nodes can communicate over P2P.

![](.topology.svg)

**mesh** (default) — every node connects to every other node.

**star** — node-1 is the hub; all other nodes connect only through node-1.

**ring** — each node connects to its two neighbors in a circle.

Topology is enforced at the Docker network level:

- **mesh**: all nodes join a single shared bridge network (`gno-cluster_net-mesh`). Since every pair is allowed anyway, per-edge isolation would just waste address-pool slots.
- **star** / **ring**: each allowed link gets its own bridge network, so Docker's network layer enforces which nodes can reach which.

A separate sidecar network per node connects each gnoland instance to its sentinel for monitoring.

Before starting, `make start` runs a preflight check that estimates Docker's address-pool capacity against what the cluster needs, and fails with actionable options (reduce size, switch topology, free unused networks, or extend `~/.docker/daemon.json`) when the pool is insufficient.

## Runs

Each `make create` produces a self-contained **run folder** under `runs/` with a descriptive name:

```
runs/2026-04-16_12-53-57_gnolang-gno_master_4-nodes_4-vals_9-bals_78-txs/
```

The folder contains snapshots of all configs, generated compose and monitoring configs, node data directories, and monitoring storage. A `runs/current` symlink points to the active run.

### Lifecycle

- `make create` — creates a new run folder and points `runs/current` at it. Does not start containers.
- `make start` — starts the current run. First time (after `make create`) brings containers up; subsequent calls resume after a `make stop`.
- `make start run=<folder>` — switch `runs/current` to a past run, then start. Rebuilds images to match that run's pinned versions if they aren't already present locally.
- `make stop` — stops the cluster; all data is preserved in the run folder.
- `make clone [run=<folder>]` — duplicate a run with fresh chain state (same keys, same configs, empty blockchain). Useful for restarting the same setup without regenerating keys or genesis.

### What clone preserves

| Kept | Dropped |
|------|---------|
| genesis.json | Chain database (db/) |
| cluster.env | Write-ahead log (wal/) |
| config.overrides | Validator signing state |
| docker-compose.yml | Loki log data |
| Watchtower/sentinel configs | VictoriaMetrics metric data |
| Validator and node keys | Grafana dashboard state |

## Architecture

For a 4-node mesh cluster, `make start` creates:

- **4 gnoland nodes** (`node-1` .. `node-4`) — blockchain nodes with RPC and P2P
- **4 sentinels** (`sentinel-1` .. `sentinel-4`) — one per node, collects RPC data, logs, and resource metrics
- **1 watchtower** — receives data from all sentinels
- **1 VictoriaMetrics** — metrics storage (Prometheus-compatible)
- **1 Loki** — log storage
- **1 Grafana** — dashboards and visualization

Network isolation ensures topology enforcement:
- **mesh**: all nodes share one bridge network; connectivity is governed by `persistent_peers`
- **star** / **ring**: each allowed node pair shares a dedicated Docker bridge network
- Each node and its sentinel share a private sidecar network
- Sentinels, watchtower, and the monitoring stack share a watchtower network
- Nodes never join the watchtower network directly

All Docker resources use a fixed `gno-cluster` compose project name, so `make stop` reliably releases networks across runs (no accumulation from previous runs with timestamp-prefixed names). Docker images are tagged with `<short-commit>-<content-hash>` so `make build` is idempotent — it skips targets whose tag already exists locally.
