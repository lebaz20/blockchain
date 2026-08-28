#!/bin/bash
#
# run-ablation-study.sh
#
# Ablation study for EnhancedBFT at NPS=4 (16 nodes, 5 faulty, 4 shards).
# Runs A, B, C in parallel — each on its own isolated AWS cluster.
#
#   Run A — full ENH        (ENABLE_PIPELINING=1, ENABLE_SHARD_MERGE=1)
#   Run B — no pipelining   (ENABLE_PIPELINING=0, ENABLE_SHARD_MERGE=1)
#   Run C — no shard merge  (ENABLE_PIPELINING=1, ENABLE_SHARD_MERGE=0)
#
# Identical parameters for all three:
#   nodes=16, NPS=4, faulty=5 (~33%), threshold=200, threads=1000, duration=300s
#
# Usage:
#   ./run-ablation-study.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log() { echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
banner() {
    log "${CYAN}═══════════════════════════════════════════════════${NC}"
    log "${CYAN}  $*${NC}"
    log "${CYAN}═══════════════════════════════════════════════════${NC}"
}

AK=$(grep -o 'aws-access-key [^ ]*'   run-on-aws.txt | head -1 | cut -d' ' -f2)
AS=$(grep -o 'aws-secret-key [^ \\]*' run-on-aws.txt | head -1 | cut -d' ' -f2)

NODES=16; NPS=4; FAULTY=6; THRESHOLD=200; THREADS=1000; DURATION=300

TS=$(date +%Y%m%d_%H%M%S)

banner "Ablation study — launching A, B, C in parallel"
log "nodes=${NODES} NPS=${NPS} faulty=${FAULTY} threads=${THREADS} duration=${DURATION}s threshold=${THRESHOLD}"

launch_condition() {
    local label="$1"
    local pipeline="$2"
    local shard_merge="$3"

    local out_dir="$SCRIPT_DIR/journal-ablation-${label}-${TS}"
    local log_file="$SCRIPT_DIR/jlog-ablation-${label}-${TS}.log"

    log "  → Launching ${label} (pipeline=${pipeline} shard_merge=${shard_merge})"

    bash "$SCRIPT_DIR/run-on-aws-cluster.sh" \
        --nodes "$NODES" \
        --deploy-nps "$NPS" \
        --deploy-faulty "$FAULTY" \
        --journal-mode \
        --num-runs 1 \
        --journal-systems "enhanced" \
        --journal-output "$out_dir" \
        --deploy-jmeter-duration "$DURATION" \
        --deploy-jmeter-threads "$THREADS" \
        --deploy-tx-threshold "$THRESHOLD" \
        --deploy-enable-shard-merge "$shard_merge" \
        --deploy-enable-pipelining "$pipeline" \
        --aws-access-key "$AK" \
        --aws-secret-key "$AS" \
        > "$log_file" 2>&1
    echo $?
}

# Launch all three in parallel, capture PIDs
launch_condition "A-full-enh"      1 1 & PID_A=$!
launch_condition "B-no-pipeline"   0 1 & PID_B=$!
launch_condition "C-no-shardmerge" 1 0 & PID_C=$!

log "All three launched — waiting for completion..."
log "  A (full ENH)     pid=$PID_A  → jlog-ablation-A-full-enh-${TS}.log"
log "  B (no pipeline)  pid=$PID_B  → jlog-ablation-B-no-pipeline-${TS}.log"
log "  C (no shard mrg) pid=$PID_C  → jlog-ablation-C-no-shardmerge-${TS}.log"

wait $PID_A; EXIT_A=$?
wait $PID_B; EXIT_B=$?
wait $PID_C; EXIT_C=$?

banner "Ablation study complete"
[[ $EXIT_A -eq 0 ]] && log "${GREEN}✓ A (full ENH)       PASS${NC}" || log "${RED}✗ A (full ENH)       FAIL (exit=$EXIT_A)${NC}"
[[ $EXIT_B -eq 0 ]] && log "${GREEN}✓ B (no pipeline)    PASS${NC}" || log "${RED}✗ B (no pipeline)    FAIL (exit=$EXIT_B)${NC}"
[[ $EXIT_C -eq 0 ]] && log "${GREEN}✓ C (no shard merge) PASS${NC}" || log "${RED}✗ C (no shard merge) FAIL (exit=$EXIT_C)${NC}"

[[ $EXIT_A -eq 0 && $EXIT_B -eq 0 && $EXIT_C -eq 0 ]] || exit 1
