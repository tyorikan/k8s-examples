#!/usr/bin/env bash
# ==============================================================================
# 01-setup-infra.sh
# Provisions VPC, Tokyo & Osaka GKE Autopilot Clusters, Fleet Memberships,
# Multi-Cluster Services (MCS), and Multi-Cluster Gateway Controller.
# ==============================================================================
set -euo pipefail
export PATH="$HOME/google-cloud-sdk/bin:$PATH"
export CLOUDSDK_CORE_DISABLE_PROMPTS=1

# ------------------------------------------------------------------------------
# Configurable Environment Variables
# ------------------------------------------------------------------------------
PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null)}"
if [[ -z "${PROJECT_ID}" ]]; then
  echo "ERROR: PROJECT_ID is not set. Run 'export PROJECT_ID=your-project-id' first." >&2
  exit 1
fi

PROJECT_NUMBER="$(gcloud projects describe "${PROJECT_ID}" --format='value(projectNumber)')"

VPC_NAME="${VPC_NAME:-mcg-demo-vpc}"
SUBNET_TOKYO="${SUBNET_TOKYO:-mcg-subnet-tokyo}"
SUBNET_OSAKA="${SUBNET_OSAKA:-mcg-subnet-osaka}"
CIDR_TOKYO="${CIDR_TOKYO:-10.10.0.0/20}"
CIDR_OSAKA="${CIDR_OSAKA:-10.20.0.0/20}"

REGION_TOKYO="${REGION_TOKYO:-asia-northeast1}"
REGION_OSAKA="${REGION_OSAKA:-asia-northeast2}"

CLUSTER_TOKYO="${CLUSTER_TOKYO:-gke-tokyo}"
CLUSTER_OSAKA="${CLUSTER_OSAKA:-gke-osaka}"

echo "=============================================================================="
echo "GKE Multi-Cluster Gateway Demo - Infrastructure Provisioning"
echo "  Project ID     : ${PROJECT_ID} (${PROJECT_NUMBER})"
echo "  VPC Network    : ${VPC_NAME}"
echo "  Tokyo Cluster  : ${CLUSTER_TOKYO} (${REGION_TOKYO}) [Config & Workload Cluster]"
echo "  Osaka Cluster  : ${CLUSTER_OSAKA} (${REGION_OSAKA}) [Workload Cluster]"
echo "=============================================================================="

# ------------------------------------------------------------------------------
# 1. Enable Required Google Cloud APIs
# ------------------------------------------------------------------------------
echo "[Step 1/7] Enabling required Google Cloud APIs..."
gcloud services enable \
  container.googleapis.com \
  compute.googleapis.com \
  trafficdirector.googleapis.com \
  multiclusterservicediscovery.googleapis.com \
  multiclusteringress.googleapis.com \
  gkehub.googleapis.com \
  dns.googleapis.com \
  cloudresourcemanager.googleapis.com \
  --project="${PROJECT_ID}"

# ------------------------------------------------------------------------------
# 2. Create Custom VPC Network & Regional Subnets (Tokyo & Osaka)
# ------------------------------------------------------------------------------
echo "[Step 2/7] Creating VPC network (${VPC_NAME}) and regional subnets..."
if ! gcloud compute networks describe "${VPC_NAME}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
  gcloud compute networks create "${VPC_NAME}" \
    --subnet-mode=custom \
    --project="${PROJECT_ID}"
else
  echo "  -> VPC ${VPC_NAME} already exists. Skipping creation."
fi

if ! gcloud compute networks subnets describe "${SUBNET_TOKYO}" --region="${REGION_TOKYO}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
  gcloud compute networks subnets create "${SUBNET_TOKYO}" \
    --network="${VPC_NAME}" \
    --region="${REGION_TOKYO}" \
    --range="${CIDR_TOKYO}" \
    --project="${PROJECT_ID}"
else
  echo "  -> Subnet ${SUBNET_TOKYO} already exists. Skipping creation."
fi

if ! gcloud compute networks subnets describe "${SUBNET_OSAKA}" --region="${REGION_OSAKA}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
  gcloud compute networks subnets create "${SUBNET_OSAKA}" \
    --network="${VPC_NAME}" \
    --region="${REGION_OSAKA}" \
    --range="${CIDR_OSAKA}" \
    --project="${PROJECT_ID}"
else
  echo "  -> Subnet ${SUBNET_OSAKA} already exists. Skipping creation."
fi

# Ensure Google Cloud Load Balancer Health Check probes (130.211.0.0/22, 35.191.0.0/16)
# are explicitly allowed to reach container ports in the custom VPC.
FW_RULE_NAME="${VPC_NAME}-allow-gclb-health-checks"
if ! gcloud compute firewall-rules describe "${FW_RULE_NAME}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
  gcloud compute firewall-rules create "${FW_RULE_NAME}" \
    --project="${PROJECT_ID}" \
    --network="${VPC_NAME}" \
    --direction=INGRESS \
    --allow=tcp:8080 \
    --source-ranges=130.211.0.0/22,35.191.0.0/16 \
    --description="Allow Google Cloud Load Balancer health checks to reach whereami Pods"
fi

# ------------------------------------------------------------------------------
# 3. Create GKE Autopilot Clusters in Tokyo and Osaka with Fleet Registration
# ------------------------------------------------------------------------------
# Note: GKE Autopilot automatically enables Workload Identity, Gateway API CRDs,
# and Container-Native Load Balancing (NEGs).
echo "[Step 3/7] Creating GKE Autopilot clusters in Tokyo and Osaka (in parallel)..."

