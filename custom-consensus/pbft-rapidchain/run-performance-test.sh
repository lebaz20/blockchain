#!/bin/bash

# Performance Test Script for PBFT-RapidChain
# This script starts the blockchain using start.sh, runs JMeter tests, and saves performance results

set -e

# Get script directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$SCRIPT_DIR"

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging function
log() {
    echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a server.log
}

# Configuration (use defaults from start.sh if not set)
export NUMBER_OF_NODES=${NUMBER_OF_NODES:-512}
export TRANSACTION_THRESHOLD=${TRANSACTION_THRESHOLD:-100}
export BLOCK_THRESHOLD=${BLOCK_THRESHOLD:-2}
export NUMBER_OF_FAULTY_NODES=${NUMBER_OF_FAULTY_NODES:-85}
export NUMBER_OF_NODES_PER_SHARD=${NUMBER_OF_NODES_PER_SHARD:-12}
export HAS_COMMITTEE_SHARD=${HAS_COMMITTEE_SHARD:-1}
export SHOULD_REDIRECT_FROM_FAULTY_NODES=${SHOULD_REDIRECT_FROM_FAULTY_NODES:-0}
export CPU_LIMIT=${CPU_LIMIT:-0.2}

# JMeter configuration
JMETER_THREADS=${JMETER_THREADS:-10}
JMETER_RAMP_UP=${JMETER_RAMP_UP:-5}
JMETER_DURATION=${JMETER_DURATION:-90}
# ConstantThroughputTimer unit is req/min; 6000 = 100 req/s
JMETER_THROUGHPUT=${JMETER_THROUGHPUT:-6000}

# Output files
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
RESULTS_DIR="performance-results"
RESULTS_FILE="${RESULTS_DIR}/pbft-rapidchain-${TIMESTAMP}.jtl"
SUMMARY_FILE="${RESULTS_DIR}/pbft-rapidchain-${TIMESTAMP}-summary.txt"
STATS_FILE="${RESULTS_DIR}/pbft-rapidchain-${TIMESTAMP}-stats.csv"

log "${BLUE}========================================${NC}"
log "${BLUE}PBFT-RapidChain Performance Test${NC}"
log "${BLUE}========================================${NC}"
log "Nodes: ${NUMBER_OF_NODES}"
log "Transaction Threshold: ${TRANSACTION_THRESHOLD}"
log "Block Threshold: ${BLOCK_THRESHOLD}"
log "Committee Shard: ${HAS_COMMITTEE_SHARD}"
log "JMeter Threads: ${JMETER_THREADS}"
log "Test Duration: ${JMETER_DURATION}s"
log "${BLUE}========================================${NC}"
echo

# Create results directory
mkdir -p "${RESULTS_DIR}"

# Cleanup function
cleanup() {
    log "\n${YELLOW}Cleaning up...${NC}"
    
    # Stop port forwarding
    log "Stopping port forwarding..."
    pkill -f "kubectl port-forward" 2>&1 | tee -a server.log || true
    
    # Delete Kubernetes resources
    log "Deleting Kubernetes resources..."
    kubectl delete -f kubeConfig.yml --ignore-not-found 2>&1 | tee -a server.log || true
    
    log "${GREEN}Cleanup complete${NC}"
}

# Set trap to cleanup on exit
trap cleanup EXIT INT TERM

# Step 1: Start blockchain using existing start.sh
log "${BLUE}Step 1: Starting blockchain (using start.sh)...${NC}"
# Run start.sh in background and wait for port forwarding to be ready
./start.sh 2>&1 | tee -a server.log &
START_PID=$!

# Wait for port forwarding to actually work (not just be started)
TIMEOUT=900
ELAPSED=0
while true; do
    # Check if at least one port is responding
    if curl -s -f http://localhost:3001/health > /dev/null 2>&1; then
        break
    fi
    
    if [ $ELAPSED -ge $TIMEOUT ]; then
        log "${RED}✗ Timeout waiting for port forwarding${NC}"
        kill $START_PID 2>/dev/null || true
        exit 1
    fi
    
    sleep 2
    ELAPSED=$((ELAPSED + 2))
    echo -ne "  Waiting for port forwarding... ${ELAPSED}s\r"
