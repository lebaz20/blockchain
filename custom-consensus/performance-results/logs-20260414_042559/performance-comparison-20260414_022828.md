# Blockchain Performance Comparison

**Test Date:** 2026-04-14 02:46:51

## Test Configuration

| Parameter | Value | Meaning |
|-----------|-------|---------|
| Number of Nodes (Enhanced) | 128 | 128 P2P nodes ran the PBFT-Enhanced consensus; each participates in every round of consensus voting |
| Number of Nodes (RapidChain) | 128 total | Nodes split into shards of 4, plus 1 committee shard for cross-shard finality |
| Faulty Nodes (RapidChain) | 42 | Byzantine-simulated nodes that do not propose or vote in consensus |
| JMeter Threads | 220 | 220 concurrent virtual users — identical for both protocols; high enough that the ConstantThroughputTimer cap (366 req/s) is the actual bottleneck rather than thread count |
| Test Duration | 100 s | JMeter fires transactions for 100 seconds total; active load = 70 s, ramp-down = 30 s |
| Ramp-up Time | 5 s | JMeter linearly scales from 0 to 220 threads over the first 5 seconds to avoid a cold-start spike |
| Ramp-down Time | 30 s | Last 30 s of the test window: no new transactions — blockchain completes in-flight blocks before the drain wait begins |
| Cross-Shard Verification | Cyclic healthy-shard ring | Each healthy shard verifies the next healthy shard in the ring; dead shards are skipped automatically — verification TXs are counted separately and excluded from all performance metrics |

---

## Results Summary

### PBFT-Enhanced

| Metric | Value | What it means |
|--------|-------|---------------|
| Total Samples | 22861 | Total HTTP requests JMeter sent and received a response for (all endpoints combined: `/transaction`, `/stats`, etc.) |
| Average Response Time (ms) | 157 | Mean round-trip time for a single HTTP request from JMeter to the node and back |
| Success Rate (%) | 100.00 | Percentage of HTTP responses that returned a 2xx status |
| Throughput (req/s) | 228.61 | HTTP requests per second handled by the node API layer (JMeter perspective, all endpoints) |
| Transactions Fired by Test | 22861 | Number of those samples that were `POST /transaction` — the actual blockchain workload submitted |
| Total Blocks Created | 141 | Blocks appended to the blockchain during the entire test + drain window |
| Transactions in Blocks | 13374 | Normal client transactions confirmed on-chain; counted per-tx so verification TXs mixed into the same block are still excluded |
| Cross-Shard Verification TX | 0 | Transactions from other healthy shards re-validated and committed by this shard's PBFT — excluded from Transactions in Blocks, Drain Rate, and Effective TX Rate |
| Unassigned Transactions | 0 | Transactions still waiting in the memory pool when the drain timeout expired — **never confirmed** (normal + verification combined) |
| Verification Unassigned TX | 0 | Of the unassigned above: cross-shard VTXs injected but never committed — high values mean VTX blocks are not filling up fast enough |
| Avg Transactions per Block | 94.85 | `Transactions in Blocks ÷ Total Blocks Created` — computed on real transactions only |
| Total Test Elapsed (s) | 144 | Wall-clock seconds from test start until the pool drained to 0 (or stalled) — includes JMeter run + drain wait |
| Blockchain TX Rate (tx/s) | 92.87 | `Real Transactions in Blocks ÷ Total Test Elapsed` |
| Drain Rate (%) | 58.50 | `Real Transactions in Blocks ÷ Transactions Fired × 100` |
| Effective TX Rate (tx/s) | 54.33 | `Blockchain TX Rate × Drain Fraction` = `TX²  ÷ (Fired × Elapsed)` — penalises leaving txs unconfirmed |

### PBFT-RapidChain (Committee-Based)

| Metric | Value | What it means |
|--------|-------|---------------|
| Total Samples | 19195 | Total HTTP requests JMeter sent and received a response for (all endpoints combined: `/transaction`, `/stats`, etc.) |
| Average Response Time (ms) | 266 | Mean round-trip time for a single HTTP request from JMeter to the node and back |
| Success Rate (%) | 98.27 | Percentage of HTTP responses that returned a 2xx status |
| Throughput (req/s) | 191.95 | HTTP requests per second handled by the node API layer (JMeter perspective, all endpoints) |
| Transactions Fired by Test | 19195 | Number of those samples that were `POST /transaction` — the actual blockchain workload submitted |
| Total Blocks Created | 99 | Blocks committed across all shards |
| Transactions in Blocks | 9900 | Unique transactions confirmed on-chain across all shards |
| Unassigned Transactions | 9219 | Transactions still in shard memory pools at the end — **never confirmed** |
| Avg Transactions per Block | 100.00 | `Transactions in Blocks ÷ Total Blocks Created` |
| Total Test Elapsed (s) | 175 | Wall-clock seconds from test start until drain stalled |
| Blockchain TX Rate (tx/s) | 56.57 | `Transactions in Blocks ÷ Total Test Elapsed` — raw number can be **misleading** (see below) |
| Drain Rate (%) | 51.57 | `Transactions in Blocks ÷ Transactions Fired × 100` — how much of what was submitted actually got confirmed |
| Effective TX Rate (tx/s) | 29.17 | `TX² ÷ (Fired × Elapsed)` — corrects for input volume differences between the two runs |

---

## Why Blockchain TX Rate Alone is Misleading

The two implementations may have a backlog of unassigned transactions still being processed while test period is complete.

The fair comparison is **Effective TX Rate**, which multiplies the raw rate by the drain fraction:

```
Effective TX Rate = TX_IN_BLOCKS² / (TRANSACTIONS_FIRED × TOTAL_ELAPSED)
```

