#!/usr/bin/env bash
# ==============================================================================
# 03-live-demo-monitor.sh
# Live Terminal Dashboard for Customer Demonstrations of GKE Multi-Cluster Gateway.
# Continuously polls the Global Gateway VIP, parses the `whereami` JSON payload,
# and renders real-time Tokyo vs. Osaka traffic distribution, latency, and status.
#
# Usage:
#   ./scripts/03-live-demo-monitor.sh [PATH] [INTERVAL_SEC]
# Examples:
#   ./scripts/03-live-demo-monitor.sh /       0.5   # Monitor weighted split route
#   ./scripts/03-live-demo-monitor.sh /auto   0.5   # Monitor proximity/failover route
# ==============================================================================
set -euo pipefail
export PATH="$HOME/google-cloud-sdk/bin:$PATH"

TARGET_PATH="${1:-/}"
SLEEP_INTERVAL="${2:-0.5}"
CLUSTER_TOKYO="${CLUSTER_TOKYO:-gke-tokyo}"
NAMESPACE="${NAMESPACE:-whereami-demo}"
GATEWAY_NAME="${GATEWAY_NAME:-external-global-gateway}"

# ANSI Color Codes for Visual Customer Presentation
BOLD="\033[1m"
DIM="\033[2m"
BLUE="\033[1;34m"    # Tokyo (asia-northeast1)
GREEN="\033[1;32m"   # Osaka (asia-northeast2)
YELLOW="\033[1;33m"
RED="\033[1;31m"
CYAN="\033[1;36m"
RESET="\033[0m"

if [[ -z "${GATEWAY_VIP:-}" ]]; then
  GATEWAY_VIP="$(kubectl get gateway "${GATEWAY_NAME}" \
    --context="${CLUSTER_TOKYO}" \
    -n "${NAMESPACE}" \
    -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || true)"
fi

if [[ -z "${GATEWAY_VIP}" ]]; then
  echo -e "${RED}ERROR: Could not resolve Gateway VIP from '${GATEWAY_NAME}' in namespace '${NAMESPACE}'.${RESET}" >&2
  echo "Set GATEWAY_VIP manually (e.g., export GATEWAY_VIP=34.x.x.x) or verify Gateway status." >&2
  exit 1
fi

URL="http://${GATEWAY_VIP}${TARGET_PATH}"

TOTAL_REQ=0
TOKYO_COUNT=0
OSAKA_COUNT=0
ERROR_COUNT=0

# Rolling window (last 20 requests) for instantaneous visual responsiveness during live switchovers
declare -a WINDOW=()
WINDOW_SIZE=20

render_bar() {
  local tokyo_pct=$1
  local osaka_pct=$2
  local width=30
  local tokyo_blocks=$(( (tokyo_pct * width + 50) / 100 ))
  local osaka_blocks=$(( width - tokyo_blocks ))
  local bar=""
  for ((i=0; i<tokyo_blocks; i++)); do bar+="${BLUE}█${RESET}"; done
  for ((i=0; i<osaka_blocks; i++)); do bar+="${GREEN}█${RESET}"; done
  echo -e "[${bar}]"
}

echo -e "${BOLD}========================================================================================${RESET}"
echo -e "${BOLD} GKE Multi-Cluster Gateway Live Customer Demo Monitor${RESET}"
echo -e " Target Endpoint : ${CYAN}${URL}${RESET} (Interval: ${SLEEP_INTERVAL}s)"
echo -e " Legend          : ${BLUE}■ Tokyo (asia-northeast1)${RESET} | ${GREEN}■ Osaka (asia-northeast2)${RESET} | ${RED}■ Error/5xx${RESET}"
echo -e " Press Ctrl+C to stop."
echo -e "${BOLD}========================================================================================${RESET}"
printf "${DIM}%-5s | %-8s | %-22s | %-17s | %-28s | %s${RESET}\n" \
  "REQ#" "HTTP/LAT" "METADATA (BACKEND)" "CLUSTER / ZONE" "POD NAME" "LAST ${WINDOW_SIZE} SPLIT (T:O)"
echo "----------------------------------------------------------------------------------------"

