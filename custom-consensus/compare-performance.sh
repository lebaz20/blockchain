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

# Test 1: PBFT-Enhanced
echo -e "${CYAN}========================================${NC}"
echo -e "${CYAN}Test 1: PBFT-Enhanced${NC}"
echo -e "${CYAN}========================================${NC}\n"

cd pbft-enhanced
./run-performance-test.sh
ENHANCED_STATS=$(ls -t performance-results/*-stats.csv | head -1)
ENHANCED_SUMMARY=$(ls -t performance-results/*-summary.txt | head -1)
cd ..

echo -e "\n${GREEN}✓ PBFT-Enhanced test completed${NC}\n"
sleep 5

# Test 2: PBFT-RapidChain
echo -e "${CYAN}========================================${NC}"
echo -e "${CYAN}Test 2: PBFT-RapidChain${NC}"
echo -e "${CYAN}========================================${NC}\n"

cd pbft-rapidchain
./run-performance-test.sh
RAPIDCHAIN_STATS=$(ls -t performance-results/*-stats.csv | head -1)
RAPIDCHAIN_SUMMARY=$(ls -t performance-results/*-summary.txt | head -1)
cd ..

echo -e "\n${GREEN}✓ PBFT-RapidChain test completed${NC}\n"

# Generate comparison report
echo -e "${CYAN}========================================${NC}"
echo -e "${CYAN}Generating Comparison Report${NC}"
echo -e "${CYAN}========================================${NC}\n"

{
    echo "# Blockchain Performance Comparison"
    echo ""
    echo "**Test Date:** $(date '+%Y-%m-%d %H:%M:%S')"
    echo ""
    echo "## Test Configuration"
    echo ""
    echo "- **Number of Nodes:** 4"
    echo "- **JMeter Threads:** 10"
    echo "- **Test Duration:** 60 seconds"
    echo "- **Ramp-up Time:** 5 seconds"
    echo ""
    echo "---"
    echo ""
    echo "## Results Summary"
    echo ""
    echo "### PBFT-Enhanced"
    echo ""
    echo "\`\`\`"
    cat "pbft-enhanced/$ENHANCED_STATS"
    echo "\`\`\`"
    echo ""
    echo "### PBFT-RapidChain (Committee-Based)"
    echo ""
    echo "\`\`\`"
    cat "pbft-rapidchain/$RAPIDCHAIN_STATS"
    echo "\`\`\`"
    echo ""
    echo "---"
    echo ""
    echo "## Detailed Comparison"
    echo ""
    echo "| Metric | PBFT-Enhanced | PBFT-RapidChain | Winner |"
    echo "|--------|---------------|-----------------|--------|"
    
    # Extract metrics and compare
    extract_metric() {
        local file=$1
        local metric=$2
        grep "^$metric," "$file" | cut -d',' -f2
    }
    
    # Throughput
    ENH_TP=$(extract_metric "pbft-enhanced/$ENHANCED_STATS" "Throughput (req/s)")
    RC_TP=$(extract_metric "pbft-rapidchain/$RAPIDCHAIN_STATS" "Throughput (req/s)")
    if (( $(echo "$ENH_TP > $RC_TP" | bc -l) )); then
        TP_WINNER="**Enhanced** 🏆"
    else
        TP_WINNER="**RapidChain** 🏆"
    fi
    echo "| Throughput (req/s) | $ENH_TP | $RC_TP | $TP_WINNER |"
    
    # Response Time
    ENH_RT=$(extract_metric "pbft-enhanced/$ENHANCED_STATS" "Average Response Time (ms)")
    RC_RT=$(extract_metric "pbft-rapidchain/$RAPIDCHAIN_STATS" "Average Response Time (ms)")
    if [ "$ENH_RT" -lt "$RC_RT" ]; then
        RT_WINNER="**Enhanced** 🏆"
    else
        RT_WINNER="**RapidChain** 🏆"
    fi
    echo "| Avg Response Time (ms) | $ENH_RT | $RC_RT | $RT_WINNER |"
    
    # Success Rate
    ENH_SR=$(extract_metric "pbft-enhanced/$ENHANCED_STATS" "Success Rate (%)")
    RC_SR=$(extract_metric "pbft-rapidchain/$RAPIDCHAIN_STATS" "Success Rate (%)")
    if (( $(echo "$ENH_SR > $RC_SR" | bc -l) )); then
        SR_WINNER="**Enhanced** 🏆"
    else
        SR_WINNER="**RapidChain** 🏆"
    fi
    echo "| Success Rate (%) | $ENH_SR | $RC_SR | $SR_WINNER |"
    
    # Blocks Created
    ENH_BL=$(extract_metric "pbft-enhanced/$ENHANCED_STATS" "Total Blocks Created")
    RC_BL=$(extract_metric "pbft-rapidchain/$RAPIDCHAIN_STATS" "Total Blocks Created")
    if [ "$ENH_BL" -gt "$RC_BL" ]; then
        BL_WINNER="**Enhanced** 🏆"
    else
        BL_WINNER="**RapidChain** 🏆"
    fi
    echo "| Blocks Created | $ENH_BL | $RC_BL | $BL_WINNER |"
    
    # Transactions in Blocks
    ENH_TX=$(extract_metric "pbft-enhanced/$ENHANCED_STATS" "Transactions in Blocks")
    RC_TX=$(extract_metric "pbft-rapidchain/$RAPIDCHAIN_STATS" "Transactions in Blocks")
    if [ "$ENH_TX" -gt "$RC_TX" ]; then
        TX_WINNER="**Enhanced** 🏆"
    else
        TX_WINNER="**RapidChain** 🏆"
    fi
    echo "| Transactions in Blocks | $ENH_TX | $RC_TX | $TX_WINNER |"
    
    # Avg TX per Block
    ENH_AVG=$(extract_metric "pbft-enhanced/$ENHANCED_STATS" "Avg Transactions per Block")
    RC_AVG=$(extract_metric "pbft-rapidchain/$RAPIDCHAIN_STATS" "Avg Transactions per Block")
    if (( $(echo "$ENH_AVG > $RC_AVG" | bc -l) )); then
        AVG_WINNER="**Enhanced** 🏆"
    else
        AVG_WINNER="**RapidChain** 🏆"
    fi
    echo "| Avg TX per Block | $ENH_AVG | $RC_AVG | $AVG_WINNER |"
    
    echo ""
    echo "---"
    echo ""
    echo "## Analysis"
    echo ""
    echo "### PBFT-Enhanced"
    echo ""
    echo "**Strengths:**"
    echo "- Simple single-shard architecture"
    echo "- Direct consensus without committee layer"
    echo "- Lower latency for transaction processing"
    echo ""
    echo "**Characteristics:**"
    echo "- All nodes participate in consensus for every block"
    echo "- Simpler message flow"
    echo "- Best for smaller networks (4-16 nodes)"
    echo ""
    echo "### PBFT-RapidChain"
    echo ""
    echo "**Strengths:**"
    echo "- Two-level consensus (shard + committee)"
    echo "- Committee validates blocks from shards"
    echo "- Better scalability for larger networks"
    echo ""
    echo "**Characteristics:**"
    echo "- Block threshold: 10 (batches blocks for committee validation)"
    echo "- Additional validation layer adds security"
    echo "- Committee shard provides cross-shard coordination"
    echo "- Best for larger networks (>16 nodes) with multiple shards"
    echo ""
    echo "---"
    echo ""
    echo "## Recommendation"
    echo ""
    
    # Determine overall winner based on key metrics
    ENH_SCORE=0
    RC_SCORE=0
    
    [ "$(echo "$ENH_TP > $RC_TP" | bc -l)" -eq 1 ] && ENH_SCORE=$((ENH_SCORE + 2)) || RC_SCORE=$((RC_SCORE + 2))
    [ "$ENH_RT" -lt "$RC_RT" ] && ENH_SCORE=$((ENH_SCORE + 2)) || RC_SCORE=$((RC_SCORE + 2))
    [ "$(echo "$ENH_SR > $RC_SR" | bc -l)" -eq 1 ] && ENH_SCORE=$((ENH_SCORE + 3)) || RC_SCORE=$((RC_SCORE + 3))
    [ "$ENH_TX" -gt "$RC_TX" ] && ENH_SCORE=$((ENH_SCORE + 2)) || RC_SCORE=$((RC_SCORE + 2))
    
    if [ $ENH_SCORE -gt $RC_SCORE ]; then
        echo "**🏆 Winner: PBFT-Enhanced**"
        echo ""
        echo "For the current configuration (4 nodes), PBFT-Enhanced performs better due to:"
        echo "- Lower overhead from simpler architecture"
        echo "- Faster consensus without committee layer"
        echo "- Better suited for small node counts"
        echo ""
        echo "**When to use RapidChain instead:**"
        echo "- Networks with >16 nodes"
        echo "- Multiple shards needed for horizontal scaling"
        echo "- Cross-shard transaction coordination required"
    else
        echo "**🏆 Winner: PBFT-RapidChain**"
        echo ""
        echo "RapidChain's committee-based consensus shows advantages even at 4 nodes:"
        echo "- Better block batching efficiency"
        echo "- Committee validation adds security layer"
        echo "- Architecture ready for horizontal scaling"
        echo ""
        echo "**When Enhanced might be better:**"
        echo "- Very small networks (2-8 nodes)"
        echo "- Minimal latency requirements"
        echo "- Simpler deployment and maintenance preferred"
    fi
    
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
