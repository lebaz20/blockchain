# Blockchain Performance Comparison

**Test Date:** 2026-04-07 21:05:08

## Test Configuration

| Parameter | Value | Meaning |
|-----------|-------|---------|
| Number of Nodes (Enhanced) | 256 | 256 P2P nodes ran the PBFT-Enhanced consensus; each participates in every round of consensus voting |
| Number of Nodes (RapidChain) | 256 total | Nodes split into shards of 4, plus 1 committee shard for cross-shard finality |
| Faulty Nodes (RapidChain) | 85 | Byzantine-simulated nodes that do not propose or vote in consensus |
| JMeter Threads | 440 | 440 concurrent virtual users — identical for both protocols; high enough that the ConstantThroughputTimer cap (733 req/s) is the actual bottleneck rather than thread count |
| Test Duration | 100 s | JMeter fires transactions for 100 seconds total; active load = 70 s, ramp-down = 30 s |
| Ramp-up Time | 5 s | JMeter linearly scales from 0 to 440 threads over the first 5 seconds to avoid a cold-start spike |
| Ramp-down Time | 30 s | Last 30 s of the test window: no new transactions — blockchain completes in-flight blocks before the drain wait begins |
| Cross-Shard Verification | Cyclic healthy-shard ring | Each healthy shard verifies the next healthy shard in the ring; dead shards are skipped automatically — verification TXs are counted separately and excluded from all performance metrics |

---

## Results Summary

### PBFT-Enhanced

| Metric | Value | What it means |
|--------|-------|---------------|
| Total Samples | 47726 | Total HTTP requests JMeter sent and received a response for (all endpoints combined: `/transaction`, `/stats`, etc.) |
| Average Response Time (ms) | 102 | Mean round-trip time for a single HTTP request from JMeter to the node and back |
| Success Rate (%) | 100.00 | Percentage of HTTP responses that returned a 2xx status |
| Throughput (req/s) | 477.26 | HTTP requests per second handled by the node API layer (JMeter perspective, all endpoints) |
| Transactions Fired by Test | 47726 | Number of those samples that were `POST /transaction` — the actual blockchain workload submitted |
| Total Blocks Created | 170 | Blocks appended to the blockchain during the entire test + drain window |
| Transactions in Blocks | 24856 | Normal client transactions confirmed on-chain; counted per-tx so verification TXs mixed into the same block are still excluded |
| Cross-Shard Verification TX | 0 | Transactions from other healthy shards re-validated and committed by this shard's PBFT — excluded from Transactions in Blocks, Drain Rate, and Effective TX Rate |
| Unassigned Transactions | 9288 | Transactions still waiting in the memory pool when the drain timeout expired — **never confirmed** (normal + verification combined) |
| Verification Unassigned TX | 0 | Of the unassigned above: cross-shard VTXs injected but never committed — high values mean VTX blocks are not filling up fast enough |
| Avg Transactions per Block | 146.21 | `Transactions in Blocks ÷ Total Blocks Created` — computed on real transactions only |
| Total Test Elapsed (s) | 136 | Wall-clock seconds from test start until the pool drained to 0 (or stalled) — includes JMeter run + drain wait |
| Blockchain TX Rate (tx/s) | 182.76 | `Real Transactions in Blocks ÷ Total Test Elapsed` |
| Drain Rate (%) | 52.08 | `Real Transactions in Blocks ÷ Transactions Fired × 100` |
| Effective TX Rate (tx/s) | 95.18 | `Blockchain TX Rate × Drain Fraction` = `TX²  ÷ (Fired × Elapsed)` — penalises leaving txs unconfirmed |

### PBFT-RapidChain (Committee-Based)

| Metric | Value | What it means |
|--------|-------|---------------|
| Total Samples | 40130 | Total HTTP requests JMeter sent and received a response for (all endpoints combined: `/transaction`, `/stats`, etc.) |
| Average Response Time (ms) | 228 | Mean round-trip time for a single HTTP request from JMeter to the node and back |
| Success Rate (%) | 99.20 | Percentage of HTTP responses that returned a 2xx status |
| Throughput (req/s) | 401.30 | HTTP requests per second handled by the node API layer (JMeter perspective, all endpoints) |
| Transactions Fired by Test | 40130 | Number of those samples that were `POST /transaction` — the actual blockchain workload submitted |
| Total Blocks Created | 347 | Blocks committed across all shards |
| Transactions in Blocks | 34700 | Unique transactions confirmed on-chain across all shards |
| Unassigned Transactions | 3879 | Transactions still in shard memory pools at the end — **never confirmed** |
| Avg Transactions per Block | 100.00 | `Transactions in Blocks ÷ Total Blocks Created` |
| Total Test Elapsed (s) | 132 | Wall-clock seconds from test start until drain stalled |
| Blockchain TX Rate (tx/s) | 262.87 | `Transactions in Blocks ÷ Total Test Elapsed` — raw number can be **misleading** (see below) |
| Drain Rate (%) | 86.46 | `Transactions in Blocks ÷ Transactions Fired × 100` — how much of what was submitted actually got confirmed |
| Effective TX Rate (tx/s) | 227.30 | `TX² ÷ (Fired × Elapsed)` — corrects for input volume differences between the two runs |

