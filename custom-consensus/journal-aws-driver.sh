#!/bin/bash
#
# journal-aws-driver.sh
#
# Outer driver for the journal-grade comparison.  Loops over node counts and
# provisions a fresh EC2 instance per scale via the existing run-on-aws.sh,
# letting that script auto-select the right-sized instance type.  On each
# instance, runs journal-comparison.sh — which itself loops fault levels × runs
# × systems — so one instance carries the full subgrid for that scale before
# being torn down.
#
# Cost model:
#   On-Demand by default for benchmark stability (no mid-run reclaims).
#   Instance type is auto-sized by node count (per-pod CPU fixed at 0.30 vCPU):
#     ≤16  → c6i.2xlarge  (8 vCPU,  16 GiB, ~$0.34/hr On-Demand)
#     ≤32  → c6i.4xlarge  (16 vCPU, 32 GiB, ~$0.68/hr On-Demand)
#     ≤64  → c6i.8xlarge  (32 vCPU, 64 GiB, ~$1.36/hr On-Demand)
#     ≤100 → c6i.16xlarge (64 vCPU, 128 GiB, ~$2.72/hr On-Demand)
#     ≤200 → c6i.24xlarge (96 vCPU, 192 GiB, ~$4.08/hr On-Demand)
#     ≤300 → c6i.32xlarge (128 vCPU,256 GiB, ~$5.44/hr On-Demand)
#     >300 → c7i.48xlarge (192 vCPU,384 GiB, ~$8.16/hr On-Demand)
#
#   So the 5-scale grid auto-spans:
#     100 nodes  → c6i.16xlarge  (~$2.72/hr × ~1h ≈ $2.72)
#     200 nodes  → c6i.24xlarge  (~$4.08/hr × ~1h ≈ $4.08)
#     300 nodes  → c6i.32xlarge  (~$5.44/hr × ~1h ≈ $5.44)
#     400 nodes  → c7i.48xlarge  (~$8.16/hr × ~1.3h ≈ $10.60)
#     500 nodes  → c7i.48xlarge  (~$8.16/hr × ~1.5h ≈ $12.24)
#   Total ≈ $35 On-Demand for the full grid.  Pass USE_SPOT=1 for ~70% off
#   at the cost of possible mid-run termination.
#
# Runs per cell: NUM_RUNS independent JMeter runs per (system, nodes, fault%).
#   Default 3 runs gives ~95 % CI half-width ~2.5 SD/√3 ≈ 1.4 SD.
#   Set NUM_RUNS=5 for tighter CIs (~2.4 SD/√5 ≈ 1.1 SD); cost scales linearly.
#
# Resource sampling: monitor-resources.sh attaches to the remote cluster during
# each JMeter run, capturing per-pod CPU/memory/bandwidth at SAMPLE_INTERVAL.
#
# Usage:
#   ./journal-aws-driver.sh                              # full grid (5 scales × 2 faults × 3 runs × 2 systems = 60 runs)
#   NODE_COUNTS="100 300 500" ./journal-aws-driver.sh    # quick subset
#   NUM_RUNS=5 FAULT_LEVELS="33" ./journal-aws-driver.sh # only adversarial, tighter CI
#   USE_SPOT=1 ./journal-aws-driver.sh                   # opt into Spot (~70% cheaper, can be reclaimed mid-run)
#
# Reads AWS credentials from run-on-aws.txt (same format as run-multi-test.sh).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ── parse credentials from run-on-aws.txt ────────────────────────────────────
TXT="$SCRIPT_DIR/run-on-aws.txt"
if [[ ! -f "$TXT" ]]; then
    echo "run-on-aws.txt not found — cannot read AWS credentials" >&2
    exit 1
fi
AWS_KEY=$(grep -o -- '--aws-access-key [^ ]*'    "$TXT" | awk '{print $2}' | head -1)
AWS_SECRET=$(grep -o -- '--aws-secret-key [^ \\]*' "$TXT" | awk '{print $2}' | head -1)
if [[ -z "$AWS_KEY" || -z "$AWS_SECRET" ]]; then
    echo "Could not parse credentials from $TXT" >&2
    exit 1
fi

# ── test matrix ──────────────────────────────────────────────────────────────
NODE_COUNTS="${NODE_COUNTS:-100 200 300 400 500}"
FAULT_LEVELS="${FAULT_LEVELS:-0 33}"
NUM_RUNS="${NUM_RUNS:-3}"
MAX_RETRIES="${MAX_RETRIES:-2}"
NODES_PER_SHARD="${NODES_PER_SHARD:-100}"     # matched between systems

