#!/bin/bash

# Performance Test Script for PBFT-Enhanced
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
export NUMBER_OF_NODES=${NUMBER_OF_NODES:-16}
export TRANSACTION_THRESHOLD=${TRANSACTION_THRESHOLD:-100}
export NUMBER_OF_FAULTY_NODES=${NUMBER_OF_FAULTY_NODES:-0}
export NUMBER_OF_NODES_PER_SHARD=${NUMBER_OF_NODES_PER_SHARD:-4}
export SHOULD_REDIRECT_FROM_FAULTY_NODES=${SHOULD_REDIRECT_FROM_FAULTY_NODES:-0}
export CPU_LIMIT=${CPU_LIMIT:-0.2}

# JMeter configuration
JMETER_THREADS=${JMETER_THREADS:-10}
JMETER_RAMP_UP=${JMETER_RAMP_UP:-5}
JMETER_DURATION=${JMETER_DURATION:-60}
JMETER_THROUGHPUT=${JMETER_THROUGHPUT:-100}

# Output files
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
RESULTS_DIR="performance-results"
RESULTS_FILE="${RESULTS_DIR}/pbft-enhanced-${TIMESTAMP}.jtl"
SUMMARY_FILE="${RESULTS_DIR}/pbft-enhanced-${TIMESTAMP}-summary.txt"
STATS_FILE="${RESULTS_DIR}/pbft-enhanced-${TIMESTAMP}-stats.csv"

log "${BLUE}========================================${NC}"
log "${BLUE}PBFT-Enhanced Performance Test${NC}"
log "${BLUE}========================================${NC}"
log "Nodes: ${NUMBER_OF_NODES}"
log "Transaction Threshold: ${TRANSACTION_THRESHOLD}"
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
TIMEOUT=300
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
for ((i=0; i<NUMBER_OF_NODES; i++)); do
    nohup kubectl port-forward pod/p2p-server-$i $((3001+i)):$((3001+i)) >> server.log 2>&1 &
done
sleep 5

log "${GREEN}✓ Blockchain deployed and ready${NC}"
echo

# Step 2: Wait for blockchain to stabilize
log "${BLUE}Step 2: Waiting for all nodes to be ready...${NC}"
TIMEOUT=150
ELAPSED=0
READY_COUNT=0

while [ $READY_COUNT -lt $NUMBER_OF_NODES ]; do
    READY_COUNT=0
    for ((i=0; i<NUMBER_OF_NODES; i++)); do
        PORT=$((3001+i))
        if curl -s -f http://localhost:$PORT/health > /dev/null 2>&1; then
            READY_COUNT=$((READY_COUNT + 1))
        else
            # Restart port-forward for this node if it's not responding
            if ! pgrep -f "port-forward pod/p2p-server-$i $PORT" > /dev/null 2>&1; then
                nohup kubectl port-forward pod/p2p-server-$i $PORT:$PORT >> server.log 2>&1 &
            fi
        fi
    done
    
    if [ $READY_COUNT -eq $NUMBER_OF_NODES ]; then
        break
    fi
    
    if [ $ELAPSED -ge $TIMEOUT ]; then
        log "${RED}✗ Timeout waiting for nodes to be ready${NC}"
        log "${YELLOW}Only $READY_COUNT/$NUMBER_OF_NODES nodes are responding${NC}"
        for ((i=0; i<NUMBER_OF_NODES; i++)); do
            PORT=$((3001+i))
            STATUS=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:$PORT/health 2>/dev/null || echo "unreachable")
            log "  Node $i (port $PORT): $STATUS"
        done
        exit 1
    fi
    
    sleep 2
    ELAPSED=$((ELAPSED + 2))
    echo -ne "  Ready: $READY_COUNT/$NUMBER_OF_NODES nodes... ${ELAPSED}s\r"
done

log "${GREEN}✓ All $NUMBER_OF_NODES nodes are ready${NC}"
echo

# Step 3: Run JMeter test
log "${BLUE}Step 3: Running JMeter performance test...${NC}"
log "  Duration: ${JMETER_DURATION}s"
log "  Threads: ${JMETER_THREADS}"
log "  Ramp-up: ${JMETER_RAMP_UP}s"
echo

