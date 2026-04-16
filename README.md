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

# 2. Build Docker images
make build

# 3. Generate node secrets (keys and IDs)
make init

# 4. Provide a genesis.json that includes the validators from step 3
#    (use the addresses and pubkeys printed by make init)
cp /path/to/your/genesis.json .

# 5. Start the cluster
make start
```

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
| `make build` | Build gnoland, watchtower, and sentinel Docker images |
| `make init` | Generate node secrets (validator keys, node IDs) |
| `make start` | Start a new cluster or resume a stopped one |
| `make stop` | Stop the cluster (data is preserved in the run folder) |
| `make status` | Show each node's block height, peer count, and status |
| `make logs svc=node-1` | Follow logs for a specific service |
| `make infos` | Print node addresses, pubkeys, ports, and IDs |
| `make clone` | Duplicate the current run with fresh chain state |
| `make update` | Rebuild images and restart the cluster |

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

Topology is enforced at the Docker network level: each allowed link gets its own bridge network, and nodes only join networks for their allowed connections. A separate sidecar network per node connects each gnoland instance to its sentinel for monitoring.

## Runs

Each `make start` creates a self-contained **run folder** under `runs/` with a descriptive name:

```
runs/2026-04-16_12-53-57_gnolang-gno_master_4-nodes_4-vals_9-bals_78-txs/
```

The folder contains snapshots of all configs, generated compose and monitoring configs, node data directories, and monitoring storage. A `runs/current` symlink points to the active run.

### Lifecycle

- `make start` — creates a fresh run, or resumes the current one if stopped
- `make start run=<folder>` — resume a specific past run
- `make stop` — stops the cluster; all data is preserved in the run folder
- `make clone` — duplicate the current run with fresh chain state (same keys, same configs, empty blockchain). Useful for restarting the same setup without regenerating keys or genesis.

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
- Each node pair that should communicate shares a dedicated Docker bridge network
- Each node and its sentinel share a private sidecar network
- Sentinels, watchtower, and the monitoring stack share a watchtower network
- Nodes never join the watchtower network directly
