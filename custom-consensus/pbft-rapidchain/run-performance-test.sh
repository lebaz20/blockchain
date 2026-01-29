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
export NUMBER_OF_NODES=${NUMBER_OF_NODES:-4}
export TRANSACTION_THRESHOLD=${TRANSACTION_THRESHOLD:-100}
export BLOCK_THRESHOLD=${BLOCK_THRESHOLD:-10}
export NUMBER_OF_FAULTY_NODES=${NUMBER_OF_FAULTY_NODES:-0}
export NUMBER_OF_NODES_PER_SHARD=${NUMBER_OF_NODES_PER_SHARD:-4}
export HAS_COMMITTEE_SHARD=${HAS_COMMITTEE_SHARD:-1}
export SHOULD_REDIRECT_FROM_FAULTY_NODES=${SHOULD_REDIRECT_FROM_FAULTY_NODES:-0}
export CPU_LIMIT=${CPU_LIMIT:-0.1}

# JMeter configuration
JMETER_THREADS=${JMETER_THREADS:-10}
JMETER_RAMP_UP=${JMETER_RAMP_UP:-5}
JMETER_DURATION=${JMETER_DURATION:-60}
JMETER_THROUGHPUT=${JMETER_THROUGHPUT:-100}

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
TIMEOUT=120
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

# Kill start.sh to prevent log streaming (but keep port forwarding alive)
kill $START_PID 2>/dev/null || true

log "${GREEN}✓ Blockchain deployed and ready${NC}"
echo

# Step 2: Wait for blockchain to stabilize
log "${BLUE}Step 2: Waiting for all nodes to be ready...${NC}"
TIMEOUT=90
ELAPSED=0
READY_COUNT=0

while [ $READY_COUNT -lt $NUMBER_OF_NODES ]; do
    READY_COUNT=0
    for ((i=0; i<NUMBER_OF_NODES; i++)); do
        PORT=$((3001+i))
        if curl -s -f http://localhost:$PORT/health > /dev/null 2>&1; then
            READY_COUNT=$((READY_COUNT + 1))
        fi
    done
    
    if [ $READY_COUNT -eq $NUMBER_OF_NODES ]; then
        break
    fi
    
    if [ $ELAPSED -ge $TIMEOUT ]; then
        log "${RED}✗ Timeout waiting for nodes to be ready${NC}"
        log "${YELLOW}Only $READY_COUNT/$NUMBER_OF_NODES nodes are responding${NC}"
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

jmeter -n -t "Test Plan.jmx" \
    -Jthreads=${JMETER_THREADS} \
    -Jrampup=${JMETER_RAMP_UP} \
    -Jduration=${JMETER_DURATION} \
    -Jthroughput=${JMETER_THROUGHPUT} \
    -l "${RESULTS_FILE}" \
    -e -o "${RESULTS_DIR}/pbft-rapidchain-${TIMESTAMP}-report" 2>&1 | tee -a server.log

