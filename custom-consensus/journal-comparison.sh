#!/bin/bash
#
# journal-comparison.sh
#
# Journal-grade controlled comparison of EnhancedBFT and PBFT-RapidChain under
# matched conditions, designed for repeatable submission-quality measurements.
#
# Test matrix:
#   Scales        : 100, 200, 300, 400, 500 nodes
#   Fault levels  : 0 % (benign) and 33 % (adversarial)
#   Repetitions   : NUM_RUNS (default 3) per cell, for mean ± SD ± 95 % CI
#   Systems       : pbft-rapidchain  and  pbft-enhanced
#
# Group 1 (test-condition) changes applied to both systems:
#   TRANSACTION_THRESHOLD     = 4000     (40× the small-batch default)
#   JMETER_THROUGHPUT (cap)   = 600000   req/min ≡ 10 000 req/s  (uncapped)
#   JMETER_DURATION           = 300      s   (long enough for steady-state)
#   CPU_LIMIT                 = scaled to (CPU_BUDGET_VCPU / N) — see below
#
# Group 2 (architectural) change applied to both systems:
#   NUMBER_OF_NODES_PER_SHARD = 100      (matches RapidChain paper exactly)
#
# CPU budget enforcement (default CPU_BUDGET_VCPU=160, leaving headroom on a
# 192-core EC2 host for kubelet / control-plane / network):
#   per-pod CPU = CPU_BUDGET_VCPU / NODE_COUNT
#   capped between 0.3 and 4.0 vCPU.
#
# Resource metrics collected per run:
#   CPU      (millicores, total + per-pod mean + per-pod peak)
#   Memory   (MiB,        total + per-pod mean + per-pod peak)
#   Bandwidth (MiB/s,     network RX + TX, sampled from /proc/net/dev)
# Captured by monitor-resources.sh running in the background during JMeter.
#
# Statistics produced by compute-stats.py:
#   For each (system, nodes, fault_pct) cell: mean, sample SD, 95 % CI
#   over the NUM_RUNS independent runs.
#
# Total cluster runs = 5 scales × 2 fault levels × 2 systems × NUM_RUNS
#                    = 60 runs when NUM_RUNS=3.
# At ~12 min/run (provision + warmup + 300 s test + teardown), expect ~12 h
# wall time.  The grid is sequential; intermediate results are written to
# disk after every run so partial completions are usable.
#
# Usage:
#   ./journal-comparison.sh
#   NUM_RUNS=5 ./journal-comparison.sh        # tighter CIs, 100 runs
#   NODE_COUNTS="100 300 500" ./journal-comparison.sh
#   FAULT_LEVELS="0" ./journal-comparison.sh  # benign only
#
# Output (per invocation):
#   journal-results-<TIMESTAMP>/
#     config-N<nodes>-f<faults>-r<run>/
#       pbft-rapidchain-summary.txt
#       pbft-rapidchain-stats.csv
#       pbft-rapidchain-resources.csv
#       pbft-enhanced-summary.txt
#       pbft-enhanced-stats.csv
#       pbft-enhanced-resources.csv
#     journal-stats.csv          # aggregated by compute-stats.py
#     journal-report.md          # paper-ready tables
#     run-log.txt                # full per-run log

set -uo pipefail

# ─── 0. Where am I, where's everything else ───────────────────────────────────
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$SCRIPT_DIR"

MONITOR_SCRIPT="$SCRIPT_DIR/monitor-resources.sh"
STATS_SCRIPT="$SCRIPT_DIR/compute-stats.py"
RAPIDCHAIN_DIR="$SCRIPT_DIR/pbft-rapidchain"
ENHANCED_DIR="$SCRIPT_DIR/pbft-enhanced"

for f in "$MONITOR_SCRIPT" "$STATS_SCRIPT"; do
    [[ -f "$f" ]] || { echo "Missing helper: $f" >&2; exit 1; }
    chmod +x "$f" 2>/dev/null || true