---

## Why Blockchain TX Rate Alone is Misleading

The two implementations may have a backlog of unassigned transactions still being processed while test period is complete.

The fair comparison is **Effective TX Rate**, which multiplies the raw rate by the drain fraction:

```
Effective TX Rate = TX_IN_BLOCKS² / (TRANSACTIONS_FIRED × TOTAL_ELAPSED)
```

| | Fired | Confirmed | Drain % | Raw TX Rate | Effective TX Rate |
|---|---|---|---|---|---|
| **PBFT-Enhanced** | 47726 | 24856 | **~52.08%** | 182.76 tx/s | **~95.18 tx/s** |
| **PBFT-RapidChain** | 40130 | 34700 | **~86.46%** | 262.87 tx/s | **~227.30 tx/s** |

See the Detailed Comparison and Effective TX Rate rows above for the run-specific verdict.

---

## Detailed Comparison

| Metric | PBFT-Enhanced | PBFT-RapidChain | Winner |
|--------|---------------|-----------------|--------|
| Throughput (req/s) ¹ | 477.26 | 401.30 | **Enhanced** 🏆 |
| Avg Response Time (ms) ² | 102 | 228 | **Enhanced** 🏆 |
| Success Rate (%) ³ | 100.00 | 99.20 | **Enhanced** 🏆 |
| Blocks Created | 170 | 347 | **RapidChain** 🏆 |
| Transactions in Blocks ⁴ | 24856 | 34700 | **RapidChain** 🏆 |
| Avg TX per Block | 146.21 | 100.00 | **Enhanced** 🏆 |
| Blockchain TX Rate (tx/s) ⁵ | 182.76 | 262.87 | _(see Effective TX Rate)_ |
| Drain Rate (%) ⁶ | 52.08 | 86.46 | **RapidChain** 🏆 |
| Effective TX Rate (tx/s) ⁷ | 95.18 | 227.30 | **RapidChain** 🏆 |
| Total Test Elapsed (s) ⁸ | 136 | 132 | _(lower = faster drain)_ |

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
- 52.08% drain rate (share of submitted transactions confirmed on-chain)
- Single-layer consensus (no committee stage) with lower operational complexity
- Cross-shard verification: each healthy shard re-validates the next healthy shard's committed blocks (cyclic ring assignment); 0 verification TXs committed this run

**Characteristics:**
- Sharded PBFT (4 nodes/shard); within each shard all nodes participate in consensus (O(n²) message complexity per shard)
- `TRANSACTION_THRESHOLD` controls block batching; no second consensus layer
- Scales well when `NUMBER_OF_NODES_PER_SHARD` is sized so each shard can tolerate the expected faulty count (f = floor((shard_size-1)/3))

### PBFT-RapidChain

**Strengths:**
- 228 ms average HTTP response time
- 86.46% drain rate (share of submitted transactions confirmed on-chain)
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

For 256 nodes, PBFT-Enhanced performs better overall:
- **100.00% acceptance rate** vs RapidChain's 99.20%
- **52.08% drain rate**
- Higher Effective TX Rate (95.18 vs 227.30 tx/s) after correcting for input volume
- Simpler architecture with no committee-layer pipeline stalls

**When RapidChain becomes the right choice:**
- Networks exceeding 32+ nodes where O(n²) PBFT message complexity becomes a bottleneck
- Multi-shard deployments where cross-shard coordination is required
- After fixing: (i) `getTotal()` to include committee pool, (ii) the drain detection logic, and (iii) the committee threshold to fire on partial batches

---

## Full Reports

- **PBFT-Enhanced Summary:** `pbft-enhanced/performance-results/pbft-enhanced-20260407_205010-summary.txt`
- **PBFT-RapidChain Summary:** `pbft-rapidchain/performance-results/pbft-rapidchain-20260407_205754-summary.txt`