done

# Kill start.sh to prevent log streaming
kill $START_PID 2>/dev/null || true
wait $START_PID 2>/dev/null || true

# Re-establish port forwarding (start.sh's subprocess port-forwards die with it)
pkill -f "kubectl port-forward" 2>/dev/null || true
sleep 2
# Raise file-descriptor limit — 512 nodes require ~1024 concurrent port-forward fds
ulimit -n 65536 2>/dev/null || true
for ((i=0; i<NUMBER_OF_NODES; i++)); do
    nohup kubectl port-forward pod/p2p-server-$i $((3001+i)):$((3001+i)) >> server.log 2>&1 &
done
sleep 30

log "${GREEN}✓ Blockchain deployed and ready${NC}"
echo

# Step 2: Wait for blockchain to stabilize
log "${BLUE}Step 2: Waiting for all nodes to be ready...${NC}"
TIMEOUT=600
ELAPSED=0
READY_COUNT=0
# Only require non-faulty nodes — faulty pods may crash on startup and are already
# excluded from jmeter_ports.csv, so they won't receive traffic anyway.
MIN_READY=$((NUMBER_OF_NODES - NUMBER_OF_FAULTY_NODES))
[ $MIN_READY -lt 1 ] && MIN_READY=1

while [ $READY_COUNT -lt $MIN_READY ]; do
    # Run all health checks in parallel (batches of 64) to avoid sequential curl latency at scale.
    # Each subshell writes a touch file on success; the count is the number of ready nodes.
    HCHECK_TMP=$(mktemp -d)
    # Track only the health-check subshell PIDs so the bare wait below does NOT block
    # on the long-running kubectl port-forward processes also in this shell's job table.
    _hcheck_pids=()
    for ((i=0; i<NUMBER_OF_NODES; i++)); do
        PORT=$((3001+i))
        (
            if curl -s -f --max-time 2 http://localhost:$PORT/health > /dev/null 2>&1; then
                touch "$HCHECK_TMP/ok_$i"
            else
                if ! pgrep -f "port-forward pod/p2p-server-$i $PORT" > /dev/null 2>&1; then
                    nohup kubectl port-forward pod/p2p-server-$i $PORT:$PORT >> server.log 2>&1 &
                fi
            fi
        ) &
        _hcheck_pids+=($!)
        # Throttle: flush every 64 spawns to avoid fd exhaustion
        if (( (i+1) % 64 == 0 )); then wait "${_hcheck_pids[@]}"; _hcheck_pids=(); fi
    done
    wait "${_hcheck_pids[@]}"
    READY_COUNT=$(ls "$HCHECK_TMP"/ok_* 2>/dev/null | wc -l | tr -d ' ')
    rm -rf "$HCHECK_TMP"

    if [ $READY_COUNT -ge $MIN_READY ]; then
        break
    fi

    if [ $ELAPSED -ge $TIMEOUT ]; then
        log "${YELLOW}⚠ Timeout: only $READY_COUNT/$NUMBER_OF_NODES nodes responding (need $MIN_READY healthy)${NC}"
        if [ $READY_COUNT -lt $MIN_READY ]; then
            log "${RED}✗ Insufficient healthy nodes ($READY_COUNT < $MIN_READY required) — aborting${NC}"
            exit 1
        fi
        log "${YELLOW}Continuing with $READY_COUNT available nodes${NC}"
        break
    fi

    sleep 2
    ELAPSED=$((ELAPSED + 2))
    echo -ne "  Ready: $READY_COUNT/$NUMBER_OF_NODES nodes (need $MIN_READY)... ${ELAPSED}s\r"
done

