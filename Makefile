# Makefile — gno-cluster: local gnoland cluster with watchtower monitoring.

SHELL := /bin/bash

-include cluster.env

# ---- Defaults
GNO_VERSION         ?= master
GNO_REPO            ?= gnolang/gno
WATCHTOWER_VERSION  ?= main
WATCHTOWER_REPO     ?= gnolang/val-companion
NUM_NODES           ?= 4
TOPOLOGY            ?= mesh
GNOLAND_RPC_PORT_BASE ?= 26657
GNOLAND_P2P_PORT_BASE ?= 26660
GRAFANA_PORT        ?= 3000

# ---- Paths
PROJECT_ROOT := $(shell pwd)
SCRIPTS      := $(PROJECT_ROOT)/internal/scripts
CURRENT_LINK := $(PROJECT_ROOT)/runs/current

# ---- Docker run helper for gnoland commands
GNOLAND_RUN = docker run --rm --entrypoint gnoland

.PHONY: build init up down clone status logs print-infos update

# ---- Build
build:
	@echo "==> Resolving versions to commit hashes..."
	@GNO_COMMIT=$$(git ls-remote "https://github.com/$(GNO_REPO).git" "$(GNO_VERSION)" | head -1 | cut -f1); \
	if [ -z "$$GNO_COMMIT" ]; then \
		echo "Error: could not resolve GNO_VERSION='$(GNO_VERSION)' from $(GNO_REPO)"; \
		exit 1; \
	fi; \
	WT_COMMIT=$$(git ls-remote "https://github.com/$(WATCHTOWER_REPO).git" "$(WATCHTOWER_VERSION)" | head -1 | cut -f1); \
	if [ -z "$$WT_COMMIT" ]; then \
		echo "Error: could not resolve WATCHTOWER_VERSION='$(WATCHTOWER_VERSION)' from $(WATCHTOWER_REPO)"; \
		exit 1; \
	fi; \
	BUILD_DATE=$$(date -u +"%Y-%m-%dT%H:%M:%SZ"); \
	echo "  gno:        $(GNO_REPO)@$(GNO_VERSION) -> $${GNO_COMMIT:0:12}"; \
	echo "  watchtower: $(WATCHTOWER_REPO)@$(WATCHTOWER_VERSION) -> $${WT_COMMIT:0:12}"; \
	echo ""; \
	echo "==> Building gnoland image..."; \
	docker build -f internal/Dockerfile \
		--target gnoland \
		--build-arg GNO_REPO=$(GNO_REPO) \
		--build-arg GNO_COMMIT_HASH=$$GNO_COMMIT \
		--build-arg GNO_VERSION=$(GNO_VERSION) \
		--build-arg BUILD_DATE=$$BUILD_DATE \
		-t gno-cluster-gnoland:latest .; \
	echo ""; \
	echo "==> Building watchtower image..."; \
	docker build -f internal/Dockerfile \
		--target watchtower \
		--build-arg WATCHTOWER_REPO=$(WATCHTOWER_REPO) \
		--build-arg WATCHTOWER_COMMIT_HASH=$$WT_COMMIT \
		--build-arg WATCHTOWER_VERSION=$(WATCHTOWER_VERSION) \
		--build-arg BUILD_DATE=$$BUILD_DATE \
		-t gno-cluster-watchtower:latest .; \
	echo ""; \
	echo "==> Building sentinel image..."; \
	docker build -f internal/Dockerfile \
		--target sentinel \
		--build-arg WATCHTOWER_REPO=$(WATCHTOWER_REPO) \
		--build-arg WATCHTOWER_COMMIT_HASH=$$WT_COMMIT \
		--build-arg WATCHTOWER_VERSION=$(WATCHTOWER_VERSION) \
		--build-arg BUILD_DATE=$$BUILD_DATE \
		-t gno-cluster-sentinel:latest .; \
	echo ""; \
	echo "==> Build complete."

