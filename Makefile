# Makefile — gno-cluster: local gnoland cluster with watchtower monitoring.
#
# Usage: make <target> [args]
#
# Targets:
#   build    [force=1]        Build Docker images (skip if up to date; force=1 rebuilds)
#   create   [yes=1]          Create a new run (keys + images + run folder; does not start)
#   start    [run=<folder>]   Start the current run, or switch to and start a past run
#   stop                      Stop the cluster (data is preserved)
#   clone    [run=<folder>]   Clone current or specified past run with fresh chain state
#   status   [watch=<sec>]    Show each node's block height, peers, and status
#   logs     svc=<service>    Follow logs for a service
#   infos                     Print node addresses, pubkeys, ports, and IDs
#   update                    Rebuild images and restart the cluster
#   clean-images              Remove all gno-cluster Docker images
#   clean-runs    [yes=1]     Remove all run folders (prompts unless yes=1)
#   clean         [yes=1]     Run clean-runs then clean-images
#   help                      Show this help message
#
# Configuration:
#   cluster.env               Environment variables (copy from cluster.env.example)
#   config.overrides          Per-node gnoland config (copy from config.overrides.example)
#   genesis.json              Chain genesis file (user-provided)

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

.PHONY: help build create start stop clone status logs infos update clean clean-runs clean-images

help:
	@awk '/^# Usage:/,/^$$/{sub(/^# ?/,""); print}' $(MAKEFILE_LIST)

build:
	@$(CLUSTER) build $(force)

create:
	@$(CLUSTER) create $(yes)

start:
	@$(CLUSTER) start $(run)

stop:
	@$(CLUSTER) stop

clone:
	@$(CLUSTER) clone $(run)

status:
	@$(CLUSTER) status $(watch)

logs:
	@$(CLUSTER) logs $(svc)

infos:
	@$(CLUSTER) infos

update:
	@$(CLUSTER) build $(force)
	@$(CLUSTER) update

clean-images:
	@$(CLUSTER) clean-images

clean-runs:
	@$(CLUSTER) clean-runs $(yes)

clean:
	@$(CLUSTER) clean $(yes)