done
[[ -d "$RAPIDCHAIN_DIR" ]] || { echo "Missing $RAPIDCHAIN_DIR" >&2; exit 1; }
[[ -d "$ENHANCED_DIR"   ]] || { echo "Missing $ENHANCED_DIR"   >&2; exit 1; }

# ─── 1. Test-matrix configuration ────────────────────────────────────────────
NODE_COUNTS="${NODE_COUNTS:-100 200 300 400 500}"
FAULT_LEVELS="${FAULT_LEVELS:-0 33}"
NUM_RUNS="${NUM_RUNS:-3}"

# Group 1 — test conditions (identical for both systems)
export TRANSACTION_THRESHOLD="${TRANSACTION_THRESHOLD:-4000}"
export RAPIDCHAIN_THRESHOLD="${RAPIDCHAIN_THRESHOLD:-4000}"
export ENHANCED_THRESHOLD="${ENHANCED_THRESHOLD:-4000}"
export JMETER_THROUGHPUT="${JMETER_THROUGHPUT:-600000}"     # req/min = 10 000 req/s
export JMETER_DURATION="${JMETER_DURATION:-300}"
export JMETER_RAMP_UP="${JMETER_RAMP_UP:-10}"
export JMETER_RAMP_DOWN="${JMETER_RAMP_DOWN:-30}"
# JMeter threads: enough so the throughput cap is the bottleneck, not concurrency
export JMETER_THREADS="${JMETER_THREADS:-$(( (JMETER_THROUGHPUT + 99) / 100 ))}"

# Group 2 — architecture (matched 100-node shards / committees)
export ENHANCED_NODES_PER_SHARD="${ENHANCED_NODES_PER_SHARD:-100}"
export RAPIDCHAIN_NODES_PER_SHARD="${RAPIDCHAIN_NODES_PER_SHARD:-100}"

# Per-pod CPU is fixed across N so latency/throughput comparisons across scales
# aren't confounded by per-pod compute differences. But it MUST scale with the
# shard size: peer-mesh CPU cost is roughly linear in (NODES_PER_SHARD-1), and
# PBFT round message count is O(NODES_PER_SHARD²). 0.30 vCPU is enough for a
# 4-node shard (3 peers), but a 100-node shard (99 peers) at 0.30 vCPU pegs
# every pod at its limit — HTTP starves, /stats returns 200 rarely, the P2P
# mesh reports FAULTY, JMeter sees 88%+ errors. Empirically we saw this in the
# 2026-07-10 100-node run — see the diag snapshot for the observed collapse.
#
# Sizing rule: 0.30 × sqrt(NODES_PER_SHARD / 4), clamped to [0.30, 4.0].
#   NPS=4   → 0.30 vCPU   (baseline)
#   NPS=16  → 0.60 vCPU
#   NPS=25  → 0.75 vCPU
#   NPS=64  → 1.20 vCPU
#   NPS=100 → 1.50 vCPU
#   NPS=400 → 3.00 vCPU
# Override with CPU_PER_POD=<n> when tuning empirically.
compute_cpu_per_pod() {
    local nps="${1:-4}"
    python3 -c "
import math
nps = float($nps)
val = max(0.30, min(4.0, 0.30 * math.sqrt(nps / 4.0)))
print(f'{val:.2f}')
"
}
if [[ -z "${CPU_PER_POD:-}" ]]; then
    # Both systems get the same shard size (matched at 100 by default), so
    # either variable gives the same result. Use enhanced's since it's set first.
    CPU_PER_POD=$(compute_cpu_per_pod "$ENHANCED_NODES_PER_SHARD")
fi
CPU_BUDGET_VCPU="${CPU_BUDGET_VCPU:-}"   # unused when CPU_PER_POD is set

