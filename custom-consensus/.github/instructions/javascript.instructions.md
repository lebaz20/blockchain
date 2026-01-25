---
applyTo: "**/*.js"
description: JavaScript and Node.js development standards for distributed blockchain systems
---

# JavaScript Development Instructions

Modern JavaScript development with Node.js for distributed systems, consensus protocols, and P2P networks.

## 🧠 Context

- **Project Type**: Distributed Blockchain System / P2P Network / WebSocket Server
- **Language**: JavaScript (ES6+)
- **Framework / Libraries**: Node.js / Express / WebSocket (ws) / Axios
- **Architecture**: Modular / P2P Network / PBFT Consensus

## 🔧 General Guidelines

### Language Standards

- Use JavaScript-idiomatic patterns and ES6+ features
- Prefer `const` over `let`, avoid `var`
- Use async/await instead of promise chains or callbacks
- Template literals for string interpolation
- Always prefer named functions and avoid long anonymous closures
- Add JSDoc comments and inline type hints where helpful
- Prefer readability over cleverness

### Code Quality

- Use consistent formatting (consider Prettier)
- Each function should have **one clear purpose**
- Code must be **simple, direct, and expressive**
- Always prioritize **readability and maintainability** over brevity
- Avoid duplication and ensure all code passes tests

## 📁 File Structure

Project follows this modular structure:

```text
pbft-[variant]/
  services/          # Core blockchain services
    blockchain.js
    p2pserver.js
    coreserver.js
    transaction.js
    validators.js
    wallet.js
    pools/          # Message and block pools
  utils/            # Utility modules
    logger.js
    chain.js
    cpu.js
  constants/        # Configuration constants
    message.js
    timeouts.js
  config.js         # Environment configuration
  app*.js           # Application entry points
```

## 🎯 Naming Conventions

### General Rules

- Use **intention-revealing, descriptive names**
- Avoid abbreviations and misleading terms
- Maintain **consistent naming conventions** across files
- Names should clearly indicate purpose and type

### Specific Patterns

- **Classes**: PascalCase (`P2pserver`, `TransactionPool`, `BlockPool`)
- **Functions/Methods**: camelCase starting with verb (`initiateBlockCreation`, `broadcastTransaction`, `validateBlock`)
- **Constants**: UPPER_SNAKE_CASE (`MIN_APPROVALS`, `TRANSACTION_THRESHOLD`, `P2P_PORT`)
- **Private methods**: Prefix with underscore (`_scheduleTimeout`, `_proposeBlock`, `_handleMessage`)
- **Variables**: camelCase, descriptive (`transactionPool`, `committeeBlocks`, `inflightBlocks`)
- **Booleans**: Prefix with `is`, `has`, `should` (`isCommittee`, `hasFaultyNode`, `shouldRedirect`)

## ⚡ Functions

### Function Design

- Functions must be **small** (ideally < 50 lines) and **do one thing**
- Use **clear, descriptive names** starting with verbs
- Prefer **≤ 2 parameters** (max 3), use object destructuring for more
- Avoid side effects unless function name indicates it
- Keep a **single level of abstraction** within each function
- Functions must **either perform an action or return data**, never both

### Examples

```javascript
// ✅ Good: Clear purpose, single responsibility
async function validateTransaction(transaction, pool, validators) {
  if (!transaction || !transaction.from) {
    return false;
  }
  return (
    validators.isValidValidator(transaction.from) &&
    !pool.transactionExists(transaction)
  );
}

// ✅ Good: Named function with clear intent
function broadcastPrePrepare(
  port,
  block,
  blocksCount,
  previousBlock,
  isCommittee
) {
  const message = {
    type: MESSAGE_TYPE.pre_prepare,
    port: P2P_PORT,
    data: { block, previousBlock, blocksCount },
  };
  this.idaGossip.sendToShardPeers({ message, isCommittee });
}

// ❌ Bad: Too long, multiple responsibilities
function processBlockCreation() {
  // ... 100+ lines doing validation, creation, and broadcasting
}
```

### Error Handling

- Use **exceptions** instead of error codes
- Don't return or accept `null` — prefer safe defaults or early returns
- Keep **error-handling separate from main logic**
- Always clean up resources (timeouts, connections) after exceptions

```javascript
// ✅ Good: Early validation with guards
async function addBlock(block, subsetIndex) {
  if (!block || !block.hash) {
    logger.error(P2P_PORT, "Invalid block provided");
    return false;
  }

  if (this.existingBlock(block.hash, subsetIndex)) {
    logger.warn(P2P_PORT, "Block already exists", block.hash);
    return false;
  }

  try {
    await this.validateAndAdd(block, subsetIndex);
    return true;
  } catch (error) {
    logger.error(P2P_PORT, "Failed to add block", error);
    return false;
  }
}

// ❌ Bad: Mixing logic with error handling
function addBlock(block, subsetIndex) {
  try {
    if (block) {
      if (!this.existingBlock(block.hash, subsetIndex)) {
        // ... deep nesting
      } else {
        return null; // Bad: returning null
      }
    }
  } catch (e) {
    // Generic error handling mixed with logic
  }
}
```

