// Import transaction class used for verification
const Transaction = require('../transaction')
const RateUtility = require('../../utils/rate')
const logger = require('../../utils/logger')

// Transaction threshold is the limit or the holding capacity of the nodes
// Once this exceeds a new block is generated
const config = require('../../config')
const TIMEOUTS = require('../../constants/timeouts')
const { TRANSACTION_THRESHOLD } = config.get()

const TRANSACTION_REASSIGNMENT_TIMEOUT_MS = TIMEOUTS.TRANSACTION_REASSIGNMENT_TIMEOUT_MS

class TransactionPool {
  constructor() {
    this.transactions = { unassigned: [] }
    this.transactionIds = new Set() // O(1) existence index across all buckets
    this.transactionsCreatedAt = {}
    this.reassignmentTimers = {}
    // Track the rate of incoming transactions
    this.ratePerMin = {}
  }

  // pushes transactions in the list
  addTransaction(transaction) {
    if (!transaction || !transaction.id) {
      throw new Error('Invalid transaction: transaction and transaction.id are required')
    }
    this.transactions.unassigned.push(transaction)
    this.transactionIds.add(transaction.id)

    RateUtility.updateRatePerMin(this.ratePerMin, transaction.createdAt)
  }

  // assign block transactions to the block via block hash
  // Release assignment after x time in case block creation doesn't succeed
  assignTransactions(block) {
    if (!block || !block.hash || !Array.isArray(block.data)) {
      throw new Error('Invalid block: block with hash and data array is required')
    }
    const assignedTransactions = block.data
    const removeIds = new Set(assignedTransactions.map((item) => item.id))
    this.transactions.unassigned = this.transactions.unassigned.filter(
      (item) => !removeIds.has(item.id)
    )
    // NOTE: transactionIds Set keeps these IDs — transactions are still in the pool
    // (just moved to a hash bucket); they'll be deleted from Set in clear() on commit.

    const hash = block.hash
    this.transactions[hash] = assignedTransactions
    this.transactionsCreatedAt[hash] = Date.now()

    // Add up to 20% random jitter so stalled blocks don't all reassign simultaneously
    const jitter = Math.floor(Math.random() * TRANSACTION_REASSIGNMENT_TIMEOUT_MS * 0.2)
    this.reassignmentTimers[hash] = setTimeout(() => {
      delete this.reassignmentTimers[hash]
      // remove the block hash after 2 minutes
      if (this.transactions[hash] && this.transactions[hash].length > 0) {
        this.transactions.unassigned = [...this.transactions.unassigned, ...this.transactions[hash]]
        delete this.transactions[hash]
        delete this.transactionsCreatedAt[hash]
        // Remove duplicates from unassigned pool — O(n) via Set
        const _seenIds = new Set()
        this.transactions.unassigned = this.transactions.unassigned.filter(
          (item) => _seenIds.size < _seenIds.add(item.id).size
        )
      }
    }, TRANSACTION_REASSIGNMENT_TIMEOUT_MS + jitter)
  }

  // get inflight blocks
  getInflightBlocks(block = undefined) {
    // unassigned is the only key we have in case no inbound transactions
    let inflightBlocks = Object.keys(this.transactions)
    if (block?.hash) {
      inflightBlocks = inflightBlocks.filter((hash) => hash !== block.hash)
    }
    return inflightBlocks
  }

  // returns true if transaction pool is full
  // else returns false
  poolFull() {
    return this.transactions.unassigned.length >= TRANSACTION_THRESHOLD
  }

  // wrapper function to verify transactions
  verifyTransaction(transaction) {
    return Transaction.verifyTransaction(transaction)
  }

  // checks if transactions exists or not — O(1) via Set index
  transactionExists(transaction) {
    return this.transactionIds.has(transaction.id)
  }

  // checks if transactions block hash exists or not
  hashExists(hash) {
    return this.transactions[hash] && this.transactions[hash].length > 0
  }

  // check if other hashes have the same transactions, then move them to the unassigned pool
  // check if the unassigned pool has the same transactions, then remove them
  removeDuplicates(blockHash, transactions) {
    Object.keys(this.transactions).forEach((hash) => {
      if (blockHash === hash || 'unassigned' === hash) {
        return // skip the current block hash and unassigned pool
      }
      const existingTransactions = this.transactions[hash] || []
      const existingIds = new Set(existingTransactions.map((item) => item.id))
      const hasDuplicate = transactions.some((item) => existingIds.has(item.id))
      if (hasDuplicate) {
        this.transactions.unassigned = [...this.transactions.unassigned, ...existingTransactions]
        delete this.transactions[hash]
        delete this.transactionsCreatedAt[hash]
      }
    })
    // Deduplicate unassigned and remove committed transactions in a single O(n+m) pass.
    // Previously two separate passes: findIndex (O(n²)) + some (O(n×m)).
    const committedIds = new Set(transactions.map((t) => t.id))
    const seenIds = new Set()
    this.transactions.unassigned = this.transactions.unassigned.filter((item) => {
      if (committedIds.has(item.id) || seenIds.has(item.id)) return false
      seenIds.add(item.id)
      return true
    })
    // Remove committed IDs from the existence index
    committedIds.forEach((id) => this.transactionIds.delete(id))
  }

  // empties the pool
  clear(hash, data) {
    // Fast exit: _handleCommit clears the pool immediately on commit, so when
    // _handleRoundChange calls clear() ~100 ms later the bucket is already gone
    // and all committed IDs have been removed from transactionIds.  Avoid the
    // O(n) Set build + O(m) filter + O(n) forEach that would otherwise run
    // redundantly.  data[0].id check is O(1) and representative because the
    // whole batch was committed atomically.
    if (
      !(hash in this.transactions) &&
      (data.length === 0 || !this.transactionIds.has(data[0].id))
    ) {
      return
    }

    logger.log(`TRANSACTION POOL CLEARED FOR BLOCK #${hash}`)

    // Cancel the safety-reassignment timer — block committed successfully
    if (this.reassignmentTimers[hash]) {
      clearTimeout(this.reassignmentTimers[hash])
      delete this.reassignmentTimers[hash]
    }

    if (hash in this.transactions) {
      delete this.transactions[hash]
      delete this.transactionsCreatedAt[hash]
    }
    const removeIds = new Set(data.map((item) => item.id))
    this.transactions.unassigned = this.transactions.unassigned.filter(
      (item) => !removeIds.has(item.id)
    )
    // Remove committed IDs from the existence index
    removeIds.forEach((id) => this.transactionIds.delete(id))
  }

  // Immediately return all assigned-but-uncommitted TX back to unassigned.
  // Called on view-change quorum so the new proposer can act right away instead
  // of waiting up to 30 s for the safety-reassignment timers to fire.
  releaseAssigned() {
    Object.keys(this.transactions).forEach((hash) => {
      if (hash === 'unassigned') return
      if (this.reassignmentTimers[hash]) {
        clearTimeout(this.reassignmentTimers[hash])
        delete this.reassignmentTimers[hash]
      }
      this.transactions.unassigned = [...this.transactions.unassigned, ...this.transactions[hash]]
      delete this.transactions[hash]
      delete this.transactionsCreatedAt[hash]
    })
    // Deduplicate — a TX might exist in both unassigned and a hash bucket
    const seen = new Set()
    this.transactions.unassigned = this.transactions.unassigned.filter(
      (item) => seen.size < seen.add(item.id).size
    )
  }
}

module.exports = TransactionPool