# Per-pod memory scales alongside CPU: at NPS=100 the P2P mesh state + PBFT
# vote pools + inflight-block state easily blow past 256Mi and pods OOMKill.
# Empirically observed 2026-07-11 at NPS=100 after the on(close) + jitter
# fixes made the mesh actually do work — 21/100 pods CrashLoopBackOff, 1
# OOMKilled. Baseline (NPS=4) works at 256Mi.
#
# Rule: 256 × sqrt(NODES_PER_SHARD / 4), clamped to [256, 4096] MiB.
#   NPS=4   → 256 Mi  (baseline)
#   NPS=16  → 512 Mi
#   NPS=25  → 640 Mi
#   NPS=64  → 1024 Mi
#   NPS=100 → 1280 Mi
#   NPS=400 → 2560 Mi
# Override with POD_MEMORY_MIB=<n> when tuning empirically.
compute_mem_per_pod_mib() {
    local nps="${1:-4}"
    python3 -c "
import math
nps = float($nps)
val = max(256, min(4096, int(256 * math.sqrt(nps / 4.0))))
print(val)
"
}
if [[ -z "${POD_MEMORY_MIB:-}" ]]; then
    POD_MEMORY_MIB=$(compute_mem_per_pod_mib "$ENHANCED_NODES_PER_SHARD")
fi
export POD_MEMORY_MIB

# Resource monitor sample interval (seconds)
export SAMPLE_INTERVAL="${SAMPLE_INTERVAL:-5}"

# ─── 2. Output directories ───────────────────────────────────────────────────
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
RESULTS_ROOT="$SCRIPT_DIR/journal-results-${TIMESTAMP}"
RUN_LOG="$RESULTS_ROOT/run-log.txt"
mkdir -p "$RESULTS_ROOT"

# ─── 3. Logging helpers ──────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    echo -e "$msg" | tee -a "$RUN_LOG"
}

banner() {
    log "${CYAN}═══════════════════════════════════════════════════${NC}"
    log "${CYAN}$*${NC}"
    log "${CYAN}═══════════════════════════════════════════════════${NC}"
}

# ─── 4. Per-pod CPU sizing ───────────────────────────────────────────────────
# Fixed at CPU_PER_POD vCPU across all scales for apples-to-apples comparison.
compute_cpu_limit() {
    printf "%s" "$CPU_PER_POD"
}

# ─── 5. Per-config dry-run summary (banner) ──────────────────────────────────
banner "Journal-grade EnhancedBFT vs RapidChain comparison"
log "Test matrix:"
log "  Scales       : $NODE_COUNTS"
log "  Fault levels : $FAULT_LEVELS %"
log "  Runs/cell    : $NUM_RUNS"
log "  Systems      : pbft-rapidchain, pbft-enhanced"
log ""
log "Group 1 — test conditions (identical for both systems):"
log "  TRANSACTION_THRESHOLD = $TRANSACTION_THRESHOLD"
log "  JMETER_THROUGHPUT cap = $JMETER_THROUGHPUT req/min ($((JMETER_THROUGHPUT/60)) req/s)"
log "  JMETER_DURATION       = ${JMETER_DURATION}s"
log "  CPU_PER_POD           = $CPU_PER_POD vCPU (auto-scaled for NODES_PER_SHARD=$ENHANCED_NODES_PER_SHARD)"
log "  POD_MEMORY_MIB        = ${POD_MEMORY_MIB} Mi (auto-scaled for NODES_PER_SHARD=$ENHANCED_NODES_PER_SHARD)"
log ""
log "Group 2 — architecture (matched):"
log "  NUMBER_OF_NODES_PER_SHARD = $ENHANCED_NODES_PER_SHARD (both systems)"
log ""
log "Results directory: $RESULTS_ROOT"
log ""

TOTAL_CONFIGS=0
for _ in $NODE_COUNTS; do for _ in $FAULT_LEVELS; do for _ in $(seq 1 "$NUM_RUNS"); do
    TOTAL_CONFIGS=$((TOTAL_CONFIGS + 1))
