# Blockchain Performance Comparison

**Test Date:** 2026-04-14 02:05:24

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
| Total Samples | 24917 | Total HTTP requests JMeter sent and received a response for (all endpoints combined: `/transaction`, `/stats`, etc.) |
| Average Response Time (ms) | 78 | Mean round-trip time for a single HTTP request from JMeter to the node and back |
| Success Rate (%) | 100.00 | Percentage of HTTP responses that returned a 2xx status |
| Throughput (req/s) | 249.17 | HTTP requests per second handled by the node API layer (JMeter perspective, all endpoints) |
| Transactions Fired by Test | 24917 | Number of those samples that were `POST /transaction` — the actual blockchain workload submitted |
| Total Blocks Created | 130 | Blocks appended to the blockchain during the entire test + drain window |
| Transactions in Blocks | 12439 | Normal client transactions confirmed on-chain; counted per-tx so verification TXs mixed into the same block are still excluded |
| Cross-Shard Verification TX | 0 | Transactions from other healthy shards re-validated and committed by this shard's PBFT — excluded from Transactions in Blocks, Drain Rate, and Effective TX Rate |
| Unassigned Transactions | 0 | Transactions still waiting in the memory pool when the drain timeout expired — **never confirmed** (normal + verification combined) |
| Verification Unassigned TX | 0 | Of the unassigned above: cross-shard VTXs injected but never committed — high values mean VTX blocks are not filling up fast enough |
| Avg Transactions per Block | 95.68 | `Transactions in Blocks ÷ Total Blocks Created` — computed on real transactions only |
| Total Test Elapsed (s) | 145 | Wall-clock seconds from test start until the pool drained to 0 (or stalled) — includes JMeter run + drain wait |
| Blockchain TX Rate (tx/s) | 85.78 | `Real Transactions in Blocks ÷ Total Test Elapsed` |
| Drain Rate (%) | 49.92 | `Real Transactions in Blocks ÷ Transactions Fired × 100` |
| Effective TX Rate (tx/s) | 42.82 | `Blockchain TX Rate × Drain Fraction` = `TX²  ÷ (Fired × Elapsed)` — penalises leaving txs unconfirmed |

### PBFT-RapidChain (Committee-Based)

| Metric | Value | What it means |
|--------|-------|---------------|
| Total Samples | 25548 | Total HTTP requests JMeter sent and received a response for (all endpoints combined: `/transaction`, `/stats`, etc.) |
| Average Response Time (ms) | 58 | Mean round-trip time for a single HTTP request from JMeter to the node and back |
| Success Rate (%) | 100.00 | Percentage of HTTP responses that returned a 2xx status |
| Throughput (req/s) | 255.48 | HTTP requests per second handled by the node API layer (JMeter perspective, all endpoints) |
| Transactions Fired by Test | 25548 | Number of those samples that were `POST /transaction` — the actual blockchain workload submitted |
| Total Blocks Created | 205 | Blocks committed across all shards |
| Transactions in Blocks | 19398 | Unique transactions confirmed on-chain across all shards |
| Unassigned Transactions | 30566 | Transactions still in shard memory pools at the end — **never confirmed** |
| Avg Transactions per Block | 94.62 | `Transactions in Blocks ÷ Total Blocks Created` |
| Total Test Elapsed (s) | 173 | Wall-clock seconds from test start until drain stalled |
| Blockchain TX Rate (tx/s) | 112.12 | `Transactions in Blocks ÷ Total Test Elapsed` — raw number can be **misleading** (see below) |
| Drain Rate (%) | 75.92 | `Transactions in Blocks ÷ Transactions Fired × 100` — how much of what was submitted actually got confirmed |
| Effective TX Rate (tx/s) | 85.13 | `TX² ÷ (Fired × Elapsed)` — corrects for input volume differences between the two runs |

---

## Why Blockchain TX Rate Alone is Misleading

The two implementations may have a backlog of unassigned transactions still being processed while test period is complete.

The fair comparison is **Effective TX Rate**, which multiplies the raw rate by the drain fraction:

```
Effective TX Rate = TX_IN_BLOCKS² / (TRANSACTIONS_FIRED × TOTAL_ELAPSED)
```

