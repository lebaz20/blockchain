# Blockchain Performance Comparison

**Test Date:** 2026-03-11 01:07:01

## Test Configuration

| Parameter | Value | Meaning |
|-----------|-------|---------|
| Number of Nodes (Enhanced) | 24 | 24 P2P nodes ran the PBFT-Enhanced consensus; each participates in every round of consensus voting |
| Number of Nodes (RapidChain) | 24 total | Nodes split into shards of 4, plus 1 committee shard for cross-shard finality |
| Faulty Nodes (RapidChain) | 7 | Byzantine-simulated nodes that do not propose or vote in consensus |
| JMeter Threads | 10 | 10 concurrent virtual users sending HTTP POST `/transaction` requests in parallel |
| Test Duration | 90 s | JMeter fires transactions for 90 seconds; the clock starts after a 5 s ramp-up |
| Ramp-up Time | 5 s | JMeter linearly scales from 0 to 10 threads over the first 5 seconds to avoid a cold-start spike |

---

## Results Summary

### PBFT-Enhanced

| Metric | Value | What it means |
|--------|-------|---------------|
| Total Samples | 4168 | Total HTTP requests JMeter sent and received a response for (all endpoints combined: `/transaction`, `/stats`, etc.) |
| Average Response Time (ms) | 194 | Mean round-trip time for a single HTTP request from JMeter to the node and back |
| Success Rate (%) | 100.00 | Percentage of HTTP responses that returned a 2xx status |
| Throughput (req/s) | 46.31 | HTTP requests per second handled by the node API layer (JMeter perspective, all endpoints) |
| Transactions Fired by Test | 4168 | Number of those samples that were `POST /transaction` — the actual blockchain workload submitted |
| Total Blocks Created | 33 | Blocks appended to the blockchain during the entire test + drain window |
| Transactions in Blocks | 2059 | Real (non-duplicate) transactions confirmed on-chain; duplicate injections are excluded from this count |
| Unassigned Transactions | 1361 | Real transactions still waiting in the memory pool when the drain timeout expired — **never confirmed** |
| Avg Transactions per Block | 62.39 | `Transactions in Blocks ÷ Total Blocks Created` — computed on real transactions only |
| Total Test Elapsed (s) | 115 | Wall-clock seconds from test start until the pool drained to 0 (or stalled) — includes JMeter run + drain wait |
| Blockchain TX Rate (tx/s) | 17.90 | `Real Transactions in Blocks ÷ Total Test Elapsed` |
| Drain Rate (%) | 49.40 | `Real Transactions in Blocks ÷ Transactions Fired × 100` |
| Effective TX Rate (tx/s) | 8.84 | `Blockchain TX Rate × Drain Fraction` = `TX²  ÷ (Fired × Elapsed)` — penalises leaving txs unconfirmed |

> **Duplicate injection:** 1751 duplicate transactions were injected by Enhanced nodes (50% probability per transaction) to simulate dual-shard verification. All TX metrics above are corrected to reflect **real transactions only** using the formula `real = raw × fired / (fired + duplicates)`. (**warning:** only 17/24 nodes responded — duplicate count may be understated)

### PBFT-RapidChain (Committee-Based)

| Metric | Value | What it means |
|--------|-------|---------------|
| Total Samples | 6079 | Total HTTP requests JMeter sent and received a response for (all endpoints combined: `/transaction`, `/stats`, etc.) |
| Average Response Time (ms) | 126 | Mean round-trip time for a single HTTP request from JMeter to the node and back |
| Success Rate (%) | 86.01 | Percentage of HTTP responses that returned a 2xx status |
| Throughput (req/s) | 67.54 | HTTP requests per second handled by the node API layer (JMeter perspective, all endpoints) |
| Transactions Fired by Test | 6079 | Number of those samples that were `POST /transaction` — the actual blockchain workload submitted |
| Total Blocks Created | 27 | Blocks committed across all shards |
| Transactions in Blocks | 2700 | Unique transactions confirmed on-chain across all shards |
| Unassigned Transactions | 667 | Transactions still in shard memory pools at the end — **never confirmed** |
| Avg Transactions per Block | 100.00 | `Transactions in Blocks ÷ Total Blocks Created` |
| Total Test Elapsed (s) | 198 | Wall-clock seconds from test start until drain stalled |
| Blockchain TX Rate (tx/s) | 13.63 | `Transactions in Blocks ÷ Total Test Elapsed` — raw number can be **misleading** (see below) |
| Drain Rate (%) | 44.41 | `Transactions in Blocks ÷ Transactions Fired × 100` — how much of what was submitted actually got confirmed |
| Effective TX Rate (tx/s) | 6.05 | `TX² ÷ (Fired × Elapsed)` — corrects for input volume differences between the two runs |

---

## Why Blockchain TX Rate Alone is Misleading

The two implementations may have a backlog of unassigned transactions still being processed while test period is complete.

The fair comparison is **Effective TX Rate**, which multiplies the raw rate by the drain fraction:

```
Effective TX Rate = TX_IN_BLOCKS² / (TRANSACTIONS_FIRED × TOTAL_ELAPSED)
```

| | Fired | Confirmed | Drain % | Raw TX Rate | Effective TX Rate |
|---|---|---|---|---|---|
| **PBFT-Enhanced** | 4168 | 2059 | **~49.40%** | 17.90 tx/s | **~8.84 tx/s** |
| **PBFT-RapidChain** | 6079 | 2700 | **~44.41%** | 13.63 tx/s | **~6.05 tx/s** |

