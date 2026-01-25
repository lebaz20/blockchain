/**
 * Timeout constants for consensus protocol operations
 * All values in milliseconds
 */
module.exports = {
  // Block creation timeout after transaction inactivity
  BLOCK_CREATION_TIMEOUT_MS: 10_000, // 10 seconds

  // Minimum inactivity period before forcing block creation
  TRANSACTION_INACTIVITY_THRESHOLD_MS: 8_000, // 8 seconds

  // Transaction reassignment timeout if block creation fails
  TRANSACTION_REASSIGNMENT_TIMEOUT_MS: 120_000, // 2 minutes

  // Rate statistics broadcast interval
  RATE_BROADCAST_INTERVAL_MS: 60_000, // 1 minute

  // Peer reconnection delay on failure
  PEER_RECONNECT_DELAY_MS: 5_000, // 5 seconds

  // WebSocket health check retry interval
  HEALTH_CHECK_RETRY_MS: 1_000 // 1 second
}