# ---- Init
init:
	@echo "==> Initializing secrets for $(NUM_NODES) nodes..."
	@mkdir -p secrets
	@for i in $$(seq 1 $(NUM_NODES)); do \
		if [ -d "secrets/node-$$i" ]; then \
			echo "  node-$$i: secrets exist, skipping"; \
		else \
			echo "  node-$$i: generating secrets..."; \
			mkdir -p "secrets/node-$$i"; \
			$(GNOLAND_RUN) \
				-v "$(PROJECT_ROOT)/secrets/node-$$i:/gnoland-data" \
				gno-cluster-gnoland:latest \
				secrets init --data-dir /gnoland-data; \
			echo "  node-$$i: extracting node ID..."; \
			NODE_ID=$$($(GNOLAND_RUN) \
				-v "$(PROJECT_ROOT)/secrets/node-$$i:/gnoland-data" \
				gno-cluster-gnoland:latest \
				secrets get node_id --data-dir /gnoland-data 2>/dev/null \
				| jq -r '.id'); \
			echo "$$NODE_ID" > "secrets/node-$$i/node_id"; \
		fi; \
	done
	@echo ""
	@echo "==> Node information:"
	@printf "  %-10s %-44s %-44s %s\n" "Node" "Address" "PubKey" "Node ID"
	@printf "  %-10s %-44s %-44s %s\n" "----" "-------" "------" "-------"
	@for i in $$(seq 1 $(NUM_NODES)); do \
		ADDR=$$(jq -r '.address' "secrets/node-$$i/priv_validator_key.json"); \
		PUBKEY=$$(jq -r '.pub_key.value' "secrets/node-$$i/priv_validator_key.json"); \
		NODE_ID=$$(cat "secrets/node-$$i/node_id"); \
		printf "  %-10s %-44s %-44s %s\n" "node-$$i" "$$ADDR" "$$PUBKEY" "$$NODE_ID"; \
	done
	@echo ""
	@echo "==> Provide your genesis.json, then run 'make up'"

# ---- Up
up:
ifdef run
	@if [ ! -d "runs/$(run)" ]; then \
		echo "Error: runs/$(run) not found."; \
		exit 1; \
	fi
	@if [ -L $(CURRENT_LINK) ]; then \
		CURRENT=$$(readlink $(CURRENT_LINK)); \
		if docker compose -f "$$CURRENT/docker-compose.yml" ps --status running -q 2>/dev/null | grep -q .; then \
			echo "==> Stopping current run $$(basename $$CURRENT) first..."; \
			docker compose -f "$$CURRENT/docker-compose.yml" down; \
		fi; \
	fi
	@echo "==> Resuming run: $(run)"
	@ln -sfn "$(PROJECT_ROOT)/runs/$(run)" $(CURRENT_LINK)
	@docker compose -f "$(CURRENT_LINK)/docker-compose.yml" up -d
	@echo "==> Run resumed."
else
	@if [ ! -f genesis.json ]; then \
		echo "Error: genesis.json not found."; \
		echo "  Run 'make init' to generate secrets, then provide genesis.json."; \
		exit 1; \
	fi
	@if [ ! -d secrets ]; then \
		echo "Error: secrets/ not found. Run 'make init' first."; \
		exit 1; \
	fi
	@if [ -L $(CURRENT_LINK) ]; then \
		CURRENT=$$(readlink $(CURRENT_LINK)); \
		if docker compose -f "$$CURRENT/docker-compose.yml" ps --status running -q 2>/dev/null | grep -q .; then \
			echo "Cluster is already running ($$(basename $$CURRENT))."; \
			echo "  Run 'make down' first, or 'make up run=<folder>' to switch."; \
			exit 0; \
		fi; \
		echo "==> Resuming stopped run: $$(basename $$CURRENT)"; \
		docker compose -f "$$CURRENT/docker-compose.yml" up -d; \
		echo "==> Run resumed."; \
		exit 0; \
	fi
	@bash $(SCRIPTS)/create-run.sh \
		"$(PROJECT_ROOT)" "$(GNO_REPO)" "$(GNO_VERSION)" \
		"$(NUM_NODES)" "$(TOPOLOGY)" \
		"$(GNOLAND_RPC_PORT_BASE)" "$(GNOLAND_P2P_PORT_BASE)" "$(GRAFANA_PORT)"
endif

