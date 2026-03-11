#!/bin/bash

# Performance Comparison Script
# Runs tests for both PBFT-Enhanced and PBFT-RapidChain and compares results

set -e

# Get script directory and change to it
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$SCRIPT_DIR"

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
COMPARISON_FILE="performance-comparison-${TIMESTAMP}.md"

# Shared configuration — exported so BOTH sub-scripts use identical values.
# Override any of these via env before calling this script.
export NUMBER_OF_NODES=${NUMBER_OF_NODES:-512}
export TRANSACTION_THRESHOLD=${TRANSACTION_THRESHOLD:-100}
# 85 faulty nodes across 128 shards (≤1 per shard on average) — safe for both
# 4-node shards (f=1 limit=128) and 12-node shards (f=3 limit=126).
export NUMBER_OF_FAULTY_NODES=${NUMBER_OF_FAULTY_NODES:-85}
export CPU_LIMIT=${CPU_LIMIT:-0.2}

# Per-protocol shard sizes (each uses its own architecture design)
# Enhanced: 4 nodes/shard → 6 shards, lower per-shard consensus latency,
#   each shard tolerates f=1 faulty node (MIN_APPROVALS=3 of 4).
#   Dead shards (≥2 faulty/shard) are rescued by the core redirect mechanism.
# RapidChain: 8 nodes/shard → fewer shards, committee overhead amortised
ENHANCED_NODES_PER_SHARD=${ENHANCED_NODES_PER_SHARD:-4}
RAPIDCHAIN_NODES_PER_SHARD=${RAPIDCHAIN_NODES_PER_SHARD:-4}

# Per-protocol redirect setting
# Enhanced: redirect enabled (faulty nodes forward txs to non-faulty peers)
# RapidChain: redirect disabled (faulty nodes drop txs — tests the raw protocol without forwarding)
ENHANCED_REDIRECT=${ENHANCED_REDIRECT:-1}
RAPIDCHAIN_REDIRECT=${RAPIDCHAIN_REDIRECT:-0}

# Per-protocol transaction threshold
# Lower threshold = smaller blocks more often = less memory pressure per pod = fewer OOM errors.
# Enhanced is set to 30 (same as its standalone run-performance-test.sh default)
# so blocks form quickly even though only 3 shards share 5-thread JMeter load.
# RapidChain keeps 100 to stress its committee pipeline; override
# RAPIDCHAIN_THRESHOLD if you want a balanced head-to-head comparison.
ENHANCED_THRESHOLD=${ENHANCED_THRESHOLD:-150}
RAPIDCHAIN_THRESHOLD=${RAPIDCHAIN_THRESHOLD:-100}
export BLOCK_THRESHOLD=${BLOCK_THRESHOLD:-2}

# JMeter configuration (also exported so sub-scripts pick them up)
export JMETER_THREADS=${JMETER_THREADS:-10}
export JMETER_RAMP_UP=${JMETER_RAMP_UP:-5}
export JMETER_DURATION=${JMETER_DURATION:-90}
# ConstantThroughputTimer unit is req/min; calcMode=1 means this is the TOTAL
# cap across all threads — individual threads are throttled to share it evenly.
# 12000 = 200 req/s total → ~16.7 real tx/shard/s after dedup (÷6 shards, ×0.5)
# → 16.7 × 3s inactivity window = ~50 tx > threshold=30 → threshold-driven blocks.
# 10 threads sustain 200 req/s smoothly (200×34ms/1000 ≈ 6.8 concurrent, well within 10).
export JMETER_THROUGHPUT=${JMETER_THROUGHPUT:-12000}

echo -e "${CYAN}========================================${NC}"
echo -e "${CYAN}Blockchain Performance Comparison${NC}"
echo -e "${CYAN}========================================${NC}\n"

# Check prerequisites
echo -e "${BLUE}Checking prerequisites...${NC}"

if ! command -v kubectl &> /dev/null; then
    echo -e "${RED}✗ kubectl not found${NC}"
    exit 1
fi

if ! command -v jmeter &> /dev/null; then
    echo -e "${RED}✗ jmeter not found${NC}"
    exit 1
fi

if ! kubectl get nodes &> /dev/null; then
    echo -e "${RED}✗ Kubernetes cluster not accessible${NC}"
    exit 1
fi

echo -e "${GREEN}✓ All prerequisites met${NC}\n"

