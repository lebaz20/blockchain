/**
 * Timeout constants for consensus protocol operations
 * All values in milliseconds
 *
 * Enhanced-specific tuning rationale:
 *   - BLOCK_CREATION_TIMEOUT_MS: 5000 (was 10000)
 *       Halved to 5 s. The old 10 s value caused flooding when the timer was
 *       reset on every incoming transaction — the current implementation uses
 *       an idempotent "once-running, never-reset" pattern with per-epoch
 *       view-change vote deduplication, so halving the interval is safe.
 *       Benefit: an unknown-faulty proposer (not yet tagged isFaulty on socket)
 *       is voted out in 5 s instead of 10 s per rotation.
 *   - TRANSACTION_INACTIVITY_THRESHOLD_MS: 2000 (was 3000, was 8000)
 *       Forces sub-threshold block creation sooner when inbound transaction flow
 *       drops (e.g., after JMeter stops), reducing idle drain time per shard.
 *       Lowered from 3 s to 2 s to squeeze extra drain blocks in the test tail.
 *   - RATE_BROADCAST_INTERVAL_MS: 2000 (was 3000, was 8000, was 15000)
 *       Core monitors shards. Faster health polling (every 2 s) means
 *       a dead shard (≥2 faulty nodes) is detected by the core sooner, cutting
 *       the first leg of the redirect rescue pipeline from up to 3 s to 2 s.
 *
 * Rescue pipeline latency (worst-case):
 *   Old: BLOCK_CREATION_TIMEOUT_MS(10) + RATE_BROADCAST_INTERVAL_MS(15)
 *        + DRAIN_INTERVAL_MS(30) = 55 s
 *   Previous: 5 + 8 + 10 = 23 s
 *   New: 2 + 2 + 0.5 = ~4.5 s  ← DRAIN_INTERVAL_MS is set in appP2p.js
 */
module.exports = {
  BLOCK_CREATION_TIMEOUT_MS: 5000,
  TRANSACTION_INACTIVITY_THRESHOLD_MS: 2000,
  TRANSACTION_REASSIGNMENT_TIMEOUT_MS: 15000,
  RATE_BROADCAST_INTERVAL_MS: 2000,
  PEER_RECONNECT_DELAY_MS: 5000,
  HEALTH_CHECK_RETRY_MS: 1000
}
