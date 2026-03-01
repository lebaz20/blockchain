# Blockchain Performance Comparison

**Test Date:** 2026-03-01 04:01:08

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
Total Samples,4524
Average Response Time (ms),256
Success Rate (%),100.00
Throughput (req/s),75.40
Transactions Fired by Test,1508
Total Blocks Created,19
Transactions in Blocks,1338
Unassigned Transactions,28
Avg Transactions per Block,70.42
```

### PBFT-RapidChain (Committee-Based)

```
Metric,Value
Total Samples,17216
Average Response Time (ms),64
Success Rate (%),81.50
Throughput (req/s),286.93
Transactions Fired by Test,4716
Total Blocks Created,4
Transactions in Blocks,300
Unassigned Transactions,2268
Avg Transactions per Block,75.00
```

---

## Detailed Comparison

| Metric | PBFT-Enhanced | PBFT-RapidChain | Winner |
|--------|---------------|-----------------|--------|
| Throughput (req/s) | 75.40 | 286.93 | **RapidChain** 🏆 |
| Avg Response Time (ms) | 256 | 64 | **RapidChain** 🏆 |
| Success Rate (%) | 100.00 | 81.50 | **Enhanced** 🏆 |
| Blocks Created | 19 | 4 | **Enhanced** 🏆 |
| Transactions in Blocks | 1338 | 300 | **Enhanced** 🏆 |
| Avg TX per Block | 70.42 | 75.00 | **RapidChain** 🏆 |

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

- **PBFT-Enhanced Summary:** `pbft-enhanced/performance-results/pbft-enhanced-20260301_035520-summary.txt`
- **PBFT-RapidChain Summary:** `pbft-rapidchain/performance-results/pbft-rapidchain-20260301_035815-summary.txt`