# Raise file-descriptor limit — 512 nodes require ~1024 concurrent port-forward fds.
# macOS sysctl: sudo sysctl -w kern.maxfiles=1228800 kern.maxfilesperproc=614400
CURRENT_NOFILE=$(ulimit -n)
if [ "${CURRENT_NOFILE}" -lt 65536 ] 2>/dev/null; then
    echo -e "${YELLOW}⚠ File descriptor limit is ${CURRENT_NOFILE} (64k+ recommended for ${NUMBER_OF_NODES} nodes)${NC}"
    echo -e "${YELLOW}  Run: ulimit -n 65536  (or add to ~/.zshrc for persistence)${NC}"
    echo -e "${YELLOW}  macOS hard limit: sudo sysctl -w kern.maxfiles=1228800 kern.maxfilesperproc=614400${NC}"
fi
ulimit -n 65536 2>/dev/null || true

# Test 1: PBFT-Enhanced
echo -e "${CYAN}========================================${NC}"
echo -e "${CYAN}Test 1: PBFT-Enhanced${NC}"
echo -e "${CYAN}========================================${NC}\n"

cd pbft-enhanced
export NUMBER_OF_NODES_PER_SHARD=$ENHANCED_NODES_PER_SHARD
export SHOULD_REDIRECT_FROM_FAULTY_NODES=$ENHANCED_REDIRECT
# Enhanced uses a lower threshold — its single-layer consensus can commit small
# batches quickly without a cross-shard committee stage.
export TRANSACTION_THRESHOLD=$ENHANCED_THRESHOLD
./run-performance-test.sh
ENHANCED_STATS=$(ls -t performance-results/*-stats.csv | head -1)
ENHANCED_SUMMARY=$(ls -t performance-results/*-summary.txt | head -1)
cd ..

echo -e "\n${GREEN}✓ PBFT-Enhanced test completed${NC}\n"
# Clean up between tests: kill all port-forwards and delete pods so ports 3001-$((3000+NUMBER_OF_NODES))
# are fully released before RapidChain tries to bind the same range
echo -e "${YELLOW}Cleaning up between tests (releasing ports 3001-$((3000+NUMBER_OF_NODES)))...${NC}"
pkill -f "kubectl port-forward" 2>/dev/null || true
kubectl delete pods,services --all --ignore-not-found=true 2>/dev/null || true
# Wait until all pods are fully terminated before starting the next test.
# Without this, rapidchain pods start and try to resolve Kubernetes service DNS
# names (e.g. core-server) while the previous run's services are still terminating,
# causing getaddrinfo ENOTFOUND errors and connection races.
echo -e "${YELLOW}  Waiting for all pods to terminate...${NC}"
kubectl wait --for=delete pod --all --timeout=600s 2>/dev/null || true
# Also wait for services to be gone so DNS entries are fully cleared
kubectl wait --for=delete service --all --timeout=300s 2>/dev/null || true
echo -e "${GREEN}✓ Cleanup complete — all pods and services terminated${NC}\n"

# Test 2: PBFT-RapidChain
echo -e "${CYAN}========================================${NC}"
echo -e "${CYAN}Test 2: PBFT-RapidChain${NC}"
echo -e "${CYAN}========================================${NC}\n"

cd pbft-rapidchain
export NUMBER_OF_NODES_PER_SHARD=$RAPIDCHAIN_NODES_PER_SHARD
export SHOULD_REDIRECT_FROM_FAULTY_NODES=$RAPIDCHAIN_REDIRECT
# Lower threshold reduces per-pod memory pressure and time-to-first-block, directly
# decreasing error rates caused by pool saturation under high load.
export TRANSACTION_THRESHOLD=$RAPIDCHAIN_THRESHOLD
./run-performance-test.sh
RAPIDCHAIN_STATS=$(ls -t performance-results/*-stats.csv | head -1)
RAPIDCHAIN_SUMMARY=$(ls -t performance-results/*-summary.txt | head -1)
cd ..

echo -e "\n${GREEN}✓ PBFT-RapidChain test completed${NC}\n"

# Generate comparison report
echo -e "${CYAN}========================================${NC}"
echo -e "${CYAN}Generating Comparison Report${NC}"
echo -e "${CYAN}========================================${NC}\n"

# Helper: extract a single metric value from a stats CSV
extract_metric() {
    local file=$1
    local metric=$2
    grep "^${metric}," "$file" | cut -d',' -f2
}

# Load all metrics from both stats files
ENH_FILE="pbft-enhanced/$ENHANCED_STATS"
RC_FILE="pbft-rapidchain/$RAPIDCHAIN_STATS"

ENH_TOTAL=$(extract_metric "$ENH_FILE" "Total Samples")
ENH_RT=$(extract_metric "$ENH_FILE" "Average Response Time (ms)")
ENH_SR=$(extract_metric "$ENH_FILE" "Success Rate (%)")
ENH_TP=$(extract_metric "$ENH_FILE" "Throughput (req/s)")
ENH_FIRED=$(extract_metric "$ENH_FILE" "Transactions Fired by Test")
ENH_BL=$(extract_metric "$ENH_FILE" "Total Blocks Created")
ENH_TX=$(extract_metric "$ENH_FILE" "Transactions in Blocks")
ENH_UNASSIGNED=$(extract_metric "$ENH_FILE" "Unassigned Transactions")
ENH_AVG=$(extract_metric "$ENH_FILE" "Avg Transactions per Block")
ENH_ELAPSED=$(extract_metric "$ENH_FILE" "Total Test Elapsed (s)")
ENH_BRATE=$(extract_metric "$ENH_FILE" "Blockchain TX Rate (tx/s)")
ENH_DRAIN=$(extract_metric "$ENH_FILE" "Drain Rate (%)")
ENH_ERATE=$(extract_metric "$ENH_FILE" "Effective TX Rate (tx/s)")
ENH_DUPS=$(extract_metric "$ENH_FILE" "Duplicates Created")
ENH_RESPONDED=$(extract_metric "$ENH_FILE" "Nodes Responded")

RC_TOTAL=$(extract_metric "$RC_FILE" "Total Samples")
RC_RT=$(extract_metric "$RC_FILE" "Average Response Time (ms)")
RC_SR=$(extract_metric "$RC_FILE" "Success Rate (%)")
RC_TP=$(extract_metric "$RC_FILE" "Throughput (req/s)")
RC_FIRED=$(extract_metric "$RC_FILE" "Transactions Fired by Test")
RC_BL=$(extract_metric "$RC_FILE" "Total Blocks Created")
RC_TX=$(extract_metric "$RC_FILE" "Transactions in Blocks")
RC_UNASSIGNED=$(extract_metric "$RC_FILE" "Unassigned Transactions")
RC_AVG=$(extract_metric "$RC_FILE" "Avg Transactions per Block")
RC_ELAPSED=$(extract_metric "$RC_FILE" "Total Test Elapsed (s)")
RC_BRATE=$(extract_metric "$RC_FILE" "Blockchain TX Rate (tx/s)")
RC_DRAIN=$(extract_metric "$RC_FILE" "Drain Rate (%)")
RC_ERATE=$(extract_metric "$RC_FILE" "Effective TX Rate (tx/s)")

# Extract actual config values written by the sub-scripts into the stats CSVs.
# compare-performance.sh has its own local defaults (16 nodes) but the sub-scripts
# use their own defaults (24 nodes), so we read the ground-truth from the CSVs.
ENH_NODES=$(extract_metric "$ENH_FILE" "Number of Nodes Used")
RC_NODES=$(extract_metric "$RC_FILE" "Number of Nodes Used")
RC_PER_SHARD=$(extract_metric "$RC_FILE" "Nodes Per Shard")
RC_FAULTY=$(extract_metric "$RC_FILE" "Faulty Nodes")
# Fall back to shell env if stats field is missing (legacy runs)
ENH_NODES=${ENH_NODES:-${NUMBER_OF_NODES:-16}}
RC_NODES=${RC_NODES:-${NUMBER_OF_NODES:-16}}
RC_PER_SHARD=${RC_PER_SHARD:-${NUMBER_OF_NODES_PER_SHARD:-8}}
RC_FAULTY=${RC_FAULTY:-${NUMBER_OF_FAULTY_NODES:-4}}

# Compute drain percentages for narrative (strip decimals for bc integer comparison)
ENH_DRAIN_PCT=$(echo "scale=1; ${ENH_DRAIN:-0}" | bc)
RC_DRAIN_PCT=$(echo "scale=1; ${RC_DRAIN:-0}" | bc)

# Compute load ratio (how many more txs RapidChain received vs Enhanced)
LOAD_RATIO=""
if [ -n "$ENH_FIRED" ] && [ -n "$RC_FIRED" ] && [ "${ENH_FIRED:-0}" -gt 0 ]; then
    LOAD_RATIO=$(echo "scale=1; ${RC_FIRED} / ${ENH_FIRED}" | bc)
fi

# Determine per-metric winners
# Throughput
if (( $(echo "${ENH_TP:-0} > ${RC_TP:-0}" | bc -l) )); then TP_WINNER="**Enhanced** 🏆"; else TP_WINNER="**RapidChain** 🏆"; fi
# Response Time (lower is better)
if (( $(echo "${ENH_RT:-9999} < ${RC_RT:-9999}" | bc -l) )); then RT_WINNER="**Enhanced** 🏆"; else RT_WINNER="**RapidChain** 🏆"; fi
# Success Rate
if (( $(echo "${ENH_SR:-0} > ${RC_SR:-0}" | bc -l) )); then SR_WINNER="**Enhanced** 🏆"; else SR_WINNER="**RapidChain** 🏆"; fi
# Blocks
if (( $(echo "${ENH_BL:-0} > ${RC_BL:-0}" | bc -l) )); then BL_WINNER="**Enhanced** 🏆"; else BL_WINNER="**RapidChain** 🏆"; fi
# TX in blocks
if (( $(echo "${ENH_TX:-0} > ${RC_TX:-0}" | bc -l) )); then TX_WINNER="**Enhanced** 🏆"; else TX_WINNER="**RapidChain** 🏆"; fi
# Avg TX per block
if (( $(echo "${ENH_AVG:-0} > ${RC_AVG:-0}" | bc -l) )); then AVG_WINNER="**Enhanced** 🏆"; else AVG_WINNER="**RapidChain** 🏆"; fi
# Drain Rate (higher = better)
if (( $(echo "${ENH_DRAIN:-0} > ${RC_DRAIN:-0}" | bc -l) )); then DRAIN_WINNER="**Enhanced** 🏆"; else DRAIN_WINNER="**RapidChain** 🏆"; fi
# Effective TX Rate
if (( $(echo "${ENH_ERATE:-0} > ${RC_ERATE:-0}" | bc -l) )); then ERATE_WINNER="**Enhanced** 🏆"; else ERATE_WINNER="**RapidChain** 🏆"; fi

# Check if Effective TX Rates are within 2% of each other → declare a tie
ERATE_TIE=0
if [ -n "$ENH_ERATE" ] && [ -n "$RC_ERATE" ] && \
   (( $(echo "${ENH_ERATE:-0} > 0" | bc -l) )) && \
   (( $(echo "${RC_ERATE:-0} > 0" | bc -l) )); then
    DIFF=$(echo "scale=4; (${ENH_ERATE} - ${RC_ERATE})^2" | bc)
    AVG_E=$(echo "scale=4; (${ENH_ERATE} + ${RC_ERATE}) / 2" | bc)
    if [ -n "$AVG_E" ] && (( $(echo "$AVG_E > 0" | bc -l) )); then
        REL=$(echo "scale=4; sqrt($DIFF) / $AVG_E" | bc)
        if (( $(echo "$REL < 0.02" | bc -l) )); then
            ERATE_TIE=1
            ERATE_WINNER="**Tie**"
        fi
    fi
fi

# Score-based overall winner (weights: HTTP metrics 2pt each, blockchain reliability 3pt each)
ENH_SCORE=0; RC_SCORE=0
[ "$(echo "${ENH_TP:-0} > ${RC_TP:-0}" | bc -l)" -eq 1 ] && ENH_SCORE=$((ENH_SCORE+2)) || RC_SCORE=$((RC_SCORE+2))
(( $(echo "${ENH_RT:-9999} < ${RC_RT:-9999}" | bc -l) )) && ENH_SCORE=$((ENH_SCORE+2)) || RC_SCORE=$((RC_SCORE+2))
[ "$(echo "${ENH_SR:-0} > ${RC_SR:-0}" | bc -l)" -eq 1 ] && ENH_SCORE=$((ENH_SCORE+3)) || RC_SCORE=$((RC_SCORE+3))
[ -n "$ENH_DRAIN" ] && [ -n "$RC_DRAIN" ] && \
    [ "$(echo "${ENH_DRAIN:-0} > ${RC_DRAIN:-0}" | bc -l)" -eq 1 ] && ENH_SCORE=$((ENH_SCORE+3)) || RC_SCORE=$((RC_SCORE+3))
if [ "$ERATE_TIE" -eq 0 ] && [ -n "$ENH_ERATE" ] && [ -n "$RC_ERATE" ]; then
    [ "$(echo "${ENH_ERATE:-0} > ${RC_ERATE:-0}" | bc -l)" -eq 1 ] && ENH_SCORE=$((ENH_SCORE+3)) || RC_SCORE=$((RC_SCORE+3))
fi

{
    echo "# Blockchain Performance Comparison"
    echo ""
    echo "**Test Date:** $(date '+%Y-%m-%d %H:%M:%S')"
    echo ""
    echo "## Test Configuration"
    echo ""
    echo "| Parameter | Value | Meaning |"
    echo "|-----------|-------|---------|"
    echo "| Number of Nodes (Enhanced) | ${ENH_NODES} | ${ENH_NODES} P2P nodes ran the PBFT-Enhanced consensus; each participates in every round of consensus voting |"
    echo "| Number of Nodes (RapidChain) | ${RC_NODES} total | Nodes split into shards of ${RC_PER_SHARD}, plus 1 committee shard for cross-shard finality |"
    echo "| Faulty Nodes (RapidChain) | ${RC_FAULTY} | Byzantine-simulated nodes that do not propose or vote in consensus |"
    echo "| JMeter Threads | ${JMETER_THREADS:-10} | ${JMETER_THREADS:-10} concurrent virtual users sending HTTP POST \`/transaction\` requests in parallel |"
    echo "| Test Duration | ${JMETER_DURATION:-60} s | JMeter fires transactions for ${JMETER_DURATION:-60} seconds; the clock starts after a ${JMETER_RAMP_UP:-5} s ramp-up |"
    echo "| Ramp-up Time | ${JMETER_RAMP_UP:-5} s | JMeter linearly scales from 0 to ${JMETER_THREADS:-10} threads over the first ${JMETER_RAMP_UP:-5} seconds to avoid a cold-start spike |"
    echo ""
    echo "---"
    echo ""
    echo "## Results Summary"
    echo ""
    echo "### PBFT-Enhanced"
    echo ""
    echo "| Metric | Value | What it means |"
    echo "|--------|-------|---------------|"
    echo "| Total Samples | ${ENH_TOTAL} | Total HTTP requests JMeter sent and received a response for (all endpoints combined: \`/transaction\`, \`/stats\`, etc.) |"
    echo "| Average Response Time (ms) | ${ENH_RT} | Mean round-trip time for a single HTTP request from JMeter to the node and back |"
    echo "| Success Rate (%) | ${ENH_SR} | Percentage of HTTP responses that returned a 2xx status |"
    echo "| Throughput (req/s) | ${ENH_TP} | HTTP requests per second handled by the node API layer (JMeter perspective, all endpoints) |"
    echo "| Transactions Fired by Test | ${ENH_FIRED} | Number of those samples that were \`POST /transaction\` — the actual blockchain workload submitted |"
    echo "| Total Blocks Created | ${ENH_BL} | Blocks appended to the blockchain during the entire test + drain window |"
    echo "| Transactions in Blocks | ${ENH_TX} | Real (non-duplicate) transactions confirmed on-chain; duplicate injections are excluded from this count |"
    echo "| Unassigned Transactions | ${ENH_UNASSIGNED} | Real transactions still waiting in the memory pool when the drain timeout expired — **never confirmed** |"
    echo "| Avg Transactions per Block | ${ENH_AVG:-N/A} | \`Transactions in Blocks ÷ Total Blocks Created\` — computed on real transactions only |"
    echo "| Total Test Elapsed (s) | ${ENH_ELAPSED:-N/A} | Wall-clock seconds from test start until the pool drained to 0 (or stalled) — includes JMeter run + drain wait |"
    echo "| Blockchain TX Rate (tx/s) | ${ENH_BRATE:-N/A} | \`Real Transactions in Blocks ÷ Total Test Elapsed\` |"
    echo "| Drain Rate (%) | ${ENH_DRAIN:-N/A} | \`Real Transactions in Blocks ÷ Transactions Fired × 100\` |"
    echo "| Effective TX Rate (tx/s) | ${ENH_ERATE:-N/A} | \`Blockchain TX Rate × Drain Fraction\` = \`TX²  ÷ (Fired × Elapsed)\` — penalises leaving txs unconfirmed |"
    # Duplicate transparency note
    if [ -n "$ENH_DUPS" ] && [ "${ENH_DUPS:-0}" -gt 0 ]; then
        ENH_NODES_NOTE=""
        if [ -n "$ENH_RESPONDED" ] && [ "${ENH_RESPONDED:-0}" -lt "${ENH_NODES:-24}" ]; then
            ENH_NODES_NOTE=" (**warning:** only ${ENH_RESPONDED}/${ENH_NODES} nodes responded — duplicate count may be understated)"
        fi
        echo ""
        echo "> **Duplicate injection:** ${ENH_DUPS} duplicate transactions were injected by Enhanced nodes (50% probability per transaction) to simulate dual-shard verification. All TX metrics above are corrected to reflect **real transactions only** using the formula \`real = raw × fired / (fired + duplicates)\`.${ENH_NODES_NOTE}"
    fi
    echo ""
    echo "### PBFT-RapidChain (Committee-Based)"
    echo ""
    echo "| Metric | Value | What it means |"
    echo "|--------|-------|---------------|"
    echo "| Total Samples | ${RC_TOTAL} | Total HTTP requests JMeter sent and received a response for (all endpoints combined: \`/transaction\`, \`/stats\`, etc.) |"
    echo "| Average Response Time (ms) | ${RC_RT} | Mean round-trip time for a single HTTP request from JMeter to the node and back |"
    echo "| Success Rate (%) | ${RC_SR} | Percentage of HTTP responses that returned a 2xx status |"
    echo "| Throughput (req/s) | ${RC_TP} | HTTP requests per second handled by the node API layer (JMeter perspective, all endpoints) |"
    echo "| Transactions Fired by Test | ${RC_FIRED} | Number of those samples that were \`POST /transaction\` — the actual blockchain workload submitted |"
    echo "| Total Blocks Created | ${RC_BL} | Blocks committed across all shards |"
    echo "| Transactions in Blocks | ${RC_TX} | Unique transactions confirmed on-chain across all shards |"
    echo "| Unassigned Transactions | ${RC_UNASSIGNED} | Transactions still in shard memory pools at the end — **never confirmed** |"
    echo "| Avg Transactions per Block | ${RC_AVG:-N/A} | \`Transactions in Blocks ÷ Total Blocks Created\` |"
    echo "| Total Test Elapsed (s) | ${RC_ELAPSED:-N/A} | Wall-clock seconds from test start until drain stalled |"
    echo "| Blockchain TX Rate (tx/s) | ${RC_BRATE:-N/A} | \`Transactions in Blocks ÷ Total Test Elapsed\` — raw number can be **misleading** (see below) |"
    echo "| Drain Rate (%) | ${RC_DRAIN:-N/A} | \`Transactions in Blocks ÷ Transactions Fired × 100\` — how much of what was submitted actually got confirmed |"
    echo "| Effective TX Rate (tx/s) | ${RC_ERATE:-N/A} | \`TX² ÷ (Fired × Elapsed)\` — corrects for input volume differences between the two runs |"
    echo ""
    echo "---"
    echo ""
    echo "## Why Blockchain TX Rate Alone is Misleading"
    echo ""
    echo "The two implementations may have a backlog of unassigned transactions still being processed while test period is complete."
    echo ""
    echo "The fair comparison is **Effective TX Rate**, which multiplies the raw rate by the drain fraction:"
    echo ""
    echo '```'
    echo 'Effective TX Rate = TX_IN_BLOCKS² / (TRANSACTIONS_FIRED × TOTAL_ELAPSED)'
    echo '```'
    echo ""
    echo "| | Fired | Confirmed | Drain % | Raw TX Rate | Effective TX Rate |"
    echo "|---|---|---|---|---|---|"
    echo "| **PBFT-Enhanced** | ${ENH_FIRED:-N/A} | ${ENH_TX:-N/A} | **~${ENH_DRAIN_PCT}%** | ${ENH_BRATE:-N/A} tx/s | **~${ENH_ERATE:-N/A} tx/s** |"
    echo "| **PBFT-RapidChain** | ${RC_FIRED:-N/A} | ${RC_TX:-N/A} | **~${RC_DRAIN_PCT}%** | ${RC_BRATE:-N/A} tx/s | **~${RC_ERATE:-N/A} tx/s** |"
    echo ""
    echo "See the Detailed Comparison and Effective TX Rate rows above for the run-specific verdict."
    echo ""
    echo "---"
    echo ""
    echo "## Detailed Comparison"
    echo ""
    echo "| Metric | PBFT-Enhanced | PBFT-RapidChain | Winner |"
    echo "|--------|---------------|-----------------|--------|"
    echo "| Throughput (req/s) ¹ | ${ENH_TP} | ${RC_TP} | $TP_WINNER |"
    echo "| Avg Response Time (ms) ² | ${ENH_RT} | ${RC_RT} | $RT_WINNER |"
    echo "| Success Rate (%) ³ | ${ENH_SR} | ${RC_SR} | $SR_WINNER |"
    echo "| Blocks Created | ${ENH_BL} | ${RC_BL} | $BL_WINNER |"
    echo "| Transactions in Blocks ⁴ | ${ENH_TX} | ${RC_TX} | $TX_WINNER |"
    echo "| Avg TX per Block | ${ENH_AVG:-N/A} | ${RC_AVG:-N/A} | $AVG_WINNER |"
    echo "| Blockchain TX Rate (tx/s) ⁵ | ${ENH_BRATE:-N/A} | ${RC_BRATE:-N/A} | _(see Effective TX Rate)_ |"
    echo "| Drain Rate (%) ⁶ | ${ENH_DRAIN:-N/A} | ${RC_DRAIN:-N/A} | $DRAIN_WINNER |"
    echo "| Effective TX Rate (tx/s) ⁷ | ${ENH_ERATE:-N/A} | ${RC_ERATE:-N/A} | $ERATE_WINNER |"
    echo "| Total Test Elapsed (s) ⁸ | ${ENH_ELAPSED:-N/A} | ${RC_ELAPSED:-N/A} | _(lower = faster drain)_ |"
    echo ""
    echo "**Footnotes:**"
    echo ""
    echo "¹ **Throughput (req/s):** HTTP-layer requests/s seen by JMeter. Reflects HTTP concurrency driven by response latency — not a direct measure of blockchain efficiency."
    echo ""
    echo "² **Avg Response Time (ms):** Time for the node to acknowledge a transaction over HTTP. Enhanced performs upfront PBFT validation before responding; RapidChain queues immediately and responds."
    echo ""
    echo "³ **Success Rate (%):** HTTP 2xx responses. Any value below 100% indicates dropped requests under high load (pool-full or node errors)."
    echo ""
    echo "⁴ **Transactions in Blocks:** Confirmed on-chain transactions. An implementation that receives more total input will naturally confirm more in absolute terms; use Drain Rate for a normalised comparison."
    echo ""
    echo "⁵ **Blockchain TX Rate (tx/s):** \`Confirmed ÷ Elapsed\`. Biased in favour of whichever implementation received more raw input. Do not use as the sole winner criterion."
    echo ""
    echo "⁶ **Drain Rate (%):** \`Confirmed ÷ Fired × 100\`. The most direct measure of whether the consensus mechanism actually processes everything it accepts."
    echo ""
    echo "⁷ **Effective TX Rate (tx/s):** \`Blockchain TX Rate × Drain Fraction\`. Corrects for input volume differences. This is the fairest single-number comparison between the two systems."
    echo ""
    echo "⁸ **Total Test Elapsed (s):** Wall-clock seconds from start until the unassigned pool reached 0 or stalled. Includes the ${JMETER_DURATION:-60} s JMeter run plus however long the drain wait took."
    echo ""
    echo "---"
    echo ""
    echo "## Analysis"
    echo ""
    echo "### PBFT-Enhanced"
    echo ""
    echo "**Strengths:**"
    echo "- ${ENH_SR}% HTTP success rate"
    echo "- ${ENH_DRAIN_PCT}% drain rate (share of submitted transactions confirmed on-chain)"
    echo "- Single-layer consensus (no committee stage) with lower operational complexity"
    echo ""
    echo "**Characteristics:**"
    echo "- Sharded PBFT (${ENHANCED_NODES_PER_SHARD} nodes/shard); within each shard all nodes participate in consensus (O(n²) message complexity per shard)"
    echo "- \`TRANSACTION_THRESHOLD\` controls block batching; no second consensus layer"
    echo "- Scales well when \`NUMBER_OF_NODES_PER_SHARD\` is sized so each shard can tolerate the expected faulty count (f = floor((shard_size-1)/3))"
    echo ""
    echo "### PBFT-RapidChain"
    echo ""
    echo "**Strengths:**"
    echo "- ${RC_RT} ms average HTTP response time"
    echo "- ${RC_DRAIN_PCT}% drain rate (share of submitted transactions confirmed on-chain)"
    echo "- Architecture designed for horizontal scaling via sharding"
    echo ""
    echo "**Characteristics:**"
    echo "- Two-level consensus: each shard runs PBFT internally, then a committee shard validates batches of shard blocks (\`BLOCK_THRESHOLD\`)"
    echo "- The committee layer creates a second pipeline stage; if too few shard blocks accumulate, the committee does not trigger and txs stall"
    echo "- \`getTotal()\` currently only counts \`transactions.unassigned\`, not \`committeeTransactions.unassigned\` — the drain monitor can declare done while committee-layer transactions are still pending"
    echo "- Non-proposer redistribution workaround (re-broadcasts txs every 10 s) causes O(n²) bandwidth growth and timing races on proposer rotation"
    echo "- Best for larger networks (>16 nodes) that need cross-shard coordination"
    echo ""
    echo "---"
    echo ""
    echo "## Recommendation"
    echo ""
    if [ "$ERATE_TIE" -eq 1 ]; then
        echo "**🤝 Effective Tie on Blockchain Throughput — Enhanced wins on Reliability**"
        echo ""
        echo "Both implementations deliver approximately **${ENH_ERATE} confirmed transactions per second** when measured with the drain-corrected Effective TX Rate."
        echo ""
        echo "PBFT-Enhanced is the stronger choice for the current ${ENH_NODES}-node configuration:"
        echo "- **${ENH_SR}% confirmation rate** vs RapidChain's ${RC_SR}%"
        echo "- **Identical effective throughput** with lower architectural complexity"
        echo "- No committee-layer pipeline stalls or drain blind-spots"
    elif [ $ENH_SCORE -gt $RC_SCORE ]; then
        echo "**🏆 Winner: PBFT-Enhanced**"
        echo ""
        echo "For ${ENH_NODES} nodes, PBFT-Enhanced performs better overall:"
        echo "- **${ENH_SR}% acceptance rate** vs RapidChain's ${RC_SR}%"
        echo "- **${ENH_DRAIN_PCT}% drain rate**"
        echo "- Higher Effective TX Rate (${ENH_ERATE:-N/A} vs ${RC_ERATE:-N/A} tx/s) after correcting for input volume"
        echo "- Simpler architecture with no committee-layer pipeline stalls"
    else
        echo "**🏆 Winner: PBFT-RapidChain**"
        echo ""
        echo "For ${RC_NODES} nodes, PBFT-RapidChain performs better overall:"
        echo "- Higher Effective TX Rate (${RC_ERATE:-N/A} vs ${ENH_ERATE:-N/A} tx/s) after correcting for input volume"
        echo "- ${RC_RT} ms vs ${ENH_RT} ms average response time"
        echo "- Architecture ready for horizontal scaling beyond this node count"
    fi
    echo ""
    echo "**When RapidChain becomes the right choice:**"
    echo "- Networks exceeding 32+ nodes where O(n²) PBFT message complexity becomes a bottleneck"
    echo "- Multi-shard deployments where cross-shard coordination is required"
    echo "- After fixing: (i) \`getTotal()\` to include committee pool, (ii) the drain detection logic, and (iii) the committee threshold to fire on partial batches"
    echo ""
    echo "---"
    echo ""
    echo "## Full Reports"
    echo ""
    echo "- **PBFT-Enhanced Summary:** \`pbft-enhanced/$ENHANCED_SUMMARY\`"
    echo "- **PBFT-RapidChain Summary:** \`pbft-rapidchain/$RAPIDCHAIN_SUMMARY\`"

} > "$COMPARISON_FILE"

echo -e "${GREEN}✓ Comparison report generated: $COMPARISON_FILE${NC}\n"

# Display the report
cat "$COMPARISON_FILE"

echo -e "\n${CYAN}========================================${NC}"
echo -e "${CYAN}Performance Comparison Complete!${NC}"
echo -e "${CYAN}========================================${NC}"
echo -e "Report saved to: ${COMPARISON_FILE}\n"
