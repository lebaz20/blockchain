#!/bin/bash
#
# run-alternating-study.sh
#
# Runs NPS=16 journal study with alternating fresh clusters:
#   Round 1: fresh cluster → RapidChain run 1 → teardown → wait → fresh cluster → Enhanced run 1 → teardown
#   Round 2: same
#   Round 3: same
#
# Each run gets its own EC2 cluster so memory accumulates fresh each time,
# eliminating the OOM-induced degradation seen when 3 consecutive runs share
# a cluster (5→2→1 block pattern).
#
# Results land in: journal-alternating-nps16-TIMESTAMP/
#   rapidchain-run{1,2,3}/   — downloaded from each RC cluster
#   enhanced-run{1,2,3}/     — downloaded from each ENH cluster
#
# Usage:
#   bash run-alternating-study.sh
#   NUM_ROUNDS=3 bash run-alternating-study.sh   (default)
#
# Estimated time: ~25 min per round, ~75 min total.
# Estimated cost: ~$2/round, ~$6 total (c6i.xlarge master + 48 × c6i.large agents).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

NUM_ROUNDS="${NUM_ROUNDS:-3}"
NPS="${DEPLOY_NPS:-16}"
NODES="${DEPLOY_NODES:-48}"
FAULTY="${DEPLOY_FAULTY:-15}"
JMETER_DURATION="${DEPLOY_JMETER_DURATION:-300}"
POD_MEMORY_MIB="${DEPLOY_POD_MEMORY_MIB:-3072}"
NODE_OPTIONS="${DEPLOY_NODE_OPTIONS:---max-old-space-size=2600}"

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
RESULTS_DIR="$SCRIPT_DIR/journal-alternating-nps${NPS}-${TIMESTAMP}"
LOG_DIR="$SCRIPT_DIR/vertical-study-logs"
mkdir -p "$RESULTS_DIR" "$LOG_DIR"

AK=$(grep -o 'aws-access-key [^ ]*'   run-on-aws.txt 2>/dev/null | head -1 | cut -d' ' -f2 || true)
AS=$(grep -o 'aws-secret-key [^ \\]*' run-on-aws.txt 2>/dev/null | head -1 | cut -d' ' -f2 || true)

if [[ -z "$AK" || -z "$AS" ]]; then
    echo "ERROR: AWS credentials not found in run-on-aws.txt" >&2
    exit 1
fi

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

RC_TOTAL_BLOCKS=0
ENH_TOTAL_BLOCKS=0
FAILED_RUNS=()

run_single() {
    local system="$1"   # rapidchain | enhanced
    local round="$2"    # 1, 2, 3
    local system_upper
    system_upper=$(echo "$system" | tr '[:lower:]' '[:upper:]')
    local run_log="$LOG_DIR/${system}-round${round}-${TIMESTAMP}.log"
    local dest="$RESULTS_DIR/${system}-run${round}"

    log "════════════════════════════════════════════════"
    log "  ${system_upper} run ${round}/${NUM_ROUNDS}"
    log "  Log: $run_log"
    log "════════════════════════════════════════════════"

    local exit_code=0
    bash "$SCRIPT_DIR/run-on-aws-cluster.sh" \
        --nodes "$NODES" \
        --deploy-nps "$NPS" \
        --deploy-faulty "$FAULTY" \
        --journal-mode \
        --num-runs 1 \
        --journal-systems "$system" \
        --deploy-jmeter-duration "$JMETER_DURATION" \
        --deploy-pod-memory-mib "$POD_MEMORY_MIB" \
        --deploy-node-options "$NODE_OPTIONS" \
        --deploy-tx-threshold "${DEPLOY_TX_THRESHOLD:-1000}" \
        --aws-access-key "$AK" \
        --aws-secret-key "$AS" \
        2>&1 | tee "$run_log" || exit_code=$?

    # Copy result directory from the auto-generated journal-* folder
    local src_pattern="$SCRIPT_DIR/journal-*-${TIMESTAMP%_*}*/${system}-run1"
    local latest_src
    latest_src=$(ls -td $SCRIPT_DIR/journal-*/${system}-run1 2>/dev/null | head -1 || true)
    if [[ -n "$latest_src" && -d "$latest_src" ]]; then
        mkdir -p "$dest"
        cp -r "$latest_src/." "$dest/"
        log "  Results copied → $dest"
    else
        log "  WARNING: could not find ${system}-run1 result directory"
    fi

    if [[ $exit_code -ne 0 ]]; then
        log "  ${system_upper} run ${round} FAILED (exit=$exit_code)"
        FAILED_RUNS+=("${system}-run${round}")
        return 1
    fi

    # Extract block count for verification
    local blocks=0
    local stats_file
    stats_file=$(ls "$dest"/performance-results/pbft-*-stats.csv 2>/dev/null | head -1 || true)
    if [[ -f "$stats_file" ]]; then
        blocks=$(grep '^Total Blocks Created,' "$stats_file" | cut -d, -f2 || echo 0)
    fi
    log "  ${system_upper} run ${round}: blocks=$blocks"

    if [[ "$system" == "rapidchain" ]]; then
        RC_TOTAL_BLOCKS=$((RC_TOTAL_BLOCKS + blocks))
    else
        ENH_TOTAL_BLOCKS=$((ENH_TOTAL_BLOCKS + blocks))
    fi

    return 0
}

wait_for_termination() {
    log "Waiting 3 min for EC2 instances to fully terminate before next cluster..."
    sleep 180
}

# ── Main loop ────────────────────────────────────────────────────────────────
log "Starting alternating study: ${NUM_ROUNDS} rounds, NPS=${NPS}"
log "Results: $RESULTS_DIR"
log ""

for round in $(seq 1 "$NUM_ROUNDS"); do
    log "══════════════ ROUND ${round}/${NUM_ROUNDS} ══════════════"

    # RapidChain
    run_single rapidchain "$round" || true
    wait_for_termination

    # Enhanced
    run_single enhanced "$round" || true

    if [[ $round -lt $NUM_ROUNDS ]]; then
        wait_for_termination
    fi

    log ""
done

# ── Final verification ────────────────────────────────────────────────────────
log "══════════════════════════════════════════════"
log "Alternating study complete."
log "  RapidChain total blocks: $RC_TOTAL_BLOCKS (across $NUM_ROUNDS runs)"
log "  Enhanced   total blocks: $ENH_TOTAL_BLOCKS (across $NUM_ROUNDS runs)"
log "  Failed runs: ${FAILED_RUNS[*]:-none}"
log ""

if [[ $RC_TOTAL_BLOCKS -eq 0 ]]; then
    log "ERROR: RapidChain produced 0 blocks across all runs. Check logs."
    exit 1
fi

if [[ $ENH_TOTAL_BLOCKS -le $RC_TOTAL_BLOCKS ]]; then
    log "WARNING: Enhanced did not outperform RapidChain ($ENH_TOTAL_BLOCKS <= $RC_TOTAL_BLOCKS)."
    log "  Check Enhanced merge logic. Results are in $RESULTS_DIR"
else
    log "✓ Enhanced outperforms RapidChain: $ENH_TOTAL_BLOCKS blocks vs $RC_TOTAL_BLOCKS blocks"
fi

log "Results: $RESULTS_DIR"
log "══════════════════════════════════════════════"

[[ ${#FAILED_RUNS[@]} -gt 0 ]] && exit 1 || exit 0
