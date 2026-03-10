// Import transaction class used for verification
const Transaction = require('../transaction')
const RateUtility = require('../../utils/rate')
const logger = require('../../utils/logger')

// Transaction threshold is the limit or the holding capacity of the nodes
// Once this exceeds a new block is generated
const config = require('../../config')
const TIMEOUTS = require('../../constants/timeouts')
const { TRANSACTION_THRESHOLD, BLOCK_THRESHOLD } = config.get()

class TransactionPool {
  constructor() {
    this.transactions = { unassigned: [] }
    this.transactionIds = new Set() // O(1) existence index for shard transactions
    this.transactionsCreatedAt = {}
    this.committeeTransactions = { unassigned: [] }
    this.committeeTransactionIds = new Set() // O(1) existence index for committee transactions
    this.reassignmentTimers = {}
    // Track the rate of incoming transactions
    this.ratePerMin = {}
  }

  // pushes transactions in the list
  addTransaction(transaction, isCommittee = false) {
    if (isCommittee) {
      if (!this.committeeTransactions) {
        this.committeeTransactions = { unassigned: [] }
      }
      this.committeeTransactions.unassigned.push(transaction)
      this.committeeTransactionIds.add(transaction.id)
    } else {
      this.transactions.unassigned.push(transaction)
      this.transactionIds.add(transaction.id)
      RateUtility.updateRatePerMin(this.ratePerMin, transaction.createdAt)
    }
  }

  // assign block transactions to the block via block hash
  // Release assignment after x time in case block creation doesn't succeed
  assignTransactions(block, isCommittee = false) {
    const assignedTransactions = block.data
    if (!isCommittee) {
      const removeIds = new Set(assignedTransactions.map((item) => item.id))
      this.transactions.unassigned = this.transactions.unassigned.filter(
        (item) => !removeIds.has(item.id)
      )

      const hash = block.hash
      this.transactions[hash] = assignedTransactions
      this.transactionsCreatedAt[hash] = Date.now()

      const jitter = Math.floor(Math.random() * TIMEOUTS.TRANSACTION_REASSIGNMENT_TIMEOUT_MS * 0.2)
      this.reassignmentTimers[hash] = setTimeout(() => {
        delete this.reassignmentTimers[hash]
        // remove the block hash after timeout
        if (this.transactions[hash] && this.transactions[hash].length > 0) {
          this.transactions.unassigned = [
            ...this.transactions.unassigned,
            ...this.transactions[hash]
          ]
          delete this.transactions[hash]
          delete this.transactionsCreatedAt[hash]
          // Remove duplicates from unassigned pool — O(n) via Set
          const _seenIds = new Set()
          this.transactions.unassigned = this.transactions.unassigned.filter(
            (item) => _seenIds.size < _seenIds.add(item.id).size
          )
        }
      }, TIMEOUTS.TRANSACTION_REASSIGNMENT_TIMEOUT_MS + jitter) // timeout + jitter
    } else {
      const removeIds = new Set(assignedTransactions.map((item) => item.id))
      this.committeeTransactions.unassigned = this.committeeTransactions.unassigned.filter(
        (item) => !removeIds.has(item.id)
      )

      const hash = block.hash
      this.committeeTransactions[hash] = assignedTransactions
      const committeeJitter = Math.floor(
        Math.random() * TIMEOUTS.TRANSACTION_REASSIGNMENT_TIMEOUT_MS * 0.2
      )
      this.reassignmentTimers[`committee_${hash}`] = setTimeout(() => {
        delete this.reassignmentTimers[`committee_${hash}`]
        // remove the block hash after timeout
        if (this.committeeTransactions[hash] && this.committeeTransactions[hash].length > 0) {
          this.committeeTransactions.unassigned = [
            ...this.committeeTransactions.unassigned,
            ...this.committeeTransactions[hash]
          ]
          delete this.committeeTransactions[hash]
          // Remove duplicates from unassigned pool — O(n) via Set
          const _cSeenIds2 = new Set()
          this.committeeTransactions.unassigned = this.committeeTransactions.unassigned.filter(
            (item) => _cSeenIds2.size < _cSeenIds2.add(item.id).size
          )
        }
      }, TIMEOUTS.TRANSACTION_REASSIGNMENT_TIMEOUT_MS + committeeJitter) // timeout + jitter
    }
  }

  // get inflight blocks
  getInflightBlocks(block = undefined, isCommittee = false) {
    // unassigned is the only key we have in case no inbound transactions
    let inflightBlocks = Object.keys(isCommittee ? this.committeeTransactions : this.transactions)
    if (block?.hash) {
      inflightBlocks = inflightBlocks.filter((hash) => hash !== block.hash)
    }
    return inflightBlocks
  }

  // returns true if transaction pool is full
  // else returns false
  poolFull(isCommittee = false) {
    if (isCommittee) {
      return this.committeeTransactions.unassigned.length >= BLOCK_THRESHOLD
    }
    return this.transactions.unassigned.length >= TRANSACTION_THRESHOLD
  }

  // wrapper function to verify transactions
  verifyTransaction(transaction) {
    return Transaction.verifyTransaction(transaction)
  }

  // checks if transactions exists or not — O(1) via Set index
  transactionExists(transaction, isCommittee = false) {
    return isCommittee
      ? this.committeeTransactionIds.has(transaction.id)
      : this.transactionIds.has(transaction.id)
  }

