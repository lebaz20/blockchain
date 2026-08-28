#!/bin/bash
# RC + Enhanced in parallel on separate clusters.
# Pod memory: 3584 MiB (max safe for c6i.large/4GB). V8 heap capped at 3200 MiB
# (JS-heap exhaustion causes process exit; container OOM kill not the concern here).
# JMeter: 150 threads — reduced from 300 to keep the 33-node merged shard from OOM.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

LOG_DIR="$SCRIPT_DIR/vertical-study-logs"
mkdir -p "$LOG_DIR"

AK=$(grep -o 'aws-access-key [^ ]*'   run-on-aws.txt | head -1 | cut -d' ' -f2)
AS=$(grep -o 'aws-secret-key [^ \\]*' run-on-aws.txt | head -1 | cut -d' ' -f2)

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
SHARED_DIR="$SCRIPT_DIR/sanity-check-$TIMESTAMP"
mkdir -p "$SHARED_DIR"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

log "═══════════════════════════════════════"
log "Parallel sanity — output: $SHARED_DIR"
log "═══════════════════════════════════════"

RC_LOG="$LOG_DIR/sanity-rc-$TIMESTAMP.log"
ENH_LOG="$LOG_DIR/sanity-enh-$TIMESTAMP.log"

log "Launching RC and Enhanced in parallel..."

bash "$SCRIPT_DIR/run-on-aws-cluster.sh" \
    --nodes 48 \
    --deploy-nps 16 \
    --deploy-faulty 15 \
    --journal-mode \
    --num-runs 1 \
    --journal-systems "rapidchain" \
    --journal-output "$SHARED_DIR" \
    --deploy-jmeter-duration 300 \
    --deploy-jmeter-threads 150 \
    --deploy-tx-threshold 200 \
    --deploy-pod-memory-mib 3584 \
    --deploy-node-options "--max-old-space-size=3200" \
    --aws-access-key "$AK" \
    --aws-secret-key "$AS" \
    2>&1 | tee "$RC_LOG" &
RC_PID=$!

bash "$SCRIPT_DIR/run-on-aws-cluster.sh" \
    --nodes 48 \
    --deploy-nps 16 \
    --deploy-faulty 15 \
    --journal-mode \
    --num-runs 1 \
    --journal-systems "enhanced" \
    --journal-output "$SHARED_DIR" \
    --deploy-jmeter-duration 300 \
    --deploy-jmeter-threads 150 \
    --deploy-tx-threshold 200 \
    --deploy-pod-memory-mib 3584 \
    --deploy-node-options "--max-old-space-size=3200" \
    --aws-access-key "$AK" \
    --aws-secret-key "$AS" \
    2>&1 | tee "$ENH_LOG" &
ENH_PID=$!

log "RC PID=$RC_PID | Enhanced PID=$ENH_PID"
log "Waiting for both to complete..."

RC_EXIT=0; wait $RC_PID || RC_EXIT=$?
log "RC done (exit=$RC_EXIT)"

ENH_EXIT=0; wait $ENH_PID || ENH_EXIT=$?
log "Enhanced done (exit=$ENH_EXIT)"

log "═══════════════════════════════════════"
log "Sanity check complete. RC=$RC_EXIT  Enhanced=$ENH_EXIT"
log "Results: $SHARED_DIR"
log "═══════════════════════════════════════"

[[ $RC_EXIT -ne 0 || $ENH_EXIT -ne 0 ]] && exit 1 || exit 0
