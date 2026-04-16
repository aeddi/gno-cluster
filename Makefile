# Makefile — gno-cluster: local gnoland cluster with watchtower monitoring.
# Thin wrapper that loads env and dispatches to internal/scripts/cluster.sh.

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

.PHONY: build init up down clone status logs print-infos update

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