# ---- Down
down:
	@if [ ! -L $(CURRENT_LINK) ]; then \
		echo "Error: no active run (runs/current does not exist)."; \
		exit 1; \
	fi
	@CURRENT=$$(readlink $(CURRENT_LINK)); \
	echo "==> Stopping run: $$(basename $$CURRENT)"; \
	docker compose -f "$$CURRENT/docker-compose.yml" down; \
	echo "==> Stopped. Data preserved in $$(basename $$CURRENT)/"

# ---- Clone
clone:
ifdef run
	$(eval SOURCE_DIR := $(PROJECT_ROOT)/runs/$(run))
else
	$(eval SOURCE_DIR := $(shell readlink $(CURRENT_LINK) 2>/dev/null))
endif
	@if [ -z "$(SOURCE_DIR)" ] || [ ! -d "$(SOURCE_DIR)" ]; then \
		echo "Error: source run not found."; \
		exit 1; \
	fi
	@# Stop source if running
	@if docker compose -f "$(SOURCE_DIR)/docker-compose.yml" ps --status running -q 2>/dev/null | grep -q .; then \
		echo "==> Stopping source run first..."; \
		docker compose -f "$(SOURCE_DIR)/docker-compose.yml" down; \
	fi
	@# Read metadata from source env
	@echo "==> Cloning from: $$(basename $(SOURCE_DIR))"
	@. "$(SOURCE_DIR)/cluster.env" 2>/dev/null || true; \
	REPO_SLUG=$$(echo "$${GNO_REPO:-$(GNO_REPO)}" | tr '/' '-'); \
	VERSION="$${GNO_VERSION:-$(GNO_VERSION)}"; \
	NODES="$${NUM_NODES:-$(NUM_NODES)}"; \
	source $(SCRIPTS)/parse-genesis.sh; \
	eval "$$(parse_genesis "$(SOURCE_DIR)/genesis.json")"; \
	TIMESTAMP=$$(date +"%Y-%m-%d_%H-%M-%S"); \
	NEW_NAME="$${TIMESTAMP}_$${REPO_SLUG}_$${VERSION}_$${NODES}-nodes_$${validators_count}-vals_$${balances_count}-bals_$${txs_count}-txs"; \
	NEW_DIR="$(PROJECT_ROOT)/runs/$${NEW_NAME}"; \
	echo "  Creating: $${NEW_NAME}"; \
	mkdir -p "$$NEW_DIR"; \
	echo "  Copying configs..."; \
	for f in genesis.json cluster.env config.overrides docker-compose.yml watchtower.toml loki-config.yml; do \
		if [ -f "$(SOURCE_DIR)/$$f" ]; then cp "$(SOURCE_DIR)/$$f" "$$NEW_DIR/$$f"; fi; \
	done; \
	cp "$(SOURCE_DIR)"/sentinel-*-config.toml "$$NEW_DIR/" 2>/dev/null || true; \
	if [ -d "$(SOURCE_DIR)/grafana-provisioning" ]; then \
		cp -r "$(SOURCE_DIR)/grafana-provisioning" "$$NEW_DIR/grafana-provisioning"; \
	fi; \
	echo "  Copying secrets, resetting chain state..."; \
	for i in $$(seq 1 $$NODES); do \
		mkdir -p "$$NEW_DIR/gnoland-data-$$i/secrets"; \
		cp "$(SOURCE_DIR)/gnoland-data-$$i/secrets/priv_validator_key.json" "$$NEW_DIR/gnoland-data-$$i/secrets/"; \
		cp "$(SOURCE_DIR)/gnoland-data-$$i/secrets/node_key.json" "$$NEW_DIR/gnoland-data-$$i/secrets/"; \
		printf '{\n  "height": "0",\n  "round": "0",\n  "step": 0\n}\n' \
			> "$$NEW_DIR/gnoland-data-$$i/secrets/priv_validator_state.json"; \
	done; \
	mkdir -p "$$NEW_DIR/victoria-data" "$$NEW_DIR/loki-data" "$$NEW_DIR/grafana-data"; \
	ln -sfn "$$NEW_DIR" $(CURRENT_LINK); \
	echo "==> Cloned. Run 'make up' to start."