create_tokyo_cluster() {
  if ! gcloud container clusters describe "${CLUSTER_TOKYO}" --region="${REGION_TOKYO}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
    gcloud container clusters create-auto "${CLUSTER_TOKYO}" \
      --region="${REGION_TOKYO}" \
      --network="${VPC_NAME}" \
      --subnetwork="${SUBNET_TOKYO}" \
      --enable-fleet \
      --project="${PROJECT_ID}"
  else
    echo "  -> Cluster ${CLUSTER_TOKYO} already exists."
  fi
}

create_osaka_cluster() {
  if ! gcloud container clusters describe "${CLUSTER_OSAKA}" --region="${REGION_OSAKA}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
    gcloud container clusters create-auto "${CLUSTER_OSAKA}" \
      --region="${REGION_OSAKA}" \
      --network="${VPC_NAME}" \
      --subnetwork="${SUBNET_OSAKA}" \
      --enable-fleet \
      --project="${PROJECT_ID}"
  else
    echo "  -> Cluster ${CLUSTER_OSAKA} already exists."
  fi
}

create_tokyo_cluster &
PID_TOKYO=$!
create_osaka_cluster &
PID_OSAKA=$!

wait "${PID_TOKYO}"
wait "${PID_OSAKA}"

echo "  -> Verifying Fleet memberships..."
gcloud container fleet memberships list --project="${PROJECT_ID}"

# ------------------------------------------------------------------------------
# 4. Configure Local kubectl Contexts (`gke-tokyo` and `gke-osaka`)
# ------------------------------------------------------------------------------
echo "[Step 4/7] Fetching cluster credentials and renaming kubectl contexts..."
gcloud container clusters get-credentials "${CLUSTER_TOKYO}" --region="${REGION_TOKYO}" --project="${PROJECT_ID}"
kubectl config delete-context "${CLUSTER_TOKYO}" >/dev/null 2>&1 || true
kubectl config rename-context "gke_${PROJECT_ID}_${REGION_TOKYO}_${CLUSTER_TOKYO}" "${CLUSTER_TOKYO}"

gcloud container clusters get-credentials "${CLUSTER_OSAKA}" --region="${REGION_OSAKA}" --project="${PROJECT_ID}"
kubectl config delete-context "${CLUSTER_OSAKA}" >/dev/null 2>&1 || true
kubectl config rename-context "gke_${PROJECT_ID}_${REGION_OSAKA}_${CLUSTER_OSAKA}" "${CLUSTER_OSAKA}"

# ------------------------------------------------------------------------------
# 5. Enable Multi-Cluster Services (MCS) & Configure Required IAM Bindings
# ------------------------------------------------------------------------------
echo "[Step 5/7] Enabling Multi-Cluster Services (MCS) in the Fleet..."
gcloud container fleet multi-cluster-services enable --project="${PROJECT_ID}"

echo "  -> Granting roles/compute.networkViewer to MCS Importer Workload Identity..."
gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
  --member="principal://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${PROJECT_ID}.svc.id.goog/subject/ns/gke-mcs/sa/gke-mcs-importer" \
  --role="roles/compute.networkViewer" \
  --condition=None \
  --project="${PROJECT_ID}" >/dev/null

echo "  -> Granting roles/multiclusterservicediscovery.serviceAgent to MCS Service Agent..."
gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:service-${PROJECT_NUMBER}@gcp-sa-mcsd.iam.gserviceaccount.com" \
  --role="roles/multiclusterservicediscovery.serviceAgent" \
  --condition=None \
  --project="${PROJECT_ID}" >/dev/null

# ------------------------------------------------------------------------------
# 6. Enable Multi-Cluster Gateway Controller (Config Cluster = gke-tokyo)
# ------------------------------------------------------------------------------
echo "[Step 6/7] Enabling Multi-Cluster Gateway with ${CLUSTER_TOKYO} as Config Cluster..."
if ! gcloud container fleet ingress describe --project="${PROJECT_ID}" >/dev/null 2>&1; then
  gcloud container fleet ingress enable \
    --config-membership="projects/${PROJECT_ID}/locations/${REGION_TOKYO}/memberships/${CLUSTER_TOKYO}" \
    --project="${PROJECT_ID}"
else
  gcloud container fleet ingress update \
    --config-membership="projects/${PROJECT_ID}/locations/${REGION_TOKYO}/memberships/${CLUSTER_TOKYO}" \
    --project="${PROJECT_ID}"
fi

echo "  -> Granting roles/container.admin to Multi-Cluster Ingress Service Agent..."
gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:service-${PROJECT_NUMBER}@gcp-sa-multiclusteringress.iam.gserviceaccount.com" \
  --role="roles/container.admin" \
  --condition=None \
  --project="${PROJECT_ID}" >/dev/null

# ------------------------------------------------------------------------------
# 7. Wait for `gke-l7-global-external-managed-mc` GatewayClass on Config Cluster
# ------------------------------------------------------------------------------
echo "[Step 7/7] Waiting for GatewayClass 'gke-l7-global-external-managed-mc' to become Accepted on ${CLUSTER_TOKYO}..."
for i in {1..30}; do
  ACCEPTED="$(kubectl get gatewayclass gke-l7-global-external-managed-mc \
    --context="${CLUSTER_TOKYO}" \
    -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}' 2>/dev/null || true)"
  if [[ "${ACCEPTED}" == "True" ]]; then
    echo "  -> GatewayClass 'gke-l7-global-external-managed-mc' is ACCEPTED and ready!"
    kubectl get gatewayclasses --context="${CLUSTER_TOKYO}"
    break
  fi
  echo "  -> Waiting for GatewayClass registration (attempt ${i}/30)..."
  sleep 10
done

kubectl config use-context "${CLUSTER_TOKYO}"
echo "=============================================================================="
echo "Infrastructure setup complete! Next step: run ./scripts/02-deploy-workloads.sh"
echo "=============================================================================="