log "${GREEN}✓ $READY_COUNT/$NUMBER_OF_NODES nodes are ready (${MIN_READY} required)${NC}"
echo

# Step 3: Run JMeter test
log "${BLUE}Step 3: Running JMeter performance test...${NC}"
log "  Duration: ${JMETER_DURATION}s"
log "  Threads: ${JMETER_THREADS}"
log "  Ramp-up: ${JMETER_RAMP_UP}s"
echo

# Start port-forward watchdog (restarts any dead forwards every 3s during JMeter)
(
    while true; do
        sleep 3
        for ((i=0; i<NUMBER_OF_NODES; i++)); do
            PORT=$((3001+i))
            if ! pgrep -f "port-forward pod/p2p-server-$i $PORT" > /dev/null 2>&1; then
                nohup kubectl port-forward pod/p2p-server-$i $PORT:$PORT >> server.log 2>&1 &
            fi
        done
    done
) &
WATCHDOG_PID=$!

TEST_START_TIME=$(date +%s)
jmeter -n -t "Test Plan.jmx" \
    -Jthreads=${JMETER_THREADS} \
    -Jrampup=${JMETER_RAMP_UP} \
    -Jduration=${JMETER_DURATION} \
    -Jthroughput=${JMETER_THROUGHPUT} \
    -l "${RESULTS_FILE}" \
    -e -o "${RESULTS_DIR}/pbft-rapidchain-${TIMESTAMP}-report" 2>&1 | tee -a server.log

# Kill watchdog
kill $WATCHDOG_PID 2>/dev/null || true

log "${GREEN}✓ JMeter test completed${NC}"
echo

# Re-establish port-forwarding before stats collection (may have died during JMeter run)
pkill -f "kubectl port-forward" 2>/dev/null || true
sleep 1
for ((i=0; i<NUMBER_OF_NODES; i++)); do
    nohup kubectl port-forward pod/p2p-server-$i $((3001+i)):$((3001+i)) >> server.log 2>&1 &
done