done; done; done
TOTAL_RUNS=$((TOTAL_CONFIGS * 2))
log "Total cluster runs to execute: $TOTAL_RUNS (≈ $((TOTAL_RUNS * 12)) min wall time)"
echo

# ─── 6. Cleanup helpers ──────────────────────────────────────────────────────
cleanup_cluster() {
    log "${YELLOW}Cleaning Kubernetes resources...${NC}"
    pkill -f "kubectl port-forward" 2>/dev/null || true
    pkill -f "monitor-resources.sh" 2>/dev/null || true
    kubectl delete pods --all --ignore-not-found=true --grace-period=1 --force 2>/dev/null || true
    kubectl delete service --field-selector metadata.name!=kubernetes \
        --ignore-not-found=true 2>/dev/null || true
    kubectl wait --for=delete pod --all --timeout=300s 2>/dev/null || true
}

# ─── 6b. Phase-file heartbeat + diagnostic snapshot ──────────────────────────
# Child scripts (run-performance-test.sh) write their current phase name to
# $PHASE_FILE at each Step. The heartbeat prints a compact "still on X after Ns"
# line every HEARTBEAT_INTERVAL seconds so the user always knows what's happening
# even when the child script is blocked waiting on the cluster (kubectl port-forward,
# readiness probe, JMeter, drain wait) and prints nothing.
export PHASE_FILE="${PHASE_FILE:-/tmp/bftperf-phase-$$}"
: > "$PHASE_FILE"
HEARTBEAT_INTERVAL="${HEARTBEAT_INTERVAL:-30}"
HEARTBEAT_PID=""

heartbeat_start() {
    local label="$1"
    local start_ts
    start_ts=$(date +%s)
    (
        # Detach from parent so kill -TERM on parent doesn't propagate immediately
        while sleep "$HEARTBEAT_INTERVAL"; do
            local elapsed=$(( $(date +%s) - start_ts ))
            local phase="(no phase file yet)"
            [[ -s "$PHASE_FILE" ]] && phase=$(cat "$PHASE_FILE" 2>/dev/null | tr -d '\n')
            printf "[%s] ${CYAN}♥ heartbeat [%s]${NC} %ds — phase: %s\n" \
                "$(date '+%Y-%m-%d %H:%M:%S')" "$label" "$elapsed" "$phase" \
                | tee -a "$RUN_LOG"
        done
    ) &
    HEARTBEAT_PID=$!
}

heartbeat_stop() {
    if [[ -n "$HEARTBEAT_PID" ]]; then
        kill "$HEARTBEAT_PID" 2>/dev/null || true
        wait "$HEARTBEAT_PID" 2>/dev/null || true
        HEARTBEAT_PID=""
    fi
}

# Diagnostic snapshot: dump cluster + host state when a run fails or times out.
# Called from run_single_system on non-zero exit, and once at script end from
# the INT/TERM trap. Output goes both to stdout (visible via SSH -t) and the log.
diag_snapshot() {
    local label="$1"
    log "${YELLOW}════════ DIAG SNAPSHOT (${label}) ════════${NC}"
    log "${YELLOW}--- current phase ---${NC}"
    [[ -s "$PHASE_FILE" ]] && cat "$PHASE_FILE" | tee -a "$RUN_LOG" || log "  (empty)"
    log "${YELLOW}--- kubectl get pods -A (non-Running) ---${NC}"
    kubectl get pods -A --no-headers 2>&1 | grep -v -E 'Running|Completed' | head -50 \
        | tee -a "$RUN_LOG" || true
    log "${YELLOW}--- kubectl get pods -A summary (status counts) ---${NC}"
    kubectl get pods -A --no-headers 2>&1 | awk '{print $4}' | sort | uniq -c \
        | tee -a "$RUN_LOG" || true
    log "${YELLOW}--- kubectl get events (last 30, all namespaces) ---${NC}"
    kubectl get events -A --sort-by=.lastTimestamp 2>&1 | tail -30 \
        | tee -a "$RUN_LOG" || true
    log "${YELLOW}--- top 10 processes by CPU ---${NC}"
    ps aux --sort=-%cpu 2>/dev/null | head -11 | tee -a "$RUN_LOG" || true
    log "${YELLOW}--- top 10 processes by RSS ---${NC}"
    ps aux --sort=-rss 2>/dev/null | head -11 | tee -a "$RUN_LOG" || true
    log "${YELLOW}--- memory / load ---${NC}"
    free -h 2>/dev/null | tee -a "$RUN_LOG" || true
    uptime 2>/dev/null | tee -a "$RUN_LOG" || true
    log "${YELLOW}--- kubectl port-forward count ---${NC}"
    ps -ef 2>/dev/null | grep -c '[k]ubectl port-forward' | tee -a "$RUN_LOG" || true
    log "${YELLOW}════════ END DIAG SNAPSHOT ════════${NC}"
}

