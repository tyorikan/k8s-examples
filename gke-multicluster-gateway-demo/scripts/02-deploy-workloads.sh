#!/usr/bin/env bash
# ==============================================================================
# 02-deploy-workloads.sh
# Deploys the `whereami` application, Services, ServiceExports, Gateway,
# HealthCheckPolicies, and initial Active-Active HTTPRoute across Tokyo & Osaka.
# ==============================================================================
set -euo pipefail
export PATH="$HOME/google-cloud-sdk/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST_DIR="${SCRIPT_DIR}/../manifests"

CLUSTER_TOKYO="${CLUSTER_TOKYO:-gke-tokyo}"
CLUSTER_OSAKA="${CLUSTER_OSAKA:-gke-osaka}"
NAMESPACE="whereami-demo"

echo "=============================================================================="
echo "Deploying Workloads & Multi-Cluster Gateway Resources"
echo "  Config & Tokyo Cluster : ${CLUSTER_TOKYO}"
echo "  Osaka Cluster          : ${CLUSTER_OSAKA}"
echo "  Namespace              : ${NAMESPACE}"
echo "=============================================================================="

# ------------------------------------------------------------------------------
# 1. Create Identical Namespace in Both Clusters (Namespace Sameness)
# ------------------------------------------------------------------------------
echo "[Step 1/5] Creating namespace '${NAMESPACE}' in ${CLUSTER_TOKYO} and ${CLUSTER_OSAKA}..."
kubectl apply --context="${CLUSTER_TOKYO}" -f "${MANIFEST_DIR}/00-namespace.yaml"
kubectl apply --context="${CLUSTER_OSAKA}" -f "${MANIFEST_DIR}/00-namespace.yaml"

# ------------------------------------------------------------------------------
# 2. Deploy Regional Workloads, Services, and ServiceExports
# ------------------------------------------------------------------------------
echo "[Step 2/5] Deploying Tokyo workload & ServiceExports (${CLUSTER_TOKYO})..."
kubectl apply --context="${CLUSTER_TOKYO}" -f "${MANIFEST_DIR}/01-tokyo-workload.yaml"

echo "[Step 3/5] Deploying Osaka workload & ServiceExports (${CLUSTER_OSAKA})..."
kubectl apply --context="${CLUSTER_OSAKA}" -f "${MANIFEST_DIR}/02-osaka-workload.yaml"

echo "  -> Waiting for whereami Deployments to roll out in both regions (Autopilot node provisioning may take 2-4 mins)..."
kubectl rollout status deployment/whereami --context="${CLUSTER_TOKYO}" -n "${NAMESPACE}" --timeout=360s &
PID_ROLLOUT_TOKYO=$!
kubectl rollout status deployment/whereami --context="${CLUSTER_OSAKA}" -n "${NAMESPACE}" --timeout=360s &
PID_ROLLOUT_OSAKA=$!
wait "${PID_ROLLOUT_TOKYO}"
wait "${PID_ROLLOUT_OSAKA}"

# ------------------------------------------------------------------------------
# 3. Wait for Multi-Cluster Service Controller to Generate ServiceImports
# ------------------------------------------------------------------------------
echo "[Step 4/5] Waiting for ServiceImports (whereami-global, whereami-tokyo, whereami-osaka) on Config Cluster (${CLUSTER_TOKYO})..."
echo "  (Note: Initial MCS propagation across a new Fleet can take 2-5 minutes)"
for i in {1..60}; do
  COUNT="$(kubectl get serviceimports --context="${CLUSTER_TOKYO}" -n "${NAMESPACE}" --no-headers 2>/dev/null | { grep -cE 'whereami-(global|tokyo|osaka)' || true; } | tr -d ' ')"
  if [[ "${COUNT:-0}" -ge 3 ]]; then
    echo "  -> All 3 ServiceImports are available on ${CLUSTER_TOKYO}:"
    kubectl get serviceimports --context="${CLUSTER_TOKYO}" -n "${NAMESPACE}"
    break
  fi
  echo "  -> Found ${COUNT:-0}/3 ServiceImports (attempt ${i}/60, waiting 10s)..."
  sleep 10
done

# ------------------------------------------------------------------------------
# 4. Deploy Global Gateway, HealthCheckPolicies, and Active-Active HTTPRoute
# ------------------------------------------------------------------------------
echo "[Step 5/5] Applying Gateway, HealthCheckPolicies, and initial 50:50 Active-Active HTTPRoute to Config Cluster (${CLUSTER_TOKYO})..."
kubectl apply --context="${CLUSTER_TOKYO}" -f "${MANIFEST_DIR}/03-gateway.yaml"
kubectl apply --context="${CLUSTER_TOKYO}" -f "${MANIFEST_DIR}/04-httproute-active-active-50-50.yaml"

echo "  -> Waiting for Global External Application Load Balancer VIP assignment..."
echo "     (Provisioning GCLB forwarding rules and NEGs typically takes 3-8 minutes)"
GATEWAY_VIP=""
for i in {1..60}; do
  GATEWAY_VIP="$(kubectl get gateway external-global-gateway \
    --context="${CLUSTER_TOKYO}" \
    -n "${NAMESPACE}" \
    -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || true)"
  PROGRAMMED="$(kubectl get gateway external-global-gateway \
    --context="${CLUSTER_TOKYO}" \
    -n "${NAMESPACE}" \
    -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null || true)"
  if [[ -n "${GATEWAY_VIP}" && "${PROGRAMMED}" == "True" ]]; then
    break
  fi
  echo "  -> Gateway VIP: '${GATEWAY_VIP:-pending}', Programmed: '${PROGRAMMED:-False}' (attempt ${i}/60, waiting 10s)..."
  sleep 10
done

echo "  -> Waiting for Global Load Balancer edge propagation and backend health checks (HTTP 200)..."
for i in {1..30}; do
  HTTP_STATUS="$(curl -s -m 3 -o /dev/null -w '%{http_code}' "http://${GATEWAY_VIP}/" 2>/dev/null || echo "000")"
  if [[ "${HTTP_STATUS}" == "200" ]]; then
    echo "  -> HTTP 200 OK received from http://${GATEWAY_VIP}/ !"
    break
  fi
  echo "  -> Current HTTP status: ${HTTP_STATUS} (attempt ${i}/30, waiting 10s)..."
  sleep 10
done

echo "=============================================================================="
echo "Deployment Complete!"
echo "  Gateway VIP : http://${GATEWAY_VIP}"
echo ""
echo "Try the endpoints:"
echo "  1. Weighted Active-Active (50/50) : curl http://${GATEWAY_VIP}/"
echo "  2. Auto Proximity & Failover      : curl http://${GATEWAY_VIP}/auto"
echo "  3. Pinned to Tokyo                : curl http://${GATEWAY_VIP}/tokyo"
echo "  4. Pinned to Osaka                : curl http://${GATEWAY_VIP}/osaka"
echo ""
echo "Run the live visual monitor for your customer demo:"
echo "  ./scripts/03-live-demo-monitor.sh /"
echo "=============================================================================="
