---
applyTo:
  - "**/*.js"
  - "**/*.md"
description: Instructions for PBFT blockchain implementation with RapidChain and IDA gossip
---

# Blockchain PBFT Instructions

You are working on a Byzantine Fault Tolerant (BFT) blockchain implementation using Practical Byzantine Fault Tolerance (PBFT) consensus protocol with RapidChain sharding and Information Dispersal Algorithm (IDA) gossip.

## Project Structure

This workspace contains multiple PBFT implementations:

- `pbft-rapidchain/` - PBFT with RapidChain sharding and committee-based validation
- `pbft-enhanced/` - Enhanced PBFT with IDA gossip optimization
- `pbft-hotstuff/` - PBFT with HotStuff improvements
- `pbft/` - Basic PBFT implementation

## Key Concepts

### PBFT Consensus

- **Phases**: Pre-prepare → Prepare → Commit → Round Change
- **Safety**: Requires 2f+1 nodes to agree (where f is max faulty nodes)
- **Byzantine Threshold**: `Math.floor(2 * N / 3) + 1` approvals needed
- **Transaction Batching**: Configurable threshold (default: 100 transactions)
- **Block Creation**: Proposer-based with timeout mechanism

### RapidChain Sharding

- **Sharding**: Network divided into committees/shards
- **Committee Validation**: Each shard validates its own transactions
- **Cross-Shard Communication**: Core node coordinates between shards
- **IDA Gossip**: Efficient message distribution using erasure coding chunks

### Network Architecture

- **P2P Server**: WebSocket-based peer-to-peer communication
- **Core Server**: Central coordinator for cross-shard communication (rapidchain)
- **HTTP Server**: REST API for transaction submission
- **Kubernetes**: Orchestrated deployment with Docker containers

## Code Style Guidelines

### Logging

- Use `logger` utility instead of `console.log`
- Include port number in all log messages: `logger.log(P2P_PORT, "message")`
- Use appropriate log levels: `log()`, `error()`, `warn()`, `debug()`

### Constants

- Extract magic numbers to `constants/timeouts.js`
- Use descriptive constant names: `BLOCK_CREATION_TIMEOUT_MS`, `TRANSACTION_INACTIVITY_THRESHOLD_MS`
- Document timeout purposes in comments

### Validation

- Separate validation from business logic
- Use `MessageValidator` utility for message validation
- Check Byzantine fault conditions before processing

### Error Handling

- Always validate input parameters
- Check for null/undefined before accessing properties
- Handle WebSocket connection errors with retry logic
- Use try-catch for async operations

### Method Design

- Keep methods under 50 lines
- Use early returns for guard clauses
- Extract complex logic into private helper methods (prefix with `_`)
- Add JSDoc comments to public methods

## Common Patterns

### Transaction Flow

1. Transaction submitted via HTTP endpoint
2. Transaction validated and added to pool
3. Broadcast transaction to peers via IDA gossip
4. Wait for threshold or timeout
5. Proposer creates block with transaction batch
6. PBFT consensus phases (pre-prepare, prepare, commit)
7. Block added to chain after 2f+1 commits

### Block Creation

```javascript
// Check threshold first
const thresholdReached = this.transactionPool.poolFull(isCommittee);
if (!thresholdReached) {
  this._scheduleTimeoutBlockCreation(isCommittee);
  return;
}

// Verify node is proposer
const proposerObject = this.blockchain.getProposer(undefined, isCommittee);
if (proposerObject.proposer !== this.wallet.getPublicKey()) {
  return;
}

// Create and broadcast block
const block = this.blockchain.createBlock(
  transactions,
  this.wallet,
  previousBlock
);
this.broadcastPrePrepare(port, block, blocksCount, previousBlock, isCommittee);
```

### IDA Gossip Pattern

- Chunk messages into K chunks
- Send different chunks to different peers
- Receiver reconstructs from any K chunks
- Reduces network overhead significantly

## Testing Considerations

- Test with 4 nodes (standard BFT: tolerates 1 faulty)
- Verify threshold behavior (e.g., 100 transactions or 8s timeout)
- Test faulty node simulation (IS_FAULTY flag)
- Validate cross-shard communication
- Check Byzantine threshold calculations

## Environment Variables

Key configuration:

- `TRANSACTION_THRESHOLD` - Transactions per block (default: 100)
- `BLOCK_THRESHOLD` - Blocks per committee transaction (default: 10)
- `NUMBER_OF_NODES_PER_SHARD` - Nodes in each shard (default: 4)
- `IS_FAULTY` - Simulate Byzantine faulty node (default: false)
- `MIN_APPROVALS` - Calculated: `Math.floor(2 * N / 3) + 1`

## Known Issues

- Original code had transaction threshold bypass bug (fixed in some versions)
- Peer assignment used incorrect `in` operator (fixed in some versions)
- BFT threshold calculation may vary between implementations

## Deployment

- Use `prepare-config.js` to generate Kubernetes configurations
- Docker images: `lebaz20/blockchain-p2p-server:latest`
- Deploy with: `kubectl apply -f kubeConfig.yml`
- Monitor with: `kubectl logs <pod-name>`

## When Making Changes

1. Maintain Byzantine fault tolerance properties
2. Preserve consensus safety guarantees
3. Test with multiple nodes
4. Update both rapidchain and enhanced versions if applicable
5. Document breaking changes in commit messages
6. Consider impact on network synchronization
