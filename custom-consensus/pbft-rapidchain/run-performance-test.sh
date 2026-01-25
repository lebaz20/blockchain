#!/bin/bash

# Performance Test Script for PBFT-RapidChain
# This script starts the blockchain using start.sh, runs JMeter tests, and saves performance results

set -e

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

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

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}PBFT-RapidChain Performance Test${NC}"
echo -e "${BLUE}========================================${NC}"
echo -e "Nodes: ${NUMBER_OF_NODES}"
echo -e "Transaction Threshold: ${TRANSACTION_THRESHOLD}"
echo -e "Block Threshold: ${BLOCK_THRESHOLD}"
echo -e "Committee Shard: ${HAS_COMMITTEE_SHARD}"
echo -e "JMeter Threads: ${JMETER_THREADS}"
echo -e "Test Duration: ${JMETER_DURATION}s"
echo -e "${BLUE}========================================${NC}\n"

# Create results directory
mkdir -p "${RESULTS_DIR}"

# Cleanup function
cleanup() {
    echo -e "\n${YELLOW}Cleaning up...${NC}"
    
    # Stop port forwarding
    pkill -f "kubectl port-forward" || true
    
    # Delete Kubernetes resources
    kubectl delete -f kubeConfig.yml --ignore-not-found || true
    
    echo -e "${GREEN}Cleanup complete${NC}"
}

# Set trap to cleanup on exit
trap cleanup EXIT INT TERM

# Step 1: Start blockchain using existing start.sh
echo -e "${BLUE}Step 1: Starting blockchain (using start.sh)...${NC}"
# Kill start.sh after deployment is complete (before it starts log streaming)
(
    ./start.sh &
    START_PID=$!
    
    # Wait for port forwarding to be set up
    sleep 15
    
    # Kill start.sh to prevent log streaming
    kill $START_PID 2>/dev/null || true
) > /dev/null 2>&1

echo -e "${GREEN}✓ Blockchain deployed and ready${NC}\n"

# Step 2: Wait for blockchain to stabilize
echo -e "${BLUE}Step 2: Waiting for blockchain to stabilize...${NC}"
sleep 10
echo -e "${GREEN}✓ Blockchain ready${NC}\n"

# Step 3: Run JMeter test
echo -e "${BLUE}Step 3: Running JMeter performance test...${NC}"
echo -e "  Duration: ${JMETER_DURATION}s"
echo -e "  Threads: ${JMETER_THREADS}"
echo -e "  Ramp-up: ${JMETER_RAMP_UP}s\n"

jmeter -n -t "Test Plan.jmx" \
    -Jthreads=${JMETER_THREADS} \
    -Jrampup=${JMETER_RAMP_UP} \
    -Jduration=${JMETER_DURATION} \
    -Jthroughput=${JMETER_THROUGHPUT} \
    -l "${RESULTS_FILE}" \
    -e -o "${RESULTS_DIR}/pbft-rapidchain-${TIMESTAMP}-report"

echo -e "${GREEN}✓ JMeter test completed${NC}\n"

# Step 4: Collect blockchain statistics
echo -e "${BLUE}Step 4: Collecting blockchain statistics...${NC}"
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
    echo "Blockchain Statistics:"
    for ((i=0; i<NUMBER_OF_NODES; i++)); do
        PORT=$((3001+i))
        echo "  Node $i (port $PORT):"
        STATS=$(curl -s http://localhost:$PORT/stats 2>/dev/null || echo '{"error": "unavailable"}')
        echo "    $STATS"
    done
} > "${SUMMARY_FILE}"

echo -e "${GREEN}✓ Statistics collected${NC}\n"

# Step 5: Parse JMeter results
echo -e "${BLUE}Step 5: Parsing JMeter results...${NC}"
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
    } > "${STATS_FILE}"
    
    echo -e "${GREEN}✓ Results parsed${NC}\n"
fi

# Display summary
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Performance Test Complete!${NC}"
echo -e "${BLUE}========================================${NC}"
echo -e "Results saved to:"
echo -e "  - Summary: ${SUMMARY_FILE}"
echo -e "  - Stats: ${STATS_FILE}"
echo -e "  - Raw data: ${RESULTS_FILE}"
echo -e "  - HTML Report: ${RESULTS_DIR}/pbft-rapidchain-${TIMESTAMP}-report/index.html"
echo -e ""

if [ -f "${STATS_FILE}" ]; then
    echo -e "${GREEN}Quick Stats:${NC}"
    cat "${STATS_FILE}"
fi

echo -e "\n${BLUE}========================================${NC}"
