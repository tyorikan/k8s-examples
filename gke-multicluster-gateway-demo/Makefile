# ==============================================================================
# Makefile for GKE Multi-Cluster Gateway Active-Active Demo (Tokyo & Osaka)
# ==============================================================================
export PATH := $(HOME)/google-cloud-sdk/bin:$(PATH)
CLUSTER_TOKYO ?= gke-tokyo
CLUSTER_OSAKA ?= gke-osaka
NAMESPACE     ?= whereami-demo
GATEWAY_NAME  ?= external-global-gateway

.PHONY: help setup-infra deploy-apps status get-vip \
        weight-50-50 weight-100-0 weight-0-100 \
        simulate-tokyo-outage recover-tokyo simulate-osaka-outage recover-osaka \
        monitor-weighted monitor-auto cleanup

help: ## Show available demo commands
	@echo "=============================================================================="
	@echo " GKE Multi-Cluster Gateway Demo (Tokyo <-> Osaka Active-Active)"
	@echo "=============================================================================="
	@grep -E '^[a-zA-Z0-9_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-24s\033[0m %s\n", $$1, $$2}'

setup-infra: ## Step 1: Provision VPC, GKE Autopilot clusters (Tokyo/Osaka), Fleet, MCS & Gateway
	./scripts/01-setup-infra.sh

deploy-apps: ## Step 2: Deploy whereami workloads, ServiceExports, Gateway, and 50:50 HTTPRoute
	./scripts/02-deploy-workloads.sh

status: ## Inspect Gateway, HTTPRoute, ServiceExports, and ServiceImports status
	@echo "=== [Config Cluster: $(CLUSTER_TOKYO)] Gateway & HTTPRoute ==="
	kubectl get gateway,httproute,healthcheckpolicy --context=$(CLUSTER_TOKYO) -n $(NAMESPACE)
	@echo ""
	@echo "=== [Config Cluster: $(CLUSTER_TOKYO)] Multi-Cluster ServiceImports ==="
	kubectl get serviceimports --context=$(CLUSTER_TOKYO) -n $(NAMESPACE)
	@echo ""
	@echo "=== [Tokyo: $(CLUSTER_TOKYO)] Pods & ServiceExports ==="
	kubectl get pods,serviceexports --context=$(CLUSTER_TOKYO) -n $(NAMESPACE)
	@echo ""
	@echo "=== [Osaka: $(CLUSTER_OSAKA)] Pods & ServiceExports ==="
	kubectl get pods,serviceexports --context=$(CLUSTER_OSAKA) -n $(NAMESPACE)

get-vip: ## Print the Global External Application Load Balancer VIP
	@kubectl get gateway $(GATEWAY_NAME) --context=$(CLUSTER_TOKYO) -n $(NAMESPACE) -o jsonpath='{.status.addresses[0].value}{"\n"}'

# ------------------------------------------------------------------------------
# Demo Scenario Controls: Weighted Traffic Splitting (Path: `/`)
# ------------------------------------------------------------------------------
weight-50-50: ## Route 50% Tokyo / 50% Osaka on `/` (Active-Active even split)
	kubectl apply --context=$(CLUSTER_TOKYO) -f manifests/04-httproute-active-active-50-50.yaml

weight-100-0: ## Route 100% Tokyo / 0% Osaka on `/` (Tokyo Primary)
	kubectl apply --context=$(CLUSTER_TOKYO) -f manifests/05-httproute-tokyo-100-osaka-0.yaml

weight-0-100: ## Route 0% Tokyo / 100% Osaka on `/` (Planned Cutover to Osaka)
	kubectl apply --context=$(CLUSTER_TOKYO) -f manifests/06-httproute-tokyo-0-osaka-100.yaml

# ------------------------------------------------------------------------------
# Demo Scenario Controls: Unplanned Regional Outage & Automatic Failover (Path: `/auto`)
# ------------------------------------------------------------------------------
simulate-tokyo-outage: ## Scale Tokyo `whereami` Deployment to 0 replicas to trigger automatic failover to Osaka
	kubectl scale deployment/whereami --replicas=0 --context=$(CLUSTER_TOKYO) -n $(NAMESPACE)

recover-tokyo: ## Restore Tokyo `whereami` Deployment to 1 replica (automatic failback)
	kubectl scale deployment/whereami --replicas=1 --context=$(CLUSTER_TOKYO) -n $(NAMESPACE)

simulate-osaka-outage: ## Scale Osaka `whereami` Deployment to 0 replicas to trigger automatic failover to Tokyo
	kubectl scale deployment/whereami --replicas=0 --context=$(CLUSTER_OSAKA) -n $(NAMESPACE)

recover-osaka: ## Restore Osaka `whereami` Deployment to 1 replica
	kubectl scale deployment/whereami --replicas=1 --context=$(CLUSTER_OSAKA) -n $(NAMESPACE)

# ------------------------------------------------------------------------------
# Live Visual Customer Demo Monitors
# ------------------------------------------------------------------------------
monitor-weighted: ## Launch live visual monitor on `/` (Weighted Traffic Split)
	./scripts/03-live-demo-monitor.sh / 0.5

monitor-auto: ## Launch live visual monitor on `/auto` (Proximity & Health-Check Auto-Failover)
	./scripts/03-live-demo-monitor.sh /auto 0.5

cleanup: ## Safely delete HTTPRoute, Gateway, and Namespace resources
	./scripts/99-cleanup.sh
