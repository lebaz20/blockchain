#!/bin/bash
#
# run-vertical-study.sh
#
# NPS=16: RC then Enhanced, 300 threads, 300s, threshold=4000 — both systems same params.
# NPS=32: threshold=500, 100 threads, 90s, c6i.xlarge — both systems same params.
#
# RC and Enhanced run as separate cluster launches sharing the same journal output dir,
# so different thread counts per system are possible without changing this invariant.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

LOG_DIR="$SCRIPT_DIR/vertical-study-logs"
mkdir -p "$LOG_DIR"

AK=$(grep -o 'aws-access-key [^ ]*'   run-on-aws.txt | head -1 | cut -d' ' -f2)
AS=$(grep -o 'aws-secret-key [^ \\]*' run-on-aws.txt | head -1 | cut -d' ' -f2)

TIMESTAMP=$(date +%Y%m%d_%H%M%S)

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

# ── NPS=16 ────────────────────────────────────────────────────────────────────
NPS16_DIR="$SCRIPT_DIR/journal-vertical-nps16-$TIMESTAMP"
NPS16_RC_LOG="$LOG_DIR/nps16-rc-$TIMESTAMP.log"
NPS16_ENH_LOG="$LOG_DIR/nps16-enh-$TIMESTAMP.log"

log "═══════════════════════════════════════"
log "NPS=16 RC (48 nodes, 15 faulty, 300 threads, 300s)"
log "Log: $NPS16_RC_LOG"
log "═══════════════════════════════════════"

NPS16_RC_EXIT=0
bash "$SCRIPT_DIR/run-on-aws-cluster.sh" \
    --nodes 48 \
    --deploy-nps 16 \
    --deploy-faulty 15 \
    --journal-mode \
    --num-runs 1 \
    --journal-systems "rapidchain" \
    --journal-output "$NPS16_DIR" \
    --deploy-jmeter-duration 300 \
    --deploy-jmeter-threads 300 \
    --deploy-tx-threshold 4000 \
    --deploy-pod-memory-mib 3584 \
    --deploy-node-options "--max-old-space-size=3200" \
    --aws-access-key "$AK" \
    --aws-secret-key "$AS" \
    2>&1 | tee "$NPS16_RC_LOG" || NPS16_RC_EXIT=$?

log "NPS=16 RC finished (exit=$NPS16_RC_EXIT)"

if [[ $NPS16_RC_EXIT -ne 0 ]]; then
    log "NPS=16 RC FAILED — aborting."
    exit 1
fi

log "Waiting 3 min for cluster teardown before Enhanced..."
sleep 180

log "═══════════════════════════════════════"
log "NPS=16 Enhanced (48 nodes, 15 faulty, 300 threads, 300s)"
log "Log: $NPS16_ENH_LOG"
log "═══════════════════════════════════════"

NPS16_ENH_EXIT=0
bash "$SCRIPT_DIR/run-on-aws-cluster.sh" \
    --nodes 48 \
    --deploy-nps 16 \
    --deploy-faulty 15 \
    --journal-mode \
    --num-runs 1 \
    --journal-systems "enhanced" \
    --journal-output "$NPS16_DIR" \
    --deploy-jmeter-duration 300 \
    --deploy-jmeter-threads 300 \
    --deploy-tx-threshold 4000 \
    --deploy-pod-memory-mib 3584 \
    --deploy-node-options "--max-old-space-size=3200" \
    --aws-access-key "$AK" \
    --aws-secret-key "$AS" \
    2>&1 | tee "$NPS16_ENH_LOG" || NPS16_ENH_EXIT=$?

log "NPS=16 Enhanced finished (exit=$NPS16_ENH_EXIT)"

if [[ $NPS16_ENH_EXIT -ne 0 ]]; then
    log "NPS=16 Enhanced FAILED — aborting."
    exit 1
fi

log "Waiting 3 min for cluster teardown before NPS=32..."
sleep 180

# ── NPS=32 ────────────────────────────────────────────────────────────────────
NPS32_DIR="$SCRIPT_DIR/journal-vertical-nps32-$TIMESTAMP"
NPS32_RC_LOG="$LOG_DIR/nps32-rc-$TIMESTAMP.log"
NPS32_ENH_LOG="$LOG_DIR/nps32-enh-$TIMESTAMP.log"

log "═══════════════════════════════════════"
log "NPS=32 RC (96 nodes, 31 faulty, 100 threads, 90s)"
log "Log: $NPS32_RC_LOG"
log "═══════════════════════════════════════"

NPS32_RC_EXIT=0
bash "$SCRIPT_DIR/run-on-aws-cluster.sh" \
    --nodes 96 \
    --deploy-nps 32 \
    --deploy-faulty 31 \
    --journal-mode \
    --num-runs 1 \
    --journal-systems "rapidchain" \
    --journal-output "$NPS32_DIR" \
    --deploy-jmeter-duration 90 \
    --deploy-jmeter-threads 100 \
    --deploy-tx-threshold 500 \
    --agent-type c6i.xlarge \
    --deploy-pod-memory-mib 6144 \
    --deploy-node-options "--max-old-space-size=5000" \
    --aws-access-key "$AK" \
    --aws-secret-key "$AS" \
    2>&1 | tee "$NPS32_RC_LOG" || NPS32_RC_EXIT=$?

log "NPS=32 RC finished (exit=$NPS32_RC_EXIT)"

if [[ $NPS32_RC_EXIT -ne 0 ]]; then
    log "NPS=32 RC FAILED — aborting."
    exit 1
fi

log "Waiting 3 min for cluster teardown before NPS=32 Enhanced..."
sleep 180

log "═══════════════════════════════════════"
log "NPS=32 Enhanced (96 nodes, 31 faulty, 100 threads, 90s)"
log "Log: $NPS32_ENH_LOG"
log "═══════════════════════════════════════"

NPS32_ENH_EXIT=0
bash "$SCRIPT_DIR/run-on-aws-cluster.sh" \
    --nodes 96 \
    --deploy-nps 32 \
    --deploy-faulty 31 \
    --journal-mode \
    --num-runs 1 \
    --journal-systems "enhanced" \
    --journal-output "$NPS32_DIR" \
    --deploy-jmeter-duration 90 \
    --deploy-jmeter-threads 100 \
    --deploy-tx-threshold 500 \
    --agent-type c6i.xlarge \
    --deploy-pod-memory-mib 6144 \
    --deploy-node-options "--max-old-space-size=5000" \
    --aws-access-key "$AK" \
    --aws-secret-key "$AS" \
    2>&1 | tee "$NPS32_ENH_LOG" || NPS32_ENH_EXIT=$?

log "NPS=32 Enhanced finished (exit=$NPS32_ENH_EXIT)"

log "═══════════════════════════════════════"
log "Study complete."
log "  NPS16 RC=$NPS16_RC_EXIT Enhanced=$NPS16_ENH_EXIT"
log "  NPS32 RC=$NPS32_RC_EXIT Enhanced=$NPS32_ENH_EXIT"
log "  NPS16 results: $NPS16_DIR"
log "  NPS32 results: $NPS32_DIR"
log "═══════════════════════════════════════"

[[ $NPS16_RC_EXIT -ne 0 || $NPS16_ENH_EXIT -ne 0 || $NPS32_RC_EXIT -ne 0 || $NPS32_ENH_EXIT -ne 0 ]] && exit 1 || exit 0