## 🧩 Patterns

### ✅ Patterns to Follow

#### Dependency Injection

```javascript
class P2pserver {
  constructor(
    blockchain,
    transactionPool,
    wallet,
    blockPool,
    preparePool,
    commitPool,
    messagePool,
    validators,
    idaGossip
  ) {
    this.blockchain = blockchain;
    this.transactionPool = transactionPool;
    // ... inject dependencies
  }
}
```

#### Repository Pattern for Data Access

```javascript
class BlockPool {
  addBlock(block, isCommittee) {
    /* ... */
  }
  existingBlock(block, isCommittee) {
    /* ... */
  }
  getBlocks(isCommittee) {
    /* ... */
  }
}
```

#### Early Returns (Guard Clauses)

```javascript
function initiateBlockCreation(port, triggeredByTransaction, isCommittee) {
  const thresholdReached = this.transactionPool.poolFull(isCommittee);

  // Early returns for invalid states
  if (IS_FAULTY || !thresholdReached) {
    this._scheduleTimeoutBlockCreation(isCommittee);
    return;
  }

  if (!this._isProposer(isCommittee)) {
    return;
  }

  // Main logic at top level
  this._proposeBlock(port, isCommittee);
}
```

#### Constants for Magic Numbers

```javascript
// constants/timeouts.js
module.exports = {
  BLOCK_CREATION_TIMEOUT_MS: 10000,
  TRANSACTION_INACTIVITY_THRESHOLD_MS: 8000,
  RATE_BROADCAST_INTERVAL_MS: 60000,
  PEER_RECONNECT_DELAY_MS: 5000,
};
```

#### Logging with Context

```javascript
const logger = require("../utils/logger");

logger.log(P2P_PORT, "Transaction added", {
  count: pool.length,
  hash: transaction.hash,
});
logger.error(P2P_PORT, "Failed to connect", error);
```

### 🚫 Patterns to Avoid

- ❌ Don't hardcode values; use config/env files or constants
- ❌ Don't generate code without tests
- ❌ Avoid global state (global console override, mutable globals)
- ❌ Don't expose secrets or keys in logs
- ❌ Avoid long anonymous functions or deep callback nesting
- ❌ Don't mix sync and async patterns
- ❌ Avoid large parameter lists (use objects)
- ❌ Don't use magic numbers or strings

## 📝 Comments

### When to Comment

- Use comments **only when code cannot express intent clearly**
- Legal notices, copyright headers
- TODO markers with context and assignee
- Warnings about consequences (performance, security)
- Complex algorithms that need explanation
- Byzantine fault tolerance reasoning

### When NOT to Comment

- Don't restate what code already shows
- Don't keep commented-out code (use git)
- Don't add redundant comments
- Prefer self-explanatory naming over comments

```javascript
// ✅ Good: Explains WHY (Byzantine requirement)
// Byzantine Fault Tolerance: need more than 2/3 of nodes to agree
// Formula: floor(2*N/3) + 1 ensures we have the minimum majority
const MIN_APPROVALS = Math.floor((2 * NUMBER_OF_NODES_PER_SHARD) / 3) + 1;

// ✅ Good: Warning about critical logic
// WARNING: Changing this condition affects transaction batching behavior
// See issue #42 for context on threshold bypass bug
if (!IS_FAULTY && thresholdReached) {
  // ...
}

// ❌ Bad: States the obvious
// Set the port to P2P_PORT
const port = P2P_PORT;

// ❌ Bad: Commented-out code
// const oldApprovals = 2 * (N / 3);  // Don't do this
```

## 🔧 Node.js Best Practices

### Modules

- Use `require()` for CommonJS modules
- One class per file (`module.exports = ClassName`)
- Group related utilities in separate files
- Keep imports at the top, organized by type (built-in, external, local)

### Async Operations

- Always handle promise rejections
- Use async/await for cleaner code
- Don't mix callbacks and promises
- Use try-catch around await calls
- Clear timeouts and intervals when done