trap 'log "${RED}Interrupted${NC}"; heartbeat_stop; diag_snapshot "INT/TERM"; cleanup_cluster; exit 130' INT TERM

# ─── 7. Single-system test runner ────────────────────────────────────────────
# Args: <system_dir> <system_label> <out_dir>
# Reads exported config (NUMBER_OF_NODES, NUMBER_OF_FAULTY_NODES, CPU_LIMIT, …)
# and invokes the system's existing run-performance-test.sh, while running the
# resource monitor in the background.
run_single_system() {
    local system_dir="$1"
    local system_label="$2"
    local out_dir="$3"

    mkdir -p "$out_dir"
    local resource_csv="$out_dir/pbft-${system_label}-resources.csv"

    # Launch the resource monitor in the background.
    "$MONITOR_SCRIPT" "$resource_csv" "${system_label}" >> "$RUN_LOG" 2>&1 &
    local monitor_pid=$!
    log "  monitor PID $monitor_pid → $resource_csv"

    # Reset phase file for this system's run, then start the heartbeat so the
    # user sees "still on <phase> after Ns" every HEARTBEAT_INTERVAL seconds
    # (even when the child script blocks on kubectl / JMeter / drain wait).
    echo "starting-${system_label}" > "$PHASE_FILE"
    heartbeat_start "${system_label}"

    # Invoke the system's existing performance harness.
    # ── stream output live: tee to stdout AND $RUN_LOG so the SSH -t session
    #    forwards every step log back to the user in real time. Previously
    #    output was silenced with >> $RUN_LOG 2>&1, so ~12 min of activity per
    #    cell looked like a hang from the user's perspective.
    # ── PIPESTATUS[0] captures the runner's exit code, not tee's.
    pushd "$system_dir" > /dev/null
    AUTOMATED_TEST=true ./run-performance-test.sh 2>&1 | tee -a "$RUN_LOG"
    local exit_code=${PIPESTATUS[0]}
    popd > /dev/null

    heartbeat_stop

    # Stop the resource monitor.
    kill -TERM "$monitor_pid" 2>/dev/null || true
    wait "$monitor_pid" 2>/dev/null || true

    # On failure, dump a diagnostic snapshot so the next run can figure out
    # what was wedged (non-Running pods, kubectl events, top processes, memory).
    if [[ $exit_code -ne 0 ]]; then
        diag_snapshot "${system_label} FAILED (exit=$exit_code)"
    fi

    # Collect the JMeter outputs that the system's harness wrote.
    local latest_stats latest_summary
    latest_stats=$(ls -t "$system_dir/performance-results/"*-stats.csv 2>/dev/null | head -1)
    latest_summary=$(ls -t "$system_dir/performance-results/"*-summary.txt 2>/dev/null | head -1)
    [[ -n "$latest_stats"   ]] && cp "$latest_stats"   "$out_dir/pbft-${system_label}-stats.csv"
    [[ -n "$latest_summary" ]] && cp "$latest_summary" "$out_dir/pbft-${system_label}-summary.txt"

    return $exit_code
}