See the Detailed Comparison and Effective TX Rate rows above for the run-specific verdict.

---

## Detailed Comparison

| Metric | PBFT-Enhanced | PBFT-RapidChain | Winner |
|--------|---------------|-----------------|--------|
| Throughput (req/s) ¹ | 46.31 | 67.54 | **RapidChain** 🏆 |
| Avg Response Time (ms) ² | 194 | 126 | **RapidChain** 🏆 |
| Success Rate (%) ³ | 100.00 | 86.01 | **Enhanced** 🏆 |
| Blocks Created | 33 | 27 | **Enhanced** 🏆 |
| Transactions in Blocks ⁴ | 2059 | 2700 | **RapidChain** 🏆 |
| Avg TX per Block | 62.39 | 100.00 | **RapidChain** 🏆 |
| Blockchain TX Rate (tx/s) ⁵ | 17.90 | 13.63 | _(see Effective TX Rate)_ |
| Drain Rate (%) ⁶ | 49.40 | 44.41 | **Enhanced** 🏆 |
| Effective TX Rate (tx/s) ⁷ | 8.84 | 6.05 | **Enhanced** 🏆 |
| Total Test Elapsed (s) ⁸ | 115 | 198 | _(lower = faster drain)_ |

**Footnotes:**

¹ **Throughput (req/s):** HTTP-layer requests/s seen by JMeter. Reflects HTTP concurrency driven by response latency — not a direct measure of blockchain efficiency.

² **Avg Response Time (ms):** Time for the node to acknowledge a transaction over HTTP. Enhanced performs upfront PBFT validation before responding; RapidChain queues immediately and responds.

³ **Success Rate (%):** HTTP 2xx responses. Any value below 100% indicates dropped requests under high load (pool-full or node errors).

⁴ **Transactions in Blocks:** Confirmed on-chain transactions. An implementation that receives more total input will naturally confirm more in absolute terms; use Drain Rate for a normalised comparison.

⁵ **Blockchain TX Rate (tx/s):** `Confirmed ÷ Elapsed`. Biased in favour of whichever implementation received more raw input. Do not use as the sole winner criterion.

⁶ **Drain Rate (%):** `Confirmed ÷ Fired × 100`. The most direct measure of whether the consensus mechanism actually processes everything it accepts.

⁷ **Effective TX Rate (tx/s):** `Blockchain TX Rate × Drain Fraction`. Corrects for input volume differences. This is the fairest single-number comparison between the two systems.

⁸ **Total Test Elapsed (s):** Wall-clock seconds from start until the unassigned pool reached 0 or stalled. Includes the 90 s JMeter run plus however long the drain wait took.

---

## Analysis

### PBFT-Enhanced

**Strengths:**
- 100.00% HTTP success rate
- 49.40% drain rate (share of submitted transactions confirmed on-chain)
- Single-layer consensus (no committee stage) with lower operational complexity

**Characteristics:**
- Sharded PBFT (4 nodes/shard); within each shard all nodes participate in consensus (O(n²) message complexity per shard)
- `TRANSACTION_THRESHOLD` controls block batching; no second consensus layer
- Scales well when `NUMBER_OF_NODES_PER_SHARD` is sized so each shard can tolerate the expected faulty count (f = floor((shard_size-1)/3))

### PBFT-RapidChain

**Strengths:**
- 126 ms average HTTP response time
- 44.41% drain rate (share of submitted transactions confirmed on-chain)
- Architecture designed for horizontal scaling via sharding

**Characteristics:**
- Two-level consensus: each shard runs PBFT internally, then a committee shard validates batches of shard blocks (`BLOCK_THRESHOLD`)
- The committee layer creates a second pipeline stage; if too few shard blocks accumulate, the committee does not trigger and txs stall
- `getTotal()` currently only counts `transactions.unassigned`, not `committeeTransactions.unassigned` — the drain monitor can declare done while committee-layer transactions are still pending
- Non-proposer redistribution workaround (re-broadcasts txs every 10 s) causes O(n²) bandwidth growth and timing races on proposer rotation
- Best for larger networks (>16 nodes) that need cross-shard coordination

---

## Recommendation

**🏆 Winner: PBFT-Enhanced**

For 24 nodes, PBFT-Enhanced performs better overall:
- **100.00% acceptance rate** vs RapidChain's 86.01%
- **49.40% drain rate**
- Higher Effective TX Rate (8.84 vs 6.05 tx/s) after correcting for input volume
- Simpler architecture with no committee-layer pipeline stalls

**When RapidChain becomes the right choice:**
- Networks exceeding 32+ nodes where O(n²) PBFT message complexity becomes a bottleneck
- Multi-shard deployments where cross-shard coordination is required
- After fixing: (i) `getTotal()` to include committee pool, (ii) the drain detection logic, and (iii) the committee threshold to fire on partial batches

---

## Full Reports

- **PBFT-Enhanced Summary:** `pbft-enhanced/performance-results/pbft-enhanced-20260311_005845-summary.txt`
- **PBFT-RapidChain Summary:** `pbft-rapidchain/performance-results/pbft-rapidchain-20260311_010212-summary.txt`