  // checks if transactions block hash exists or not
  hashExists(hash, isCommittee = false) {
    return (
      (isCommittee ? this.committeeTransactions : this.transactions)[hash] &&
      (isCommittee ? this.committeeTransactions : this.transactions)[hash].length > 0
    )
  }

  // check if other hashes have the same transactions, then move them to the unassigned pool
  // check if the unassigned pool has the same transactions, then remove them
  removeDuplicates(blockHash, transactions, isCommittee = false) {
    if (isCommittee) {
      Object.keys(this.committeeTransactions).forEach((hash) => {
        if (blockHash === hash || 'unassigned' === hash) {
          return // skip the current block hash and unassigned pool
        }
        const existingTransactions = this.committeeTransactions[hash] || []
        const existingIds = new Set(existingTransactions.map((item) => item.id))
        const hasDuplicate = transactions.some((item) => existingIds.has(item.id))
        if (hasDuplicate) {
          this.committeeTransactions.unassigned = [
            ...this.committeeTransactions.unassigned,
            ...existingTransactions
          ]
          delete this.committeeTransactions[hash]
        }
      })
      // Remove duplicates from unassigned pool (O(n) via Set)
      const _cSeenIds = new Set()
      this.committeeTransactions.unassigned = this.committeeTransactions.unassigned.filter(
        (item) => _cSeenIds.size < _cSeenIds.add(item.id).size
      )
      // Filter out transactions that are being committed — O(n+m) via Set
      const _cCommittedIds = new Set(transactions.map((t) => t.id))
      this.committeeTransactions.unassigned = this.committeeTransactions.unassigned.filter(
        (item) => !_cCommittedIds.has(item.id)
      )
      // Remove committed IDs from the existence index
      transactions.forEach((t) => this.committeeTransactionIds.delete(t.id))
    } else {
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
      // Remove duplicates from unassigned pool (O(n) via Set)
      const _seenIds = new Set()
      this.transactions.unassigned = this.transactions.unassigned.filter(
        (item) => _seenIds.size < _seenIds.add(item.id).size
      )
      // Filter out transactions that are being committed — O(n+m) via Set
      const _committedIds = new Set(transactions.map((t) => t.id))
      this.transactions.unassigned = this.transactions.unassigned.filter(
        (item) => !_committedIds.has(item.id)
      )
      // Remove committed IDs from the existence index
      transactions.forEach((t) => this.transactionIds.delete(t.id))
    }
  }

  // empties the pool
  clear(hash, data, isCommittee = false) {
    // Fast exit: _handleCommit clears the pool immediately on commit, so when
    // _handleRoundChange calls clear() ~100 ms later the bucket is already gone
    // and all committed IDs have been purged from the existence index. The two
    // O(1) checks here avoid the O(n) Set build + filter + forEach that would
    // otherwise run redundantly on every committed block.
    const _txStore = isCommittee ? this.committeeTransactions : this.transactions
    const _idIndex = isCommittee ? this.committeeTransactionIds : this.transactionIds
    if (!(hash in _txStore) && (data.length === 0 || !_idIndex.has(data[0].id))) {
      return
    }

    logger.log(`TRANSACTION POOL CLEARED FOR BLOCK #${hash}`)

    // Cancel the safety-reassignment timer — block committed successfully
    const timerKey = isCommittee ? `committee_${hash}` : hash
    if (this.reassignmentTimers[timerKey]) {
      clearTimeout(this.reassignmentTimers[timerKey])
      delete this.reassignmentTimers[timerKey]
    }

    if (isCommittee) {
      if (hash in this.committeeTransactions) {
        delete this.committeeTransactions[hash]
        delete this.committeeTransactionsCreatedAt[hash]
      }
      const removeIds = new Set(data.map((item) => item.id))
      this.committeeTransactions.unassigned = this.committeeTransactions.unassigned.filter(
        (item) => !removeIds.has(item.id)
      )
      removeIds.forEach((id) => this.committeeTransactionIds.delete(id))
    } else {
      if (hash in this.transactions) {
        delete this.transactions[hash]
        delete this.transactionsCreatedAt[hash]
      }
      const removeIds = new Set(data.map((item) => item.id))
      this.transactions.unassigned = this.transactions.unassigned.filter(
        (item) => !removeIds.has(item.id)
      )
      removeIds.forEach((id) => this.transactionIds.delete(id))
    }
  }

  // Immediately return all assigned-but-uncommitted TX back to unassigned.
  // Called on view-change quorum so the new proposer can act right away instead
  // of waiting up to 30 s for the safety-reassignment timers to fire.
  releaseAssigned(isCommittee = false) {
    const pool = isCommittee ? this.committeeTransactions : this.transactions
    const timerPrefix = isCommittee ? 'committee_' : ''
    Object.keys(pool).forEach((hash) => {
      if (hash === 'unassigned') return
      const timerKey = `${timerPrefix}${hash}`
      if (this.reassignmentTimers[timerKey]) {
        clearTimeout(this.reassignmentTimers[timerKey])
        delete this.reassignmentTimers[timerKey]
      }
      pool.unassigned = [...pool.unassigned, ...pool[hash]]
      delete pool[hash]
      if (!isCommittee) delete this.transactionsCreatedAt[hash]
    })
    // Deduplicate — a TX might exist in both unassigned and a hash bucket
    const seen = new Set()
    pool.unassigned = pool.unassigned.filter((item) => seen.size < seen.add(item.id).size)
  }
}

module.exports = TransactionPool