# ─── 8. Main test grid ───────────────────────────────────────────────────────
RUN_INDEX=0
for NODES in $NODE_COUNTS; do
    for FAULT_PCT in $FAULT_LEVELS; do

        # Compute fault count from percentage
        FAULTY=$(( NODES * FAULT_PCT / 100 ))
        export NUMBER_OF_NODES="$NODES"
        export NUMBER_OF_FAULTY_NODES="$FAULTY"

        # Per-pod CPU sized to the budget
        export CPU_LIMIT
        CPU_LIMIT=$(compute_cpu_limit "$NODES")

        for RUN in $(seq 1 "$NUM_RUNS"); do
            RUN_INDEX=$((RUN_INDEX + 1))
            CFG_DIR="$RESULTS_ROOT/config-N${NODES}-f${FAULT_PCT}-r${RUN}"
            mkdir -p "$CFG_DIR"

            banner "[$RUN_INDEX / $TOTAL_CONFIGS] N=$NODES  f=$FAULT_PCT%  run=$RUN  CPU=$CPU_LIMIT vCPU/pod"

            # ── RapidChain ─────────────────────────────────────────────────
            log "${BLUE}▶ pbft-rapidchain${NC}"
            cleanup_cluster
            export SUBSET_INDEX="SUBSET1"
            export SHOULD_REDIRECT_FROM_FAULTY_NODES=0
            export ENABLE_SHARD_MERGE=0
            export NUMBER_OF_NODES_PER_SHARD="$RAPIDCHAIN_NODES_PER_SHARD"
            export TRANSACTION_THRESHOLD="$RAPIDCHAIN_THRESHOLD"
            # RapidChain's BLOCK_THRESHOLD: number of healthy data shards
            _SHARDS=$(( NODES / RAPIDCHAIN_NODES_PER_SHARD ))
            _BREAK=$(( RAPIDCHAIN_NODES_PER_SHARD / 3 + 1 ))
            _DEAD=$(( FAULTY / _BREAK ))
            [[ "$_DEAD" -gt "$_SHARDS" ]] && _DEAD=$_SHARDS
            _HEALTHY=$(( _SHARDS - _DEAD ))
            [[ "$_HEALTHY" -lt 1 ]] && _HEALTHY=1
            export BLOCK_THRESHOLD="$_HEALTHY"

            if ! run_single_system "$RAPIDCHAIN_DIR" "rapidchain" "$CFG_DIR"; then
                log "${RED}  ✗ rapidchain failed at N=$NODES f=$FAULT_PCT% run=$RUN — continuing${NC}"
            fi

            # ── EnhancedBFT ─────────────────────────────────────────────────
            log "${BLUE}▶ pbft-enhanced${NC}"
            cleanup_cluster
            export NUMBER_OF_NODES_PER_SHARD="$ENHANCED_NODES_PER_SHARD"
            export TRANSACTION_THRESHOLD="$ENHANCED_THRESHOLD"
            export SHOULD_REDIRECT_FROM_FAULTY_NODES=0
            export ENABLE_SHARD_MERGE=1

            if ! run_single_system "$ENHANCED_DIR" "enhanced" "$CFG_DIR"; then
                log "${RED}  ✗ enhanced failed at N=$NODES f=$FAULT_PCT% run=$RUN — continuing${NC}"
            fi

            # ── Incremental aggregation so partial runs are still useful ──
            log "${YELLOW}  incremental aggregate after run $RUN_INDEX${NC}"
            python3 "$STATS_SCRIPT" "$RESULTS_ROOT" 2>&1 | tee -a "$RUN_LOG" || \
                log "${YELLOW}  (aggregation skipped — too few datapoints yet)${NC}"
        done
    done
done

# ─── 9. Final aggregation and report ─────────────────────────────────────────
banner "Final aggregation"
python3 "$STATS_SCRIPT" "$RESULTS_ROOT" | tee -a "$RUN_LOG"