| | Fired | Confirmed | Drain % | Raw TX Rate | Effective TX Rate |
|---|---|---|---|---|---|
| **PBFT-Enhanced** | 22861 | 13374 | **~58.50%** | 92.87 tx/s | **~54.33 tx/s** |
| **PBFT-RapidChain** | 19195 | 9900 | **~51.57%** | 56.57 tx/s | **~29.17 tx/s** |

See the Detailed Comparison and Effective TX Rate rows above for the run-specific verdict.

---

## Detailed Comparison

| Metric | PBFT-Enhanced | PBFT-RapidChain | Winner |
|--------|---------------|-----------------|--------|
| Throughput (req/s) ¹ | 228.61 | 191.95 | **Enhanced** 🏆 |
| Avg Response Time (ms) ² | 157 | 266 | **Enhanced** 🏆 |
| Success Rate (%) ³ | 100.00 | 98.27 | **Enhanced** 🏆 |
| Blocks Created | 141 | 99 | **Enhanced** 🏆 |
| Transactions in Blocks ⁴ | 13374 | 9900 | **Enhanced** 🏆 |
| Avg TX per Block | 94.85 | 100.00 | **RapidChain** 🏆 |
| Blockchain TX Rate (tx/s) ⁵ | 92.87 | 56.57 | _(see Effective TX Rate)_ |
| Drain Rate (%) ⁶ | 58.50 | 51.57 | **Enhanced** 🏆 |
| Effective TX Rate (tx/s) ⁷ | 54.33 | 29.17 | **Enhanced** 🏆 |
| Total Test Elapsed (s) ⁸ | 144 | 175 | _(lower = faster drain)_ |

**Footnotes:**

¹ **Throughput (req/s):** HTTP-layer requests/s seen by JMeter. Reflects HTTP concurrency driven by response latency — not a direct measure of blockchain efficiency.

² **Avg Response Time (ms):** Time for the node to acknowledge a transaction over HTTP. Enhanced performs upfront PBFT validation before responding; RapidChain queues immediately and responds.

³ **Success Rate (%):** HTTP 2xx responses. Any value below 100% indicates dropped requests under high load (pool-full or node errors).

⁴ **Transactions in Blocks:** Confirmed on-chain transactions. An implementation that receives more total input will naturally confirm more in absolute terms; use Drain Rate for a normalised comparison.

⁵ **Blockchain TX Rate (tx/s):** `Confirmed ÷ Elapsed`. Biased in favour of whichever implementation received more raw input. Do not use as the sole winner criterion.

⁶ **Drain Rate (%):** `Confirmed ÷ Fired × 100`. The most direct measure of whether the consensus mechanism actually processes everything it accepts.

⁷ **Effective TX Rate (tx/s):** `Blockchain TX Rate × Drain Fraction`. Corrects for input volume differences. This is the fairest single-number comparison between the two systems.

⁸ **Total Test Elapsed (s):** Wall-clock seconds from start until the unassigned pool reached 0 or stalled. Includes the 100 s JMeter run plus however long the drain wait took.

---

## Analysis

### PBFT-Enhanced

**Strengths:**
- 100.00% HTTP success rate
- 58.50% drain rate (share of submitted transactions confirmed on-chain)
- Single-layer consensus (no committee stage) with lower operational complexity
- Cross-shard verification: each healthy shard re-validates the next healthy shard's committed blocks (cyclic ring assignment); 0 verification TXs committed this run

**Characteristics:**
- Sharded PBFT (4 nodes/shard); within each shard all nodes participate in consensus (O(n²) message complexity per shard)
- `TRANSACTION_THRESHOLD` controls block batching; no second consensus layer
- Scales well when `NUMBER_OF_NODES_PER_SHARD` is sized so each shard can tolerate the expected faulty count (f = floor((shard_size-1)/3))

### PBFT-RapidChain

**Strengths:**
- 266 ms average HTTP response time
- 51.57% drain rate (share of submitted transactions confirmed on-chain)
- Architecture designed for horizontal scaling via sharding

**Characteristics:**
- Two-level consensus: each shard runs PBFT internally, then a committee shard validates batches of shard blocks (`BLOCK_THRESHOLD`)
- The committee layer creates a second pipeline stage; if too few shard blocks accumulate, the committee does not trigger and txs stall
- `getTotal()` counts all pending client transactions (unassigned + inflight blocks not yet committed), so the drain rate correctly penalises TXs stuck in dead-shard inflight blocks
- Non-proposer redistribution workaround (re-broadcasts txs every 10 s) causes O(n²) bandwidth growth and timing races on proposer rotation
- Best for larger networks (>16 nodes) that need cross-shard coordination

---

## Recommendation

**🏆 Winner: PBFT-Enhanced**

For 128 nodes, PBFT-Enhanced performs better overall:
- **100.00% acceptance rate** vs RapidChain's 98.27%
- **58.50% drain rate**
- Higher Effective TX Rate (54.33 vs 29.17 tx/s) after correcting for input volume
- Simpler architecture with no committee-layer pipeline stalls

**When RapidChain becomes the right choice:**
- Networks exceeding 32+ nodes where O(n²) PBFT message complexity becomes a bottleneck
- Multi-shard deployments where cross-shard coordination is required
- After fixing: (i) `getTotal()` to include committee pool, (ii) the drain detection logic, and (iii) the committee threshold to fire on partial batches

---

## Full Reports

- **PBFT-Enhanced Summary:** `pbft-enhanced/performance-results/pbft-enhanced-20260414_022828-summary.txt`
- **PBFT-RapidChain Summary:** `pbft-rapidchain/performance-results/pbft-rapidchain-20260414_024244-summary.txt`