# CPU-per-pod scales with shard peer count. Formula MUST match the one in
# journal-comparison.sh so the instance we provision has enough vCPU headroom
# for the CPU limit the shim will apply. 0.30 vCPU works for 4-node shards;
# 100-node shards need ~1.5 vCPU each or the peer-mesh collapses (WebSocket
# ECONNRESET storm → /stats starves → mesh reports FAULTY).
if [[ -z "${CPU_PER_POD:-}" ]]; then
    CPU_PER_POD=$(python3 -c "
import math
nps = float($NODES_PER_SHARD)
val = max(0.30, min(4.0, 0.30 * math.sqrt(nps / 4.0)))
print(f'{val:.2f}')
")
fi
export CPU_PER_POD

# Same scaling logic for pod memory (must match journal-comparison.sh formula).
# 256Mi baseline handles NPS=4; larger shards need proportionally more RAM for
# the P2P mesh + PBFT state or pods OOMKill under load.
if [[ -z "${POD_MEMORY_MIB:-}" ]]; then
    POD_MEMORY_MIB=$(python3 -c "
import math
nps = float($NODES_PER_SHARD)
val = max(256, min(4096, int(256 * math.sqrt(nps / 4.0))))
print(val)
")
fi
export POD_MEMORY_MIB

USE_SPOT="${USE_SPOT:-0}"              # 0 = On-Demand (default, stable), 1 = Spot (cheaper, interruptible)
RUNNER="$SCRIPT_DIR/run-on-aws.sh"
COMPARE_ORIG="$SCRIPT_DIR/compare-performance.sh"
COMPARE_BACKUP="$SCRIPT_DIR/.compare-performance.sh.bak"

[[ -x "$RUNNER" ]] || { echo "Missing executable: $RUNNER" >&2; exit 1; }
[[ -f "$COMPARE_ORIG" ]] || { echo "Missing $COMPARE_ORIG" >&2; exit 1; }

# ── colours / logging ────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'
log() { echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
banner() {
    log "${CYAN}═══════════════════════════════════════════════════${NC}"
    log "${CYAN}$*${NC}"
    log "${CYAN}═══════════════════════════════════════════════════${NC}"
}

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
DRIVER_OUT="$SCRIPT_DIR/journal-grid-${TIMESTAMP}"
mkdir -p "$DRIVER_OUT"

# ── temporarily replace compare-performance.sh with a self-contained shim.
#    run-on-aws.sh hard-codes upload of compare-performance.sh only — it does
#    NOT upload journal-comparison.sh / monitor-resources.sh / compute-stats.py.
#    So the shim embeds those three helpers as base64 heredocs and decodes
#    them at runtime on the remote.  This way no modification to run-on-aws.sh
#    is needed; the single uploaded file carries everything.
install_shim() {
    local scale="$1" faults_csv="$2"
    if [[ -f "$COMPARE_ORIG" && ! -f "$COMPARE_BACKUP" ]]; then
        cp "$COMPARE_ORIG" "$COMPARE_BACKUP"
    fi

    local _journal_b64 _monitor_b64 _stats_b64
    _journal_b64=$(base64 < "$SCRIPT_DIR/journal-comparison.sh" | tr -d '\n')
    _monitor_b64=$(base64 < "$SCRIPT_DIR/monitor-resources.sh"  | tr -d '\n')
    _stats_b64=$(base64   < "$SCRIPT_DIR/compute-stats.py"      | tr -d '\n')

    cat > "$COMPARE_ORIG" <<EOF
#!/bin/bash
# Auto-generated self-contained shim by journal-aws-driver.sh.
# Decodes the three journal-grade helpers from base64 heredocs into ./, then
# launches journal-comparison.sh with the per-scale subgrid.
set -uo pipefail
cd "\$(dirname "\${BASH_SOURCE[0]}")"

echo '$_journal_b64' | base64 -d > journal-comparison.sh
echo '$_monitor_b64' | base64 -d > monitor-resources.sh
echo '$_stats_b64'   | base64 -d > compute-stats.py
chmod +x journal-comparison.sh monitor-resources.sh compute-stats.py

export NODE_COUNTS="$scale"
export FAULT_LEVELS="$faults_csv"
export NUM_RUNS="$NUM_RUNS"
export ENHANCED_NODES_PER_SHARD="${ENHANCED_NODES_PER_SHARD:-100}"
export RAPIDCHAIN_NODES_PER_SHARD="${RAPIDCHAIN_NODES_PER_SHARD:-100}"
exec ./journal-comparison.sh
EOF
    chmod +x "$COMPARE_ORIG"
}

restore_compare() {
    if [[ -f "$COMPARE_BACKUP" ]]; then
        mv -f "$COMPARE_BACKUP" "$COMPARE_ORIG"
        log "${GREEN}✓ restored original compare-performance.sh${NC}"
    fi
}

# Unconditional AWS nuke on driver exit — belt-and-suspenders safety net.
# The per-scale `run-on-aws.sh` trap already handles its own targeted cleanup
# (specific instance / SG / key by ID); this catches everything the targeted
# path missed: SIGKILL'd child processes, network-drop during terminate-instances,
# mid-grid crashes between scales, or bugs we haven't discovered yet.
#
# Note: nuke-aws.sh's filters (blockchain* / k3s* / custom-consensus* prefixes)
# scope the deletion so unrelated AWS work in the same account is not affected.
# Fleets/Launch Templates/Spot requests are cleaned unconditionally as those
# are always ours in this project.
final_cleanup() {
    local exit_code=$?
    # Detach the trap immediately so a signal received during cleanup doesn't
    # re-invoke us recursively.
    trap - EXIT INT TERM

    restore_compare

    log ""
    banner "Final safety-net AWS nuke (unconditional)"
    log "Cleaning up any AWS resources this driver may have left behind."
    log "Uses ${SCRIPT_DIR}/nuke-aws.sh (name-filtered to our project prefix)."
    local nuke_log="${DRIVER_OUT:-/tmp}/nuke-final.log"
    if bash "${SCRIPT_DIR}/nuke-aws.sh" 2>&1 | tee "$nuke_log"; then
        log "${GREEN}✓ nuke-aws.sh completed${NC}"
    else
        log "${YELLOW}⚠ nuke-aws.sh exited non-zero — inspect $nuke_log${NC}"
    fi

    log ""
    log "Driver finished with exit code $exit_code"
    exit "$exit_code"
}
trap final_cleanup EXIT INT TERM

# ── dry-run banner ───────────────────────────────────────────────────────────
banner "Journal-grade AWS-driven comparison"
log "Test matrix:"
log "  Scales         : $NODE_COUNTS"
log "  Fault levels   : $FAULT_LEVELS %"
log "  Runs/cell      : $NUM_RUNS"
log "  Nodes/shard    : $NODES_PER_SHARD"
log "  CPU/pod        : $CPU_PER_POD vCPU (auto-sized for peer mesh at NPS=$NODES_PER_SHARD; override CPU_PER_POD=<n>)"
log "  MEM/pod        : ${POD_MEMORY_MIB} Mi (auto-sized for NPS=$NODES_PER_SHARD; override POD_MEMORY_MIB=<n>)"
log "  Pricing        : $([[ "$USE_SPOT" == "1" ]] && echo "Spot (~70% cheaper, interruptible)" || echo "On-Demand (default, stable)")"
log "  Output         : $DRIVER_OUT"
log ""
log "Per scale: one EC2 instance (auto-sized by node count) carries all"
log "fault levels × runs × both systems before being torn down."
log ""

# Faults as CSV for the shim (space-separated → space-preserved by env passing)
FAULTS_CSV="$FAULT_LEVELS"

OVERALL_PASS=0
OVERALL_FAIL=0
SCALE_INDEX=0

for NODES in $NODE_COUNTS; do
    SCALE_INDEX=$((SCALE_INDEX + 1))
    banner "[$SCALE_INDEX] Scale = $NODES nodes — provisioning EC2 ..."

    # Install the shim that will run on the remote in place of compare-performance.sh
    install_shim "$NODES" "$FAULTS_CSV"

    # Also stage the helper scripts so they get rsync'd by run-on-aws.sh into
    # ~/blockchain/custom-consensus/ on the remote.  We do this by copying them
    # alongside the local versions (run-on-aws.sh rsyncs the dir).
    cp -f "$SCRIPT_DIR/journal-comparison.sh" "$SCRIPT_DIR/journal-comparison.sh"  # no-op, kept for clarity
    cp -f "$SCRIPT_DIR/monitor-resources.sh"  "$SCRIPT_DIR/monitor-resources.sh"
    cp -f "$SCRIPT_DIR/compute-stats.py"       "$SCRIPT_DIR/compute-stats.py"

    # Build the run-on-aws.sh invocation
    RUNNER_ARGS=(
        --aws-access-key "$AWS_KEY"
        --aws-secret-key "$AWS_SECRET"
        --nodes "$NODES"
        --cpu-per-pod "$CPU_PER_POD"
        --pod-memory-mib "$POD_MEMORY_MIB"
    )
    if [[ "$USE_SPOT" == "1" ]]; then
        RUNNER_ARGS+=(--spot)
    fi

    # Retry on Spot interruption (capacity outage)
    attempt=1
    success=false
    while [[ $attempt -le $MAX_RETRIES ]]; do
        log "${BLUE}attempt $attempt/$MAX_RETRIES — running run-on-aws.sh${NC}"

        # Per-scale log file so partial failures are inspectable
        SCALE_LOG="$DRIVER_OUT/scale-N${NODES}-attempt${attempt}.log"
        bash "$RUNNER" "${RUNNER_ARGS[@]}" 2>&1 | tee "$SCALE_LOG"
        exit_code=${PIPESTATUS[0]}

        if [[ $exit_code -eq 0 ]]; then
            log "${GREEN}✓ scale=$NODES passed (attempt $attempt)${NC}"
            success=true
            OVERALL_PASS=$((OVERALL_PASS + 1))
            break
        else
            log "${YELLOW}⚠ scale=$NODES failed (exit $exit_code, attempt $attempt/$MAX_RETRIES)${NC}"
            if [[ $attempt -lt $MAX_RETRIES ]]; then
                log "Waiting 60s before retry..."
                sleep 60
            fi
        fi
        attempt=$((attempt + 1))
    done

    if [[ "$success" != "true" ]]; then
        log "${RED}✗ scale=$NODES failed after $MAX_RETRIES attempts — moving on${NC}"
        OVERALL_FAIL=$((OVERALL_FAIL + 1))
    fi

    # ── pull back the journal results directory from this run.
    #    run-on-aws.sh downloads results into ./performance-results-AWS- ...
    #    but the journal-comparison.sh writes to journal-results-<TS>/ — we
    #    pull that explicitly via the cleanup hooks in run-on-aws.sh, or fall
    #    back to scp here.  Both paths are handled by the cleanup trap inside
    #    run-on-aws.sh which downloads the entire test directory.
    log "Scale $NODES results in: $DRIVER_OUT/ (per-scale log: $SCALE_LOG)"
done

restore_compare

# ── post-process: merge per-scale journal-results-* into a single grid ───────
banner "Merging per-scale results into unified grid"
MERGED="$DRIVER_OUT/journal-results-merged"
mkdir -p "$MERGED"
# Per-scale results are pulled into ~/blockchain/custom-consensus/journal-results-<TS>
# on each instance, then downloaded by run-on-aws.sh's cleanup trap to local
# results directories.  Adjust the glob below if your run-on-aws.sh download
# path differs.
for dir in "$SCRIPT_DIR"/journal-results-*/ "$SCRIPT_DIR"/performance-results-AWS-*/journal-results-*/; do
    [[ -d "$dir" ]] || continue
    # Copy config-* subdirs into the merged tree
    for cfg in "$dir"/config-*; do
        [[ -d "$cfg" ]] || continue
        cp -r "$cfg" "$MERGED/" 2>/dev/null || true
    done
done

# Aggregate across all scales
if compgen -G "$MERGED/config-*" > /dev/null; then
    log "Running final aggregation across all scales..."
    python3 "$SCRIPT_DIR/compute-stats.py" "$MERGED" || true

    # Generate the cross-scale journal report
    REPORT="$MERGED/journal-report.md"
    python3 "$SCRIPT_DIR/journal-comparison.sh" >/dev/null 2>&1 || true
    if [[ -f "$MERGED/journal-stats.csv" ]]; then
        log "${GREEN}✓ Merged aggregate: $MERGED/journal-stats.csv${NC}"
    fi
fi

# ── summary ──────────────────────────────────────────────────────────────────
banner "Driver finished"
log "${GREEN}Passed: $OVERALL_PASS${NC}   ${RED}Failed: $OVERALL_FAIL${NC}"
log "Driver output : $DRIVER_OUT"
log "Per-scale logs: $DRIVER_OUT/scale-N*-attempt*.log"
log "Merged grid   : $MERGED  (journal-stats.csv, journal-report.md)"
[[ $OVERALL_FAIL -gt 0 ]] && exit 1
exit 0