# ---- Status
status:
	@if [ ! -L $(CURRENT_LINK) ]; then \
		echo "No active run."; \
		exit 0; \
	fi
	@. "$(shell readlink $(CURRENT_LINK))/cluster.env" 2>/dev/null || true; \
	NODES=$${NUM_NODES:-$(NUM_NODES)}; \
	RPC_BASE=$${GNOLAND_RPC_PORT_BASE:-$(GNOLAND_RPC_PORT_BASE)}; \
	printf "%-10s %-12s %-8s %-24s %s\n" "Node" "Status" "Height" "Latest Block" "Peers"; \
	printf "%-10s %-12s %-8s %-24s %s\n" "----" "------" "------" "------------" "-----"; \
	for i in $$(seq 1 $$NODES); do \
		PORT=$$((RPC_BASE + i - 1)); \
		RESULT=$$(curl -s --max-time 2 "http://localhost:$$PORT/status" 2>/dev/null) || true; \
		if [ -z "$$RESULT" ]; then \
			printf "%-10s %-12s %-8s %-24s %s\n" "node-$$i" "unreachable" "-" "-" "-"; \
		else \
			HEIGHT=$$(echo "$$RESULT" | jq -r '.result.sync_info.latest_block_height // "?"'); \
			BLOCK_TIME=$$(echo "$$RESULT" | jq -r '.result.sync_info.latest_block_time // "?"' | cut -c1-19); \
			NUM_PEERS=$$(echo "$$RESULT" | jq -r '.result.n_peers // "?"'); \
			printf "%-10s %-12s %-8s %-24s %s\n" "node-$$i" "running" "$$HEIGHT" "$$BLOCK_TIME" "$$NUM_PEERS"; \
		fi; \
	done

# ---- Logs
logs:
ifndef svc
	@echo "Usage: make logs svc=<service>"
	@echo "  Services: node-1..node-N, sentinel-1..sentinel-N, watchtower, victoria-metrics, loki, grafana"
	@exit 1
endif
	@if [ ! -L $(CURRENT_LINK) ]; then \
		echo "Error: no active run."; \
		exit 1; \
	fi
	@docker compose -f "$$(readlink $(CURRENT_LINK))/docker-compose.yml" logs -f $(svc)

# ---- Print Infos
print-infos:
	@if [ ! -d secrets ]; then \
		echo "Error: secrets/ not found. Run 'make init' first."; \
		exit 1; \
	fi
	@echo "==> Node information ($(NUM_NODES) nodes, $(TOPOLOGY) topology):"
	@echo ""
	@printf "  %-10s %-20s %-44s %-44s %-22s %s\n" \
		"Node" "Moniker" "Address" "PubKey" "RPC" "P2P Port"
	@printf "  %-10s %-20s %-44s %-44s %-22s %s\n" \
		"----" "-------" "-------" "------" "---" "--------"
	@for i in $$(seq 1 $(NUM_NODES)); do \
		ADDR=$$(jq -r '.address' "secrets/node-$$i/priv_validator_key.json"); \
		PUBKEY=$$(jq -r '.pub_key.value' "secrets/node-$$i/priv_validator_key.json"); \
		NODE_ID=$$(cat "secrets/node-$$i/node_id" 2>/dev/null || echo "unknown"); \
		RPC_PORT=$$(($(GNOLAND_RPC_PORT_BASE) + i - 1)); \
		P2P_PORT=$$(($(GNOLAND_P2P_PORT_BASE) + i - 1)); \
		MONIKER="node-$$i"; \
		printf "  %-10s %-20s %-44s %-44s localhost:%-12s %s\n" \
			"node-$$i" "$$MONIKER" "$$ADDR" "$$PUBKEY" "$$RPC_PORT" "$$P2P_PORT"; \
	done
	@echo ""
	@echo "  Node IDs:"
	@for i in $$(seq 1 $(NUM_NODES)); do \
		NODE_ID=$$(cat "secrets/node-$$i/node_id" 2>/dev/null || echo "unknown"); \
		echo "    node-$$i: $$NODE_ID"; \
	done

# ---- Update
update: build
	@if [ ! -L $(CURRENT_LINK) ]; then \
		echo "Error: no active run to update."; \
		exit 1; \
	fi
	@CURRENT=$$(readlink $(CURRENT_LINK)); \
	echo "==> Restarting run: $$(basename $$CURRENT)"; \
	docker compose -f "$$CURRENT/docker-compose.yml" up -d --force-recreate; \
	echo "==> Updated and restarted."