log "${GREEN}✓ JMeter test completed${NC}"
echo

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
    
    # Simple approach: query one node and display shard stats
    # All nodes in a shard have the same blockchain state
    TOTAL_BLOCKS=0
    TOTAL_TX_IN_BLOCKS=0
    TOTAL_UNASSIGNED_TX=0
    
    PORT=3001
    STATS=$(curl -s http://localhost:$PORT/stats 2>/dev/null || echo '{}')
    
    if [ "$STATS" != "{}" ] && command -v jq &> /dev/null; then
        # Get all shard indices
        SHARD_INDICES=$(echo "$STATS" | jq -r '.total | keys[]' 2>/dev/null)
        
        for SHARD_IDX in $SHARD_INDICES; do
            BLOCKS=$(echo "$STATS" | jq -r ".total[\"$SHARD_IDX\"].blocks // 0")
            TX=$(echo "$STATS" | jq -r ".total[\"$SHARD_IDX\"].transactions // 0")
            UNASSIGNED=$(echo "$STATS" | jq -r ".total[\"$SHARD_IDX\"].unassignedTransactions // 0")
            
            if [ "$SHARD_IDX" = "committee" ]; then
                echo ""
                echo "Shard committee:"
            else
                echo ""
                echo "Shard $SHARD_IDX:"
            fi
            echo "----------------------------------------"
            echo "  Blocks Created: $BLOCKS"
            echo "  Transactions in Blocks: $TX"
            echo "  Unassigned Transactions: $UNASSIGNED"
            
            TOTAL_BLOCKS=$((TOTAL_BLOCKS + BLOCKS))
            TOTAL_TX_IN_BLOCKS=$((TOTAL_TX_IN_BLOCKS + TX))
            TOTAL_UNASSIGNED_TX=$((TOTAL_UNASSIGNED_TX + UNASSIGNED))
        done
    else
        echo ""
        echo "(Install jq for detailed shard statistics: brew install jq)"
        # Fallback: show raw node data
        for ((i=0; i<NUMBER_OF_NODES; i++)); do
            PORT=$((3001+i))
            echo ""
            echo "Node $i (port $PORT):"
            STATS=$(curl -s http://localhost:$PORT/stats 2>/dev/null || echo '{"error": "unavailable"}')
            echo "  $STATS"
        done
    fi
    
    echo ""
    echo "=========================================="
    echo "TOTAL (All Shards):"
    echo "=========================================="
    echo "Total Blocks Created: $TOTAL_BLOCKS"
    echo "Total Transactions in Blocks: $TOTAL_TX_IN_BLOCKS"
    echo "Total Unassigned Transactions: $TOTAL_UNASSIGNED_TX"
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
        echo "Total Samples,$(grep -c '<httpSample' ${RESULTS_FILE} 2>/dev/null || echo 0)"
        
        # Calculate average response time
        AVG_TIME=$(awk -F',' 'NR>1 {sum+=$2; count++} END {if(count>0) print int(sum/count); else print 0}' "${RESULTS_FILE}")
        echo "Average Response Time (ms),$AVG_TIME"
        
        # Calculate success rate
        TOTAL=$(wc -l < "${RESULTS_FILE}" | tr -d ' ')
        SUCCESS=$(grep -c '"true"' "${RESULTS_FILE}" 2>/dev/null || echo 0)
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
            JMETER_FIRED=$(grep "Total Transactions Fired by Test:" "${SUMMARY_FILE}" | awk '{print $NF}')
            BLOCKS=$(grep "Total Blocks Created:" "${SUMMARY_FILE}" | tail -1 | awk '{print $NF}')
            TX_IN_BLOCKS=$(grep "Total Transactions in Blocks:" "${SUMMARY_FILE}" | tail -1 | awk '{print $NF}')
            UNASSIGNED=$(grep "Total Unassigned Transactions:" "${SUMMARY_FILE}" | tail -1 | awk '{print $NF}')
            
            echo "Transactions Fired by Test,${JMETER_FIRED:-0}"
            echo "Total Blocks Created,${BLOCKS:-0}"
            echo "Transactions in Blocks,${TX_IN_BLOCKS:-0}"
            echo "Unassigned Transactions,${UNASSIGNED:-0}"
            
            # Calculate block efficiency
            if [ "$BLOCKS" -gt 0 ] && [ "$TX_IN_BLOCKS" -gt 0 ]; then
                AVG_TX_PER_BLOCK=$(echo "scale=2; $TX_IN_BLOCKS / $BLOCKS" | bc)
                echo "Avg Transactions per Block,$AVG_TX_PER_BLOCK"
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
log "  - HTML Report: ${RESULTS_DIR}/pbft-rapidchain-${TIMESTAMP}-report/index.html"
echo

if [ -f "${STATS_FILE}" ]; then
    log "${GREEN}Quick Stats:${NC}"
    cat "${STATS_FILE}" | tee -a server.log
fi

log "${BLUE}========================================${NC}"
