# Blockchain Performance Comparison

**Test Date:** 2026-03-01 03:50:59

## Test Configuration

- **Number of Nodes (Enhanced):** 16
- **JMeter Threads:** 10
- **Test Duration:** 60 seconds
- **Ramp-up Time:** 5 seconds

---

## Results Summary

### PBFT-Enhanced

```
Metric,Value
Total Samples,10509
Average Response Time (ms),109
Success Rate (%),100.00
Throughput (req/s),175.15
Transactions Fired by Test,3503
Total Blocks Created,24
Transactions in Blocks,2000
Unassigned Transactions,797
Avg Transactions per Block,83.33
```

### PBFT-RapidChain (Committee-Based)

```
Metric,Value
Total Samples,9823
Average Response Time (ms),113
Success Rate (%),88.02
Throughput (req/s),163.71
Transactions Fired by Test,2913
Total Blocks Created,5
Transactions in Blocks,400
Unassigned Transactions,544
Avg Transactions per Block,80.00
```

---

## Detailed Comparison

| Metric | PBFT-Enhanced | PBFT-RapidChain | Winner |
|--------|---------------|-----------------|--------|
| Throughput (req/s) | 175.15 | 163.71 | **Enhanced** 🏆 |
| Avg Response Time (ms) | 109 | 113 | **Enhanced** 🏆 |
| Success Rate (%) | 100.00 | 88.02 | **Enhanced** 🏆 |
| Blocks Created | 24 | 5 | **Enhanced** 🏆 |
| Transactions in Blocks | 2000 | 400 | **Enhanced** 🏆 |
| Avg TX per Block | 83.33 | 80.00 | **Enhanced** 🏆 |

---

## Analysis

### PBFT-Enhanced

**Strengths:**
- Simple single-shard architecture
- Direct consensus without committee layer
- Lower latency for transaction processing

**Characteristics:**
- All nodes participate in consensus for every block
- Simpler message flow
- Best for smaller networks (4-16 nodes)

### PBFT-RapidChain

**Strengths:**
- Two-level consensus (shard + committee)
- Committee validates blocks from shards
- Better scalability for larger networks

**Characteristics:**
- Block threshold: 10 (batches blocks for committee validation)
- Additional validation layer adds security
- Committee shard provides cross-shard coordination
- Best for larger networks (>16 nodes) with multiple shards

---

## Recommendation

**🏆 Winner: PBFT-Enhanced**

For the current configuration (4 nodes), PBFT-Enhanced performs better due to:
- Lower overhead from simpler architecture
- Faster consensus without committee layer
- Better suited for small node counts

**When to use RapidChain instead:**
- Networks with >16 nodes
- Multiple shards needed for horizontal scaling
- Cross-shard transaction coordination required

---

## Full Reports

- **PBFT-Enhanced Summary:** `pbft-enhanced/performance-results/pbft-enhanced-20260301_034447-summary.txt`
- **PBFT-RapidChain Summary:** `pbft-rapidchain/performance-results/pbft-rapidchain-20260301_034803-summary.txt`
