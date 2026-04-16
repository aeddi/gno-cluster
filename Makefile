# Makefile — gno-cluster: local gnoland cluster with watchtower monitoring.
#
# Usage: make <target> [args]
#
# Targets:
#   build          Build Docker images (gnoland, watchtower, sentinel)
#   init           Generate node secrets (keys, node IDs)
#   up             Start a new cluster or resume a stopped one
#   down           Stop the cluster (data is preserved)
#   clone          Duplicate current run with fresh chain state
#   status         Show each node's block height, peers, and status
#   logs           Follow logs for a service (make logs svc=node-1)
#   print-infos    Print node addresses, pubkeys, ports, and IDs
#   update         Rebuild images and restart the cluster
#   test           Run unit tests
#   help           Show this help message
#
# Arguments:
#   make up run=<folder>      Resume a specific past run
#   make clone run=<folder>   Clone a specific past run
#   make logs svc=<service>   Follow logs (node-1..N, sentinel-1..N, watchtower, grafana, loki, victoria-metrics)
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
export PROJECT_ROOT  := $(shell pwd)
export GNO_VERSION GNO_REPO WATCHTOWER_VERSION WATCHTOWER_REPO
export NUM_NODES TOPOLOGY GNOLAND_RPC_PORT_BASE GNOLAND_P2P_PORT_BASE GRAFANA_PORT

CLUSTER := bash $(PROJECT_ROOT)/internal/scripts/cluster.sh

.DEFAULT_GOAL := help
.PHONY: help build init up down clone status logs print-infos update test

help:
	@awk '/^# Usage:/,/^$$/{sub(/^# ?/,""); print}' $(MAKEFILE_LIST)

build:
	@$(CLUSTER) build

init:
	@$(CLUSTER) init

up:
	@$(CLUSTER) up $(run)

down:
	@$(CLUSTER) down

clone:
	@$(CLUSTER) clone $(run)

status:
	@$(CLUSTER) status

logs:
	@$(CLUSTER) logs $(svc)

print-infos:
	@$(CLUSTER) print-infos

update:
	@$(CLUSTER) build
	@$(CLUSTER) update

test:
	@echo "==> Running tests..."
	@bash tests/test_topology.sh
	@bash tests/test_parse_genesis.sh
	@bash tests/test_parse_overrides.sh
	@echo ""
	@echo "==> All tests passed."