| | Fired | Confirmed | Drain % | Raw TX Rate | Effective TX Rate |
|---|---|---|---|---|---|
| **PBFT-Enhanced** | 24917 | 12439 | **~49.92%** | 85.78 tx/s | **~42.82 tx/s** |
| **PBFT-RapidChain** | 25548 | 19398 | **~75.92%** | 112.12 tx/s | **~85.13 tx/s** |

See the Detailed Comparison and Effective TX Rate rows above for the run-specific verdict.

---

## Detailed Comparison

| Metric | PBFT-Enhanced | PBFT-RapidChain | Winner |
|--------|---------------|-----------------|--------|
| Throughput (req/s) ¹ | 249.17 | 255.48 | **RapidChain** 🏆 |
| Avg Response Time (ms) ² | 78 | 58 | **RapidChain** 🏆 |
| Success Rate (%) ³ | 100.00 | 100.00 | **RapidChain** 🏆 |
| Blocks Created | 130 | 205 | **RapidChain** 🏆 |
| Transactions in Blocks ⁴ | 12439 | 19398 | **RapidChain** 🏆 |
| Avg TX per Block | 95.68 | 94.62 | **Enhanced** 🏆 |
| Blockchain TX Rate (tx/s) ⁵ | 85.78 | 112.12 | _(see Effective TX Rate)_ |
| Drain Rate (%) ⁶ | 49.92 | 75.92 | **RapidChain** 🏆 |
| Effective TX Rate (tx/s) ⁷ | 42.82 | 85.13 | **RapidChain** 🏆 |
| Total Test Elapsed (s) ⁸ | 145 | 173 | _(lower = faster drain)_ |

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
- 49.92% drain rate (share of submitted transactions confirmed on-chain)
- Single-layer consensus (no committee stage) with lower operational complexity
- Cross-shard verification: each healthy shard re-validates the next healthy shard's committed blocks (cyclic ring assignment); 0 verification TXs committed this run

**Characteristics:**
- Sharded PBFT (4 nodes/shard); within each shard all nodes participate in consensus (O(n²) message complexity per shard)
- `TRANSACTION_THRESHOLD` controls block batching; no second consensus layer
- Scales well when `NUMBER_OF_NODES_PER_SHARD` is sized so each shard can tolerate the expected faulty count (f = floor((shard_size-1)/3))

### PBFT-RapidChain

**Strengths:**
- 58 ms average HTTP response time
- 75.92% drain rate (share of submitted transactions confirmed on-chain)
- Architecture designed for horizontal scaling via sharding

**Characteristics:**
- Two-level consensus: each shard runs PBFT internally, then a committee shard validates batches of shard blocks (`BLOCK_THRESHOLD`)
- The committee layer creates a second pipeline stage; if too few shard blocks accumulate, the committee does not trigger and txs stall
- `getTotal()` counts all pending client transactions (unassigned + inflight blocks not yet committed), so the drain rate correctly penalises TXs stuck in dead-shard inflight blocks
- Non-proposer redistribution workaround (re-broadcasts txs every 10 s) causes O(n²) bandwidth growth and timing races on proposer rotation
- Best for larger networks (>16 nodes) that need cross-shard coordination

---

## Recommendation

**🏆 Winner: PBFT-RapidChain**

For 128 nodes, PBFT-RapidChain performs better overall:
- Higher Effective TX Rate (85.13 vs 42.82 tx/s) after correcting for input volume
- 58 ms vs 78 ms average response time
- Architecture ready for horizontal scaling beyond this node count

**When RapidChain becomes the right choice:**
- Networks exceeding 32+ nodes where O(n²) PBFT message complexity becomes a bottleneck
- Multi-shard deployments where cross-shard coordination is required
- After fixing: (i) `getTotal()` to include committee pool, (ii) the drain detection logic, and (iii) the committee threshold to fire on partial batches

---

## Full Reports

- **PBFT-Enhanced Summary:** `pbft-enhanced/performance-results/pbft-enhanced-20260414_014908-summary.txt`
- **PBFT-RapidChain Summary:** `pbft-rapidchain/performance-results/pbft-rapidchain-20260414_020228-summary.txt`