# Start port-forward watchdog (restarts any dead forwards every 15s during JMeter)
(
    while true; do
        sleep 15
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
    -e -o "${RESULTS_DIR}/pbft-enhanced-${TIMESTAMP}-report" 2>&1 | tee -a server.log

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
DRAIN_TIMEOUT=300
DRAIN_ELAPSED=0
PREV_UNASSIGNED=-1
UNCHANGED_COUNT=0
DRAIN_END_TIME=0
while [ $DRAIN_ELAPSED -lt $DRAIN_TIMEOUT ]; do
    sleep 10
    DRAIN_ELAPSED=$((DRAIN_ELAPSED + 10))
    for ((i=0; i<NUMBER_OF_NODES; i++)); do
        PORT=$((3001+i))
        DRAIN_STATS=$(curl -s --max-time 10 http://localhost:$PORT/stats 2>/dev/null || echo '')
        if [ -n "$DRAIN_STATS" ]; then
            CUR_UNASSIGNED=$(echo "$DRAIN_STATS" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    total = sum(v.get('unassignedTransactions', 0) for v in d.get('total', {}).values())
    print(total)
except: print(-1)
" 2>/dev/null || echo -1)
            echo -ne "  Drain wait ${DRAIN_ELAPSED}s — unassigned: ${CUR_UNASSIGNED}\r"
            if [ "$CUR_UNASSIGNED" = "0" ]; then
                echo ""
                DRAIN_END_TIME=$(date +%s)
                log "${GREEN}✓ All transactions processed (unassigned=0)${NC}"
                break 2
            elif [ "$CUR_UNASSIGNED" = "$PREV_UNASSIGNED" ]; then
                UNCHANGED_COUNT=$((UNCHANGED_COUNT + 1))
                if [ $UNCHANGED_COUNT -ge 6 ]; then
                    echo ""
                    DRAIN_END_TIME=$(date +%s)
                    log "${YELLOW}Pool stalled at ${CUR_UNASSIGNED} unassigned (no change for 60s) — stopping drain wait${NC}"
                    break 2
                fi
            else
                UNCHANGED_COUNT=0
            fi
            PREV_UNASSIGNED=$CUR_UNASSIGNED
            break
        fi
    done
done
DRAIN_END_TIME=${DRAIN_END_TIME:-$(date +%s)}
TOTAL_ELAPSED=$(( DRAIN_END_TIME - TEST_START_TIME ))

# Step 4: Collect blockchain statistics
log "${BLUE}Step 4: Collecting blockchain statistics...${NC}"
{
    echo "PBFT-Enhanced Performance Test Results"
    echo "========================================"
    echo "Timestamp: ${TIMESTAMP}"
    echo "Configuration:"
    echo "  - Number of Nodes: ${NUMBER_OF_NODES}"
    echo "  - Transaction Threshold: ${TRANSACTION_THRESHOLD}"
    echo "  - Faulty Nodes: ${NUMBER_OF_FAULTY_NODES}"
    echo "  - CPU Limit: ${CPU_LIMIT}"
    echo ""
    echo "JMeter Configuration:"
    echo "  - Threads: ${JMETER_THREADS}"
    echo "  - Ramp-up: ${JMETER_RAMP_UP}s"
    echo "  - Duration: ${JMETER_DURATION}s"
    echo "  - Target Throughput: ${JMETER_THROUGHPUT} req/s"
    echo ""
    echo "Blockchain Statistics (By Shard):"
    echo "========================================"
    
    # Helper: parse a scalar value from JSON using jq or python3
    json_val() {
        local json="$1"
        local jq_expr="$2"
        local py_expr="$3"
        if command -v jq &> /dev/null; then
            echo "$json" | jq -r "$jq_expr" 2>/dev/null
        else
            echo "$json" | python3 -c "import sys,json; data=json.load(sys.stdin); print($py_expr)" 2>/dev/null
        fi
    }

    TOTAL_BLOCKS=0
    TOTAL_TX_IN_BLOCKS=0
    TOTAL_UNASSIGNED_TX=0

    # Query ALL nodes and aggregate stats across all unique shards
    # Each node only knows its own shard, so we must collect from all
    # Note: avoid declare -A (not available in bash 3.2 on macOS)
    SEEN_SHARDS=""
    for ((i=0; i<NUMBER_OF_NODES; i++)); do
        PORT=$((3001+i))
        CANDIDATE=$(curl -s --max-time 10 http://localhost:$PORT/stats 2>/dev/null || echo '')
        if [ -z "$CANDIDATE" ] || ! echo "$CANDIDATE" | python3 -c "import sys,json; json.load(sys.stdin)" 2>/dev/null; then
            continue
        fi

        # Get shard indices from this node's stats
        NODE_SHARDS=$(echo "$CANDIDATE" | python3 -c "import sys,json; d=json.load(sys.stdin); [print(k) for k in d.get('total',{})]" 2>/dev/null)
        for SHARD_IDX in $NODE_SHARDS; do
            # Skip if we already counted this shard
            if echo "$SEEN_SHARDS" | grep -qw "$SHARD_IDX"; then
                continue
            fi
            SEEN_SHARDS="$SEEN_SHARDS $SHARD_IDX"

            BLOCKS=$(echo "$CANDIDATE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['total']['$SHARD_IDX'].get('blocks',0))" 2>/dev/null || echo 0)
            TX=$(echo "$CANDIDATE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['total']['$SHARD_IDX'].get('transactions',0))" 2>/dev/null || echo 0)
            UNASSIGNED=$(echo "$CANDIDATE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['total']['$SHARD_IDX'].get('unassignedTransactions',0))" 2>/dev/null || echo 0)

            BLOCKS=${BLOCKS:-0}
            TX=${TX:-0}
            UNASSIGNED=${UNASSIGNED:-0}

            echo ""
            echo "Shard $SHARD_IDX (node $i, port $PORT):"
            echo "----------------------------------------"
            echo "  Blocks Created: $BLOCKS"
            echo "  Transactions in Blocks: $TX"
            echo "  Unassigned Transactions: $UNASSIGNED"

            TOTAL_BLOCKS=$((TOTAL_BLOCKS + BLOCKS))
            TOTAL_TX_IN_BLOCKS=$((TOTAL_TX_IN_BLOCKS + TX))
            TOTAL_UNASSIGNED_TX=$((TOTAL_UNASSIGNED_TX + UNASSIGNED))
        done
    done

    if [ -z "$SEEN_SHARDS" ]; then
        echo ""
        echo "  (No node responded to /stats query)"
    fi
    
    echo ""
    echo "========================================"
    echo "TOTAL (All Shards):"
    echo "========================================"
    echo "Total Blocks Created: $TOTAL_BLOCKS"
    echo "Total Transactions in Blocks: $TOTAL_TX_IN_BLOCKS"
    echo "Total Unassigned Transactions: $TOTAL_UNASSIGNED_TX"
    echo ""
    echo "UNASSIGNED TRANSACTION REASONS:"
    echo "  - Transaction pool not full (threshold: ${TRANSACTION_THRESHOLD})"
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
            # Count transaction requests fired by JMeter (URL column 14 contains /transaction)
            JMETER_FIRED=$(awk -F',' 'NR>1 && $14 ~ /\/transaction/ {count++} END {print count+0}' "${RESULTS_FILE}")
            BLOCKS_RAW=$(grep "Total Blocks Created:" "${SUMMARY_FILE}" | tail -1 | awk '{print $NF}')
            TX_IN_BLOCKS_RAW=$(grep "Total Transactions in Blocks:" "${SUMMARY_FILE}" | tail -1 | awk '{print $NF}')
            UNASSIGNED_RAW=$(grep "Total Unassigned Transactions:" "${SUMMARY_FILE}" | tail -1 | awk '{print $NF}')
            
            # Each incoming transaction is duplicated in appP2p.js (dual-shard simulation),
            # so every raw count is doubled. Halve to get unique transaction/block counts.
            BLOCKS=$(echo "${BLOCKS_RAW:-0} / 2" | bc)
            TX_IN_BLOCKS=$(echo "${TX_IN_BLOCKS_RAW:-0} / 2" | bc)
            UNASSIGNED=$(echo "${UNASSIGNED_RAW:-0} / 2" | bc)
            
            echo "Transactions Fired by Test,${JMETER_FIRED:-0}"
            echo "Total Blocks Created,${BLOCKS:-0}"
            echo "Transactions in Blocks,${TX_IN_BLOCKS}"
            echo "Unassigned Transactions,${UNASSIGNED}"
            
            # Calculate block efficiency
            if [ "${BLOCKS:-0}" -gt 0 ] && [ "${TX_IN_BLOCKS:-0}" -gt 0 ]; then
                AVG_TX_PER_BLOCK=$(echo "scale=2; $TX_IN_BLOCKS / $BLOCKS" | bc)
                echo "Avg Transactions per Block,$AVG_TX_PER_BLOCK"
            fi
            
            # Blockchain transaction rate over total test+drain time (using deduplicated count)
            if [ "${TOTAL_ELAPSED:-0}" -gt 0 ] && [ "${TX_IN_BLOCKS:-0}" -gt 0 ]; then
                BLOCKCHAIN_TX_RATE=$(echo "scale=2; ${TX_IN_BLOCKS} / ${TOTAL_ELAPSED}" | bc)
                echo "Total Test Elapsed (s),${TOTAL_ELAPSED}"
                echo "Blockchain TX Rate (tx/s),${BLOCKCHAIN_TX_RATE}"
            fi
        fi
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
log "  - HTML Report: ${RESULTS_DIR}/pbft-enhanced-${TIMESTAMP}-report/index.html"
echo

if [ -f "${STATS_FILE}" ]; then
    log "${GREEN}Quick Stats:${NC}"
    cat "${STATS_FILE}" | tee -a server.log
fi

log "${BLUE}========================================${NC}"