# Render a paper-ready markdown report from the aggregated CSV
REPORT="$RESULTS_ROOT/journal-report.md"
python3 - "$RESULTS_ROOT/journal-stats.csv" "$REPORT" <<'PYEOF'
import csv, sys, datetime
csv_path, report_path = sys.argv[1], sys.argv[2]
rows = list(csv.DictReader(open(csv_path)))
if not rows:
    open(report_path, 'w').write("# No data\n")
    sys.exit(0)

def fmt(v, sd=None, prec=1):
    if v in ('', None): return '-'
    try:
        f = float(v)
    except ValueError:
        return v
    if sd in ('', None):
        return f'{f:.{prec}f}'
    try:
        s = float(sd)
    except ValueError:
        return f'{f:.{prec}f}'
    return f'{f:.{prec}f} ± {s:.{prec}f}'

# Group rows by (nodes, fault_pct) so each row shows both systems side by side
grouped = {}
for r in rows:
    grouped.setdefault((int(r['nodes']), int(r['fault_pct'])), {})[r['system']] = r

with open(report_path, 'w') as f:
    f.write(f"# Journal-grade comparison report\n\n")
    f.write(f"_Generated_: {datetime.datetime.utcnow().isoformat()}Z\n\n")
    f.write("Mean ± sample SD over independent runs (n = `n_runs` column).\n\n")

    sections = [
        ("Throughput (tx/s) — confirmed transactions",
         'throughput_txps', 1),
        ("Drain rate (%) — fraction of submitted tx committed",
         'drain_rate_pct', 1),
        ("CPU — total cluster (millicores)",
         'cpu_total_mcores_mean', 0),
        ("CPU — per-pod peak (millicores)",
         'cpu_p2p_max_mcores_peak', 0),
        ("Memory — total cluster (MiB)",
         'mem_total_mib_mean', 0),
        ("Memory — per-pod peak (MiB)",
         'mem_p2p_max_mib_peak', 0),
        ("Bandwidth — RX (MiB/s)",
         'net_rx_mibps', 2),
        ("Bandwidth — TX (MiB/s)",
         'net_tx_mibps', 2),
    ]

    for title, col, prec in sections:
        f.write(f"## {title}\n\n")
        f.write("| Nodes | Faults % | RapidChain | EnhancedBFT | Gap (E/R) |\n")
        f.write("|------:|---------:|-----------:|------------:|----------:|\n")
        for (nodes, fault), bysys in sorted(grouped.items()):
            rc = bysys.get('rapidchain', {})
            eh = bysys.get('enhanced',   {})
            rc_m = fmt(rc.get(col + '_mean'), rc.get(col + '_sd'), prec)
            eh_m = fmt(eh.get(col + '_mean'), eh.get(col + '_sd'), prec)
            gap = '-'
            try:
                a = float(rc.get(col + '_mean')); b = float(eh.get(col + '_mean'))
                if a > 0: gap = f'{b/a:.2f}×'
            except (TypeError, ValueError):
                pass
            f.write(f"| {nodes} | {fault} | {rc_m} | {eh_m} | {gap} |\n")
        f.write("\n")

    f.write("## Reading guide\n\n")
    f.write("* **Throughput** — primary metric, expect EnhancedBFT > RapidChain in every cell.\n")
    f.write("* **Drain rate** — closeness to 100 % under load; collapse indicates the system has run out of consensus headroom.\n")
    f.write("* **CPU / memory** — physical cost per shard; report per-pod peaks to expose worst-case sizing requirements.\n")
    f.write("* **Bandwidth** — total network egress + ingress per pod; RapidChain pays the committee an extra round-trip per block.\n")
    f.write("\n")

print(f'Wrote {report_path}')
PYEOF

log ""
banner "Done"
log "Results : $RESULTS_ROOT"
log "Report  : $REPORT"
log "Stats   : $RESULTS_ROOT/journal-stats.csv"
log "Log     : $RUN_LOG"
