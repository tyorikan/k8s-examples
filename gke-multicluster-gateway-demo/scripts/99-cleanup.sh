#!/usr/bin/env bash
# ==============================================================================
# 99-cleanup.sh
# Safely tears down GKE Multi-Cluster Gateway resources in the strict order
# required to avoid leaked Google Cloud Load Balancer forwarding rules / NEGs.
# ==============================================================================
set -euo pipefail
export PATH="$HOME/google-cloud-sdk/bin:$PATH"

PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null)}"
VPC_NAME="${VPC_NAME:-mcg-demo-vpc}"
SUBNET_TOKYO="${SUBNET_TOKYO:-mcg-subnet-tokyo}"
SUBNET_OSAKA="${SUBNET_OSAKA:-mcg-subnet-osaka}"
REGION_TOKYO="${REGION_TOKYO:-asia-northeast1}"
REGION_OSAKA="${REGION_OSAKA:-asia-northeast2}"
CLUSTER_TOKYO="${CLUSTER_TOKYO:-gke-tokyo}"
CLUSTER_OSAKA="${CLUSTER_OSAKA:-gke-osaka}"
NAMESPACE="whereami-demo"

echo "=============================================================================="
echo "Cleaning Up GKE Multi-Cluster Gateway Demo Resources"
echo "  IMPORTANT: Deleting HTTPRoute & Gateway BEFORE disabling Fleet Ingress"
echo "             or deleting clusters prevents leaked GCLB resources."
echo "=============================================================================="

# 1. Delete HTTPRoute and Gateway on the Config Cluster first
echo "[Step 1/4] Deleting HTTPRoute, Gateway, and HealthCheckPolicies on ${CLUSTER_TOKYO}..."
kubectl delete httproute whereami-route --context="${CLUSTER_TOKYO}" -n "${NAMESPACE}" --ignore-not-found
kubectl delete gateway external-global-gateway --context="${CLUSTER_TOKYO}" -n "${NAMESPACE}" --ignore-not-found
kubectl delete healthcheckpolicy --all --context="${CLUSTER_TOKYO}" -n "${NAMESPACE}" --ignore-not-found

echo "  -> Waiting 60 seconds for GKE Multi-Cluster Gateway controller to deprovision Global Load Balancer..."
sleep 60

# 2. Delete ServiceExports and Workloads in Both Clusters
echo "[Step 2/4] Deleting ServiceExports and workloads in ${CLUSTER_TOKYO} and ${CLUSTER_OSAKA}..."
kubectl delete namespace "${NAMESPACE}" --context="${CLUSTER_TOKYO}" --ignore-not-found
kubectl delete namespace "${NAMESPACE}" --context="${CLUSTER_OSAKA}" --ignore-not-found

# 3. Disable Fleet Ingress & Multi-Cluster Services
echo "[Step 3/4] Disabling Fleet Multi-Cluster Ingress and Multi-Cluster Services..."
gcloud container fleet ingress disable --project="${PROJECT_ID}" --quiet || true
gcloud container fleet multi-cluster-services disable --project="${PROJECT_ID}" --quiet || true

# 4. Delete GKE Clusters & VPC Network (Optional: set DELETE_INFRA=true to delete clusters)
if [[ "${DELETE_INFRA:-false}" == "true" ]]; then
  echo "[Step 4/4] Deleting GKE clusters (${CLUSTER_TOKYO}, ${CLUSTER_OSAKA}) and VPC (${VPC_NAME})..."
  gcloud container clusters delete "${CLUSTER_TOKYO}" --region="${REGION_TOKYO}" --project="${PROJECT_ID}" --quiet &
  PID_T=$!
  gcloud container clusters delete "${CLUSTER_OSAKA}" --region="${REGION_OSAKA}" --project="${PROJECT_ID}" --quiet &
  PID_O=$!
  wait "${PID_T}"
  wait "${PID_O}"

  gcloud compute firewall-rules delete "${VPC_NAME}-allow-gclb-health-checks" --project="${PROJECT_ID}" --quiet || true
  gcloud compute networks subnets delete "${SUBNET_TOKYO}" --region="${REGION_TOKYO}" --project="${PROJECT_ID}" --quiet || true
  gcloud compute networks subnets delete "${SUBNET_OSAKA}" --region="${REGION_OSAKA}" --project="${PROJECT_ID}" --quiet || true
  gcloud compute networks delete "${VPC_NAME}" --project="${PROJECT_ID}" --quiet || true
else
  echo "[Step 4/4] Skipping GKE cluster & VPC deletion (run 'DELETE_INFRA=true ./scripts/99-cleanup.sh' to delete clusters)."
fi

echo "Cleanup complete!"