# Wait for transaction pool to drain (wait until unassigned hits 0)
log "${BLUE}Waiting for transaction pool to drain...${NC}"
DRAIN_TIMEOUT=120
DRAIN_ELAPSED=0
PREV_UNASSIGNED=-1
UNCHANGED_COUNT=0
DRAIN_END_TIME=
while [ $DRAIN_ELAPSED -lt $DRAIN_TIMEOUT ]; do
    sleep 5
    DRAIN_ELAPSED=$((DRAIN_ELAPSED + 5))
    # Step by NODES_PER_SHARD to sample exactly one representative node per shard,
    # then SUM the per-shard unassigned counts.
    # MIN was wrong: a drained shard returns 0 and would falsely signal completion
    # while other shards still had stuck transactions.
    STEP=${NUMBER_OF_NODES_PER_SHARD}
    [ $STEP -lt 1 ] && STEP=1
    SUM_UNASSIGNED=0
    VALID_SAMPLES=0
    OFFSET=0
    while [ $(( OFFSET * STEP )) -lt $NUMBER_OF_NODES ]; do
        IDX=$(( OFFSET * STEP ))
        PORT=$((3001+IDX))
        DRAIN_STATS=$(curl -s --max-time 3 http://localhost:$PORT/stats 2>/dev/null || echo '')
        if [ -n "$DRAIN_STATS" ]; then
            NODE_UNASSIGNED=$(echo "$DRAIN_STATS" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    if d.get('isFaulty', False):
        print(-1)
    else:
        total = sum(v.get('unassignedTransactions', 0) for v in d.get('total', {}).values())
        print(total)
except: print(-1)
" 2>/dev/null || echo -1)
            if [ "$NODE_UNASSIGNED" != "-1" ]; then
                SUM_UNASSIGNED=$(( SUM_UNASSIGNED + NODE_UNASSIGNED ))
                VALID_SAMPLES=$(( VALID_SAMPLES + 1 ))
            fi
        fi
        OFFSET=$(( OFFSET + 1 ))
    done
    # No valid samples means all polled nodes were unreachable/faulty — treat as unknown
    [ $VALID_SAMPLES -eq 0 ] && SUM_UNASSIGNED=-1
    CUR_UNASSIGNED=${SUM_UNASSIGNED}
    echo -ne "  Drain wait ${DRAIN_ELAPSED}s — unassigned: ${CUR_UNASSIGNED}\r"
    if [ "$CUR_UNASSIGNED" = "0" ]; then
        echo ""
        DRAIN_END_TIME=$(date +%s)
        log "${GREEN}✓ All transactions processed (unassigned=0)${NC}"
        break
    else
        # Treat as stalled if within ±STALL_TOLERANCE (small polling noise from
        # sampling different shard representatives each tick).
        STALL_TOLERANCE=50
        DELTA=$(( CUR_UNASSIGNED - PREV_UNASSIGNED ))
        [ $DELTA -lt 0 ] && DELTA=$(( -DELTA ))
        if [ $DELTA -le $STALL_TOLERANCE ]; then
            UNCHANGED_COUNT=$(( UNCHANGED_COUNT + 1 ))
            if [ $UNCHANGED_COUNT -ge 3 ]; then
                echo ""
                DRAIN_END_TIME=$(date +%s)
                log "${YELLOW}Pool stalled at ${CUR_UNASSIGNED} unassigned (±${STALL_TOLERANCE} for 15s) — stopping drain wait${NC}"
                break
            fi
        else
            UNCHANGED_COUNT=0
        fi
    fi
    PREV_UNASSIGNED=$CUR_UNASSIGNED
done
DRAIN_END_TIME=${DRAIN_END_TIME:-$(date +%s)}
TOTAL_ELAPSED=$(( DRAIN_END_TIME - TEST_START_TIME ))

# Step 4: Collect blockchain statistics
log "${BLUE}Step 4: Collecting blockchain statistics...${NC}"
{
    echo "PBFT-RapidChain Performance Test Results"
    echo "=========================================="
    echo "Timestamp: ${TIMESTAMP}"
    echo "Configuration:"
    echo "  - Number of Nodes: ${NUMBER_OF_NODES}"
    echo "  - Transaction Threshold: ${TRANSACTION_THRESHOLD}"
    echo "  - Block Threshold: ${BLOCK_THRESHOLD}"
    echo "  - Committee Shard: ${HAS_COMMITTEE_SHARD}"
    echo "  - Faulty Nodes: ${NUMBER_OF_FAULTY_NODES}"
    echo "  - CPU Limit: ${CPU_LIMIT}"
    echo ""
    echo "JMeter Configuration:"
    echo "  - Threads: ${JMETER_THREADS}"
    echo "  - Ramp-up: ${JMETER_RAMP_UP}s"
    echo "  - Duration: ${JMETER_DURATION}s"
    echo "  - Target Throughput: ${JMETER_THROUGHPUT} req/s"
    echo ""
    
    # Count total transactions fired by JMeter
    if [ -f "${RESULTS_FILE}" ]; then
        JMETER_TX_FIRED=$(grep -c '<httpSample' "${RESULTS_FILE}" 2>/dev/null || echo 0)
        echo "Total Transactions Fired by Test: $JMETER_TX_FIRED"
    else
        JMETER_TX_FIRED=0
        echo "Total Transactions Fired by Test: (pending)"
    fi
    
    echo ""
    echo "Blockchain Statistics (By Shard):"
    echo "=========================================="
    
    TOTAL_BLOCKS=0
    TOTAL_TX_IN_BLOCKS=0
    TOTAL_UNASSIGNED_TX=0
    NODES_RESPONDED=0

    # Query ALL nodes; for each shard keep the MAXIMUM value reported by any node
    # in that shard. Nodes within the same shard may be slightly out of sync
    # (one may have committed a block its peer hasn't received yet), so taking
    # the max gives the most up-to-date view.
    # Uses dynamically-named variables (SHARD_BLOCKS_<var>, ...) to avoid
    # declare -A which isn't available in bash 3.2 on macOS.
    SEEN_SHARDS=""
    for ((i=0; i<NUMBER_OF_NODES; i++)); do
        PORT=$((3001+i))
        CANDIDATE=$(curl -s --max-time 3 http://localhost:$PORT/stats 2>/dev/null || echo '')
        if [ -z "$CANDIDATE" ] || ! echo "$CANDIDATE" | python3 -c "import sys,json; json.load(sys.stdin)" 2>/dev/null; then
            continue
        fi
        IS_NODE_FAULTY=$(echo "$CANDIDATE" | python3 -c "import sys,json; d=json.load(sys.stdin); print('true' if d.get('isFaulty', False) else 'false')" 2>/dev/null || echo 'false')
        if [ "$IS_NODE_FAULTY" = "true" ]; then
            continue
        fi
        NODES_RESPONDED=$((NODES_RESPONDED + 1))

        NODE_SHARDS=$(echo "$CANDIDATE" | python3 -c "import sys,json; d=json.load(sys.stdin); [print(k) for k in d.get('total',{})]" 2>/dev/null)
        for SHARD_IDX in $NODE_SHARDS; do
            # Register shard on first encounter
            if ! echo "$SEEN_SHARDS" | grep -qw "$SHARD_IDX"; then
                SEEN_SHARDS="$SEEN_SHARDS $SHARD_IDX"
            fi

            # Sanitize shard key into a valid shell variable name
            SHARD_VAR=$(echo "$SHARD_IDX" | tr -cd '[:alnum:]_')

            BLOCKS=$(echo "$CANDIDATE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['total']['$SHARD_IDX'].get('blocks',0))" 2>/dev/null || echo 0)
            TX=$(echo "$CANDIDATE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['total']['$SHARD_IDX'].get('transactions',0))" 2>/dev/null || echo 0)
            UNASSIGNED=$(echo "$CANDIDATE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['total']['$SHARD_IDX'].get('unassignedTransactions',0))" 2>/dev/null || echo 0)

            BLOCKS=${BLOCKS:-0}; TX=${TX:-0}; UNASSIGNED=${UNASSIGNED:-0}

            # Update rolling max for this shard.
            # Unassigned is tied to the node with the most blocks: that node has
            # committed the most and therefore has the smallest (most accurate) pool.
            # Independent MAX would pick the most-stale node's inflated pool size.
            PREV_BLOCKS=$(eval echo "\${SHARD_BLOCKS_${SHARD_VAR}:-0}")
            PREV_TX=$(eval echo "\${SHARD_TX_${SHARD_VAR}:-0}")
            if [ "$BLOCKS" -gt "$PREV_BLOCKS" ]; then
                eval "SHARD_BLOCKS_${SHARD_VAR}=$BLOCKS"
                eval "SHARD_UNASSIGNED_${SHARD_VAR}=$UNASSIGNED"
            fi
            [ "$TX" -gt "$PREV_TX" ] && eval "SHARD_TX_${SHARD_VAR}=$TX"
        done
    done

    # Print per-shard max and accumulate totals
    for SHARD_IDX in $SEEN_SHARDS; do
        SHARD_VAR=$(echo "$SHARD_IDX" | tr -cd '[:alnum:]_')
        BLOCKS=$(eval echo "\${SHARD_BLOCKS_${SHARD_VAR}:-0}")
        TX=$(eval echo "\${SHARD_TX_${SHARD_VAR}:-0}")
        UNASSIGNED=$(eval echo "\${SHARD_UNASSIGNED_${SHARD_VAR}:-0}")

        echo ""
        echo "Shard $SHARD_IDX (max across shard nodes):"
        echo "----------------------------------------"
        echo "  Blocks Created: $BLOCKS"
        echo "  Transactions in Blocks: $TX"
        echo "  Unassigned Transactions: $UNASSIGNED"

        TOTAL_BLOCKS=$((TOTAL_BLOCKS + BLOCKS))
        TOTAL_TX_IN_BLOCKS=$((TOTAL_TX_IN_BLOCKS + TX))
        TOTAL_UNASSIGNED_TX=$((TOTAL_UNASSIGNED_TX + UNASSIGNED))
    done

    if [ -z "$SEEN_SHARDS" ]; then
        echo ""
        echo "  (No node responded to /stats query)"
    fi
    
    echo ""
    echo "=========================================="
    echo "TOTAL (All Shards):"
    echo "=========================================="
    echo "Total Blocks Created: $TOTAL_BLOCKS"
    echo "Total Transactions in Blocks: $TOTAL_TX_IN_BLOCKS"
    echo "Total Unassigned Transactions: $TOTAL_UNASSIGNED_TX"
    echo "Nodes Responded: $NODES_RESPONDED"
    echo "Nodes Total: $NUMBER_OF_NODES"
    if [ "$NODES_RESPONDED" -lt "$NUMBER_OF_NODES" ]; then
        MISSED=$(( NUMBER_OF_NODES - NODES_RESPONDED ))
        echo "WARNING: $MISSED node(s) did not respond — stats may be incomplete"
    fi
    echo ""
    echo "UNASSIGNED TRANSACTION REASONS:"
    echo "  - Transaction pool not full (threshold: ${TRANSACTION_THRESHOLD})"
    echo "  - Block pool not full (block threshold: ${BLOCK_THRESHOLD})"
    echo "  - Waiting for committee validation"
    echo "  - Consensus not reached for pending blocks"
    echo "  - Block creation in progress"
    echo "  - Test duration ended before block finalization"
} | tee "${SUMMARY_FILE}" | tee -a server.log > /dev/null

log "${GREEN}✓ Statistics collected${NC}"
echo

# Step 5: Parse JMeter results
log "${BLUE}Step 5: Parsing JMeter results...${NC}"
if [ -f "${RESULTS_FILE}" ]; then
    {
        echo "Metric,Value"
        TOTAL=$(awk -F',' 'NR>1 {count++} END {print count+0}' "${RESULTS_FILE}")
        echo "Total Samples,$TOTAL"
        
        # Calculate average response time
        AVG_TIME=$(awk -F',' 'NR>1 {sum+=$2; count++} END {if(count>0) print int(sum/count); else print 0}' "${RESULTS_FILE}")
        echo "Average Response Time (ms),$AVG_TIME"
        
        # Calculate success rate
        SUCCESS=$(awk -F',' 'NR>1 && $8=="true" {count++} END {print count+0}' "${RESULTS_FILE}")
        if [ "$TOTAL" -gt 0 ]; then
            SUCCESS_RATE=$(echo "scale=2; $SUCCESS * 100 / $TOTAL" | bc)
        else
            SUCCESS_RATE=0
        fi
        echo "Success Rate (%),$SUCCESS_RATE"
        
        # Calculate throughput
        if [ "$JMETER_DURATION" -gt 0 ]; then
            THROUGHPUT=$(echo "scale=2; $TOTAL / $JMETER_DURATION" | bc)
        else
            THROUGHPUT=0
        fi
        echo "Throughput (req/s),$THROUGHPUT"
        
        # Add blockchain metrics from summary
        if [ -f "${SUMMARY_FILE}" ]; then
            # Count /transaction requests: use label col (col 3) since TCP-refused
            # requests never reach the server so the URL col (col 14) is empty for them.
            # This gives the true total fired count including failed connections.
            JMETER_FIRED=$(awk -F',' 'NR>1 && $3 ~ /HTTP Request/ {count++} END {print count+0}' "${RESULTS_FILE}")
            BLOCKS=$(grep "Total Blocks Created:" "${SUMMARY_FILE}" | tail -1 | awk '{print $NF}')
            TX_IN_BLOCKS=$(grep "Total Transactions in Blocks:" "${SUMMARY_FILE}" | tail -1 | awk '{print $NF}')
            UNASSIGNED=$(grep "Total Unassigned Transactions:" "${SUMMARY_FILE}" | tail -1 | awk '{print $NF}')
            
            echo "Transactions Fired by Test,${JMETER_FIRED:-0}"
            echo "Total Blocks Created,${BLOCKS:-0}"
            echo "Transactions in Blocks,${TX_IN_BLOCKS:-0}"
            echo "Unassigned Transactions,${UNASSIGNED:-0}"

            # Drain Rate: fraction of fired transactions that made it into blocks
            if [ "${JMETER_FIRED:-0}" -gt 0 ]; then
                DRAIN_RATE=$(echo "scale=2; ${TX_IN_BLOCKS:-0} * 100 / ${JMETER_FIRED}" | bc)
                echo "Drain Rate (%),${DRAIN_RATE}"
            fi
            
            # Calculate block efficiency
            if [ "$BLOCKS" -gt 0 ] && [ "$TX_IN_BLOCKS" -gt 0 ]; then
                AVG_TX_PER_BLOCK=$(echo "scale=2; $TX_IN_BLOCKS / $BLOCKS" | bc)
                echo "Avg Transactions per Block,$AVG_TX_PER_BLOCK"
            fi
            
            # Blockchain transaction rate over total test+drain time
            if [ "${TOTAL_ELAPSED:-0}" -gt 0 ] && [ "${TX_IN_BLOCKS:-0}" -gt 0 ]; then
                BLOCKCHAIN_TX_RATE=$(echo "scale=2; ${TX_IN_BLOCKS} / ${TOTAL_ELAPSED}" | bc)
                echo "Total Test Elapsed (s),${TOTAL_ELAPSED}"
                echo "Blockchain TX Rate (tx/s),${BLOCKCHAIN_TX_RATE}"
                # Effective TX Rate = Blockchain TX Rate × Drain Fraction
                # = TX_IN_BLOCKS² / (JMETER_FIRED × TOTAL_ELAPSED)
                # Penalizes implementations that score high TX rate by leaving transactions unconfirmed
                if [ "${JMETER_FIRED:-0}" -gt 0 ]; then
                    EFFECTIVE_TX_RATE=$(echo "scale=2; ${TX_IN_BLOCKS} * ${TX_IN_BLOCKS} / (${JMETER_FIRED} * ${TOTAL_ELAPSED})" | bc)
                    echo "Effective TX Rate (tx/s),${EFFECTIVE_TX_RATE}"
                fi
            fi
        fi
        # Config metadata — read back by compare-performance.sh for the report
        echo "Number of Nodes Used,${NUMBER_OF_NODES}"
        echo "Nodes Per Shard,${NUMBER_OF_NODES_PER_SHARD}"
        echo "Faulty Nodes,${NUMBER_OF_FAULTY_NODES}"
        # Read back Nodes Responded from the summary file
        NODES_RESPONDED_STAT=$(grep "^Nodes Responded:" "${SUMMARY_FILE}" | awk '{print $NF}')
        echo "Nodes Responded,${NODES_RESPONDED_STAT:-0}"
    } > "${STATS_FILE}"
    
    log "${GREEN}✓ Results parsed${NC}"
    echo
fi

# Display summary
log "${BLUE}========================================${NC}"
log "${BLUE}Performance Test Complete!${NC}"
log "${BLUE}========================================${NC}"
log "Results saved to:"
log "  - Summary: ${SUMMARY_FILE}"
log "  - Stats: ${STATS_FILE}"
log "  - Raw data: ${RESULTS_FILE}"
log "  - HTML Report: ${RESULTS_DIR}/pbft-rapidchain-${TIMESTAMP}-report/index.html"
echo

if [ -f "${STATS_FILE}" ]; then
    log "${GREEN}Quick Stats:${NC}"
    cat "${STATS_FILE}" | tee -a server.log
fi

log "${BLUE}========================================${NC}"