while true; do
  TOTAL_REQ=$((TOTAL_REQ + 1))

  # Capture response body, HTTP status code, and total time in ms
  RAW_OUT="$(curl -s -m 3 -w "\n%{http_code} %{time_total}" "${URL}" 2>/dev/null || echo -e "\n000 0.000")"
  STATUS_LINE="$(echo "${RAW_OUT}" | tail -n 1)"
  BODY="$(echo "${RAW_OUT}" | sed '$d')"

  HTTP_CODE="$(echo "${STATUS_LINE}" | awk '{print $1}')"
  TIME_SEC="$(echo "${STATUS_LINE}" | awk '{print $2}')"
  LATENCY_MS="$(awk -v t="${TIME_SEC}" 'BEGIN { printf "%d", t * 1000 }')"

  if [[ "${HTTP_CODE}" == "200" ]]; then
    CLUSTER="$(echo "${BODY}" | grep -o '"cluster_name": *"[^"]*"' | head -n1 | cut -d'"' -f4 || echo "unknown")"
    ZONE="$(echo "${BODY}" | grep -o '"zone": *"[^"]*"' | head -n1 | cut -d'"' -f4 || echo "unknown")"
    POD="$(echo "${BODY}" | grep -o '"pod_name": *"[^"]*"' | head -n1 | cut -d'"' -f4 || echo "unknown")"
    META="$(echo "${BODY}" | grep -o '"metadata": *"[^"]*"' | head -n1 | cut -d'"' -f4 || echo "unknown")"

    if [[ "${META}" == *"tokyo"* || "${ZONE}" == *"asia-northeast1"* ]]; then
      TOKYO_COUNT=$((TOKYO_COUNT + 1))
      REGION_TAG="T"
      COLOR="${BLUE}"
    elif [[ "${META}" == *"osaka"* || "${ZONE}" == *"asia-northeast2"* ]]; then
      OSAKA_COUNT=$((OSAKA_COUNT + 1))
      REGION_TAG="O"
      COLOR="${GREEN}"
    else
      REGION_TAG="?"
      COLOR="${YELLOW}"
    fi
  else
    ERROR_COUNT=$((ERROR_COUNT + 1))
    REGION_TAG="E"
    COLOR="${RED}"
    META="HTTP_${HTTP_CODE}"
    ZONE="unhealthy/abort"
    POD="-"
  fi

  # Update rolling window of last N requests
  WINDOW+=("${REGION_TAG}")
  if [[ ${#WINDOW[@]} -gt ${WINDOW_SIZE} ]]; then
    WINDOW=("${WINDOW[@]:1}")
  fi

  WIN_T=0
  WIN_O=0
  for item in "${WINDOW[@]}"; do
    [[ "${item}" == "T" ]] && WIN_T=$((WIN_T + 1))
    [[ "${item}" == "O" ]] && WIN_O=$((WIN_O + 1))
  done
  WIN_VALID=$((WIN_T + WIN_O))
  if [[ ${WIN_VALID} -gt 0 ]]; then
    WIN_T_PCT=$(( (WIN_T * 100) / WIN_VALID ))
    WIN_O_PCT=$(( 100 - WIN_T_PCT ))
  else
    WIN_T_PCT=0
    WIN_O_PCT=0
  fi

  BAR="$(render_bar "${WIN_T_PCT}" "${WIN_O_PCT}")"

  printf "#%-4d | %b%3s%b %3dms | %b%-22s%b | %-17s | %-28s | %s %b%3d%%%b:%b%3d%%%b (Total T:%d O:%d Err:%d)\n" \
    "${TOTAL_REQ}" \
    "${COLOR}" "${HTTP_CODE}" "${RESET}" "${LATENCY_MS}" \
    "${COLOR}" "${META}" "${RESET}" \
    "${ZONE}" \
    "${POD}" \
    "${BAR}" \
    "${BLUE}" "${WIN_T_PCT}" "${RESET}" "${GREEN}" "${WIN_O_PCT}" "${RESET}" \
    "${TOKYO_COUNT}" "${OSAKA_COUNT}" "${ERROR_COUNT}"

  sleep "${SLEEP_INTERVAL}"
done