```javascript
// ✅ Good: Clean async/await with error handling
async function addUpdatedBlock(
  blockHash,
  blockPool,
  preparePool,
  commitPool,
  isCommittee
) {
  try {
    const block = blockPool.getBlock(blockHash, isCommittee);
    if (!block) {
      logger.error(P2P_PORT, "Block not found", blockHash);
      return false;
    }

    await this.validateConsensus(block, preparePool, commitPool);
    this.addBlock(block, isCommittee);
    return block;
  } catch (error) {
    logger.error(P2P_PORT, "Failed to add block", error);
    return false;
  }
}
```

### Networking (WebSocket/P2P)

- Handle connection errors gracefully with retry logic
- Implement exponential backoff for reconnections
- Close connections properly on shutdown
- Validate all incoming messages before processing
- Use timeouts to prevent hanging connections

```javascript
// ✅ Good: Resilient connection with retry
function connectToPeer(peer) {
  const socket = new WebSocket(peer);

  socket.on("error", (error) => {
    logger.error(P2P_PORT, "Peer connection failed, retrying...", error);
    setTimeout(() => connectToPeer(peer), TIMEOUTS.PEER_RECONNECT_DELAY_MS);
  });

  socket.on("open", () => {
    logger.log(P2P_PORT, "Connected to peer", peer);
    this.registerMessageHandler(socket);
  });
}
```

### Performance

- Avoid synchronous file operations in request handlers
- Use `setImmediate()` for deferring non-critical work
- Clear timeouts/intervals to prevent memory leaks
- Monitor memory usage in long-running processes
- Use object pools for frequently created objects

## 🧪 Testing Guidelines

### Testing Approach

- Use Jest for unit and integration tests
- Follow **FIRST** principles: Fast, Independent, Repeatable, Self-validating, Timely
- Prefer test-driven development (TDD) when modifying core logic
- Tests must be **clean, readable, and reflect real behavior**
- Never skip tests; treat test code with same care as production code

### Test Structure

```javascript
describe("TransactionPool", () => {
  let pool;

  beforeEach(() => {
    pool = new TransactionPool();
  });

  describe("addTransaction", () => {
    it("should add valid transaction to pool", () => {
      const transaction = createValidTransaction();
      pool.addTransaction(transaction);
      expect(pool.getUnassignedCount()).toBe(1);
    });

    it("should reject duplicate transaction", () => {
      const transaction = createValidTransaction();
      pool.addTransaction(transaction);
      pool.addTransaction(transaction);
      expect(pool.getUnassignedCount()).toBe(1);
    });
  });
});
```

### Mocking

- Include mocks/stubs for third-party services (network, file system)
- Mock dependencies for unit tests
- Use real implementations for integration tests
- Test Byzantine scenarios (faulty nodes, malicious messages)

## 🏗️ Architecture Principles

### Separation of Concerns

- **Services**: Business logic (blockchain, consensus, validation)
- **Pools**: Data management (transactions, blocks, messages)
- **Utils**: Pure functions and helpers (logging, crypto)
- **Constants**: Configuration values

### Encapsulation

- Hide implementation details behind clear interfaces
- Expose only necessary public methods
- Keep internal state private
- Use getter methods for read-only access

### Single Responsibility

- Each class should have **one reason to change**
- Split large classes into focused modules
- Separate concerns (network, consensus, storage)

## 📚 Blockchain-Specific Guidelines

### Byzantine Fault Tolerance

- Always validate sender identity
- Check message signatures
- Verify quorum thresholds before committing
- Handle malicious/faulty node scenarios
- Don't trust data from peers without validation

### Consensus Protocol

- Follow PBFT phase order strictly
- Maintain deterministic state transitions
- Log all consensus decisions
- Handle view changes properly
- Respect timeout mechanisms

### Transaction Processing

- Validate all transaction fields
- Check for duplicates before adding
- Batch transactions efficiently
- Clear assigned transactions after block commit
- Handle transaction expiry

## 🔁 Iteration & Review

- Copilot output should be reviewed and modified before committing
- If code isn't following these instructions, regenerate with more context
- Use comments to clarify intent before invoking Copilot
- Refactor continually; leave code cleaner than you found it
- Strive for **clarity, simplicity, and correctness**

## 📚 References

- [JavaScript Style Guide (Airbnb)](https://github.com/airbnb/javascript)
- [Clean Code JavaScript](https://github.com/ryanmcdermott/clean-code-javascript)
- [MDN JavaScript Reference](https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference)
- [Node.js Documentation](https://nodejs.org/en/docs)
- [Node.js Best Practices](https://github.com/goldbergyoni/nodebestpractices)
- [Express Documentation](https://expressjs.com/)
- [WebSocket (ws) Documentation](https://github.com/websockets/ws)
- [Jest Testing Framework](https://jestjs.io/docs/getting-started)
- [Clean Architecture](https://blog.cleancoder.com/uncle-bob/2012/08/13/the-clean-architecture.html)
