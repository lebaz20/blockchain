#!/bin/bash
# Local vertical-scaling study: 3 shards, 0 faulty nodes, NPS ∈ {4,8,16,32}.
# Runs on a laptop via Rancher Desktop / Docker Desktop Kubernetes.
#
# Usage:
#   bash run-local-vertical.sh                        # both systems, NPS=4,8,16,32
#   bash run-local-vertical.sh enhanced               # enhanced only, all NPS
#   bash run-local-vertical.sh rapidchain             # rapidchain only, all NPS
#   bash run-local-vertical.sh enhanced 4,8           # enhanced, NPS=4 and NPS=8
#   bash run-local-vertical.sh both 4,8,16            # both systems, NPS=4,8,16
#
# Extra env vars passed through to both scripts (examples):
#   JMETER_DURATION=60 bash run-local-vertical.sh enhanced 4
#   POD_MEMORY_MIB=256 bash run-local-vertical.sh rapidchain 8
#
# Prerequisites:
#   - Rancher Desktop running with Kubernetes enabled
#   - Docker images built locally (start.sh builds them automatically)
#   - JMeter installed and in PATH
#   - kubectl pointing at the local cluster

set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$SCRIPT_DIR"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

SYSTEM=${1:-both}
NPS_LIST=$(echo "${2:-4,8,16,32}" | tr ',' ' ')

if [[ "$SYSTEM" != "enhanced" && "$SYSTEM" != "rapidchain" && "$SYSTEM" != "both" ]]; then
    echo "Usage: $0 [enhanced|rapidchain|both] [nps,nps,...]"
    echo "  e.g.  $0 enhanced 4,8"
    echo "        $0 both 4,8,16,32"
    exit 1
fi

# ── Preflight ─────────────────────────────────────────────────────────────────
echo -e "${BLUE}${BOLD}Preflight checks...${NC}"

if ! command -v kubectl &>/dev/null; then
    echo -e "${RED}ERROR: kubectl not found in PATH.${NC}"; exit 1
fi

if ! kubectl get nodes &>/dev/null; then
    echo -e "${RED}ERROR: kubectl cannot reach the cluster.${NC}"
    echo "  → Start Rancher Desktop and enable Kubernetes, then retry."
    exit 1
fi

if ! command -v jmeter &>/dev/null; then
    echo -e "${RED}ERROR: jmeter not found in PATH.${NC}"
    echo "  → Install JMeter: brew install jmeter"
    exit 1
fi

NODE_INFO=$(kubectl get nodes --no-headers 2>/dev/null | head -1)
echo -e "${GREEN}✓ Kubernetes node: ${NODE_INFO}${NC}"

# Warn for large NPS values about total pod count
for NPS in $NPS_LIST; do
    TOTAL=$((3 * NPS))
    if [ "$TOTAL" -ge 48 ]; then
        MEM_CAP=$((128 + 8 * NPS))
        TOTAL_MEM=$(( (TOTAL + 1) * MEM_CAP ))
        echo -e "${YELLOW}  NPS=${NPS}: ${TOTAL} pods × ${MEM_CAP}MiB limit = ${TOTAL_MEM}MiB total limits${NC}"
        echo -e "${YELLOW}  (Actual RSS is typically 40–60% of limit; Rancher Desktop needs ≥8GiB VM RAM)${NC}"
    fi
done
echo ""

# ── Run one combination ───────────────────────────────────────────────────────
PASS_COUNT=0
FAIL_COUNT=0
RESULTS_LINES=()

run_one() {
    local system=$1
    local nps=$2
    local total=$((3 * nps))
    local mem_cap; mem_cap=$(python3 -c "print(max(256, 128 + 8 * ${nps}))")
    local dir="pbft-${system}"
    local system_upper
    system_upper=$(echo "$system" | tr '[:lower:]' '[:upper:]')

    echo ""
    echo -e "${BLUE}${BOLD}══════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}${BOLD}  ${system_upper} | NPS=${nps} | ${total} nodes | 3 shards | 0 faulty${NC}"
    echo -e "${BLUE}${BOLD}  Pod memory cap: ${mem_cap}MiB | LOCAL_MODE=1${NC}"
    echo -e "${BLUE}${BOLD}══════════════════════════════════════════════════════════${NC}"

    if [ ! -d "$dir" ]; then
        echo -e "${RED}ERROR: directory '${dir}' not found.${NC}"
        RESULTS_LINES+=("  ${RED}✗${NC} ${system} NPS=${nps}: directory not found")
        FAIL_COUNT=$((FAIL_COUNT + 1))
        return
    fi

    pushd "$dir" > /dev/null

    set +e
    LOCAL_MODE=1 \
      NUMBER_OF_NODES=$total \
      NUMBER_OF_NODES_PER_SHARD=$nps \
      NUMBER_OF_FAULTY_NODES=0 \
      bash run-performance-test.sh
    local exit_code=$?
    set -e

    popd > /dev/null

    if [ $exit_code -eq 0 ]; then
        local latest_stats
        latest_stats=$(ls "${dir}/performance-results/"*-stats.csv 2>/dev/null | tail -1)
        local avg_round=""
        if [ -n "$latest_stats" ]; then
            avg_round=$(grep -i "Median Round" "$latest_stats" 2>/dev/null | awk -F',' '{print $2}' | tr -d ' ')
            avg_round=" | avgRoundMs≈${avg_round}"
        fi
        echo -e "${GREEN}✓ ${system} NPS=${nps} completed${avg_round}${NC}"
        RESULTS_LINES+=("  ✓ ${system_upper} NPS=${nps} (N=${total}): OK${avg_round}")
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        echo -e "${RED}✗ ${system} NPS=${nps} FAILED (exit ${exit_code})${NC}"
        RESULTS_LINES+=("  ✗ ${system_upper} NPS=${nps} (N=${total}): FAILED (exit ${exit_code})")
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}

# ── Main loop ─────────────────────────────────────────────────────────────────
for NPS in $NPS_LIST; do
    if [[ "$SYSTEM" == "enhanced" || "$SYSTEM" == "both" ]]; then
        run_one "enhanced" "$NPS"
    fi
    if [[ "$SYSTEM" == "rapidchain" || "$SYSTEM" == "both" ]]; then
        run_one "rapidchain" "$NPS"
    fi
done

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${BLUE}${BOLD}══════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}${BOLD}  SUMMARY  (${PASS_COUNT} passed, ${FAIL_COUNT} failed)${NC}"
echo -e "${BLUE}${BOLD}══════════════════════════════════════════════════════════${NC}"
for line in "${RESULTS_LINES[@]}"; do
    echo -e "$line"
done

echo ""
echo -e "${BOLD}Stats CSVs:${NC}"
if [[ "$SYSTEM" != "rapidchain" ]]; then
    ls pbft-enhanced/performance-results/*-stats.csv 2>/dev/null | tail -8 || true
fi
if [[ "$SYSTEM" != "enhanced" ]]; then
    ls pbft-rapidchain/performance-results/*-stats.csv 2>/dev/null | tail -8 || true
fi

if [ "$FAIL_COUNT" -gt 0 ]; then
    exit 1
fi
