# Makefile — gno-cluster: local gnoland cluster with watchtower monitoring.
#
# Usage: make <target> [args]
#
# Run lifecycle:
#   create       [yes=1]          Create a new run (yes=1 skips the genesis prompt)
#   clone        [run=<folder>]   Clone a run with fresh chain state (run= targets a past run, else current)
#   update       [run=<folder>]   Rebuild drifted images and restart (run= targets a past run, else current)
#
# Cluster ops:
#   start        [run=<folder>]   Start a run (run= switches to a past run, else current)
#   stop                          Stop the current run
#   restart      [run=<folder>]   Stop then start (run= switches to a past run, else current)
#   infos        [run=<folder>]   Print node addresses, pubkeys, ports (run= targets a past run, else current)
#   status       [watch=<sec>]    Show nodes' block height, peers, and status (watch= refreshes every N seconds)
#   logs         svc=<service>    Follow logs for a service (svc= is required, e.g. node-1, watchtower)
#
# Cleanup:
#   clean-imgs   [yes=1]          Remove all gno-cluster Docker images (yes=1 skips the prompt)
#   clean-runs   [yes=1]          Remove all run folders (yes=1 skips the prompt)
#   clean        [yes=1]          Run clean-runs then clean-imgs (yes=1 skips the prompt)
#
# Config files:
#   cluster.env                   Environment variables (copy from cluster.env.example)
#   config.overrides              Per-node gnoland config (copy from config.overrides.example)
#   genesis.json                  Chain genesis file (user-provided)

-include cluster.env

# ---- Defaults
GNO_VERSION           ?= master
GNO_REPO              ?= gnolang/gno
WATCHTOWER_VERSION    ?= main
WATCHTOWER_REPO       ?= aeddi/gno-watchtower
NUM_NODES             ?= 4
TOPOLOGY              ?= mesh
GNOLAND_RPC_PORT_BASE ?= 26657
GNOLAND_P2P_PORT_BASE ?= 26670
GRAFANA_PORT          ?= 3000

# ---- Env export (passed to cluster.sh)
export PROJECT_ROOT  := $(shell dirname $(realpath $(lastword $(MAKEFILE_LIST))))
export GNO_VERSION GNO_REPO WATCHTOWER_VERSION WATCHTOWER_REPO
export NUM_NODES TOPOLOGY GNOLAND_RPC_PORT_BASE GNOLAND_P2P_PORT_BASE GRAFANA_PORT

# Cluster command are implemented in a bash script to allow for more complex logic
# and better error handling. The Makefile is just a thin wrapper around it.
CLUSTER := bash $(PROJECT_ROOT)/internal/scripts/cluster.sh

.PHONY: help build create start stop restart clone status logs infos update clean clean-runs clean-imgs

help:
	@awk '/^# Usage:/,/^$$/{sub(/^# ?/,""); print}' $(MAKEFILE_LIST)

create:
	@$(CLUSTER) create $(yes)

start:
	@$(CLUSTER) start $(run)

stop:
	@$(CLUSTER) stop

restart:
	@$(CLUSTER) restart $(run)

clone:
	@$(CLUSTER) clone $(run)

status:
	@$(CLUSTER) status $(watch)

logs:
	@$(CLUSTER) logs $(svc)

infos:
	@$(CLUSTER) infos $(run)

update:
	@$(CLUSTER) update $(run)

clean-imgs:
	@$(CLUSTER) clean-imgs $(yes)

clean-runs:
	@$(CLUSTER) clean-runs $(yes)

clean:
	@$(CLUSTER) clean $(yes)

# build is an implementation detail of create/update. Kept here so it can still
# be invoked directly (e.g. for debugging), but hidden from `make help`.
build:
	@$(CLUSTER) build $(force)
