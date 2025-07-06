// Import transaction class used for verification
const Transaction = require("../transaction");
const RateUtility = require("../../utils/rate");

// Transaction threshold is the limit or the holding capacity of the nodes
// Once this exceeds a new block is generated
const { TRANSACTION_THRESHOLD } = require("../../config");

class TransactionPool {
  constructor() {
    this.transactions = { unassigned: [] };
    this.transactionsCreatedAt = {}
    // Track the rate of incoming transactions
    this.ratePerMin = {};
  }

  // pushes transactions in the list
  addTransaction(transaction) {
    this.transactions.unassigned.push(transaction);

    RateUtility.updateRatePerMin(this.ratePerMin, transaction.createdAt);
  }

  // assign block transactions to the block via block hash
  // Release assignment after x time in case block creation doesn't succeed
  assignTransactions(block) {
    const assignedTransactions = block.data;
    const removeIds = new Set(assignedTransactions.map((item) => item.id));
    this.transactions.unassigned = this.transactions.unassigned.filter(
      (item) => !removeIds.has(item.id),
    );

    const hash = block.hash;
    this.transactions[hash] = assignedTransactions;
    this.transactionsCreatedAt[hash] = new Date.now();

    setTimeout(() => {
      // remove the block hash after 2 minutes
      if (this.transactions[hash] && this.transactions[hash].length > 0) {
        this.transactions.unassigned = [ ...this.transactions.unassigned, ...this.transactions[hash] ];  
        delete this.transactions[hash];
        delete this.transactionsCreatedAt[hash];
        // Remove duplicates from unassigned pool
        this.transactions.unassigned = this.transactions.unassigned.filter(
          (item, index, self) => index === self.findIndex((t) => t.id === item.id)
        );
      }
    }, 2 * 60 * 1000); // 2 minutes
  }

  // get inflight blocks
  getInflightBlocks(block = undefined) {
    // unassigned is the only key we have in case no inbound transactions
    let inflightBlocks = Object.keys(this.transactions);
    if (block?.hash) {
      inflightBlocks = inflightBlocks.filter((hash) => hash !== block.hash);
    }
    return inflightBlocks;
  }

  // returns true if transaction pool is full
  // else returns false
  poolFull() {
    return this.transactions.unassigned.length >= TRANSACTION_THRESHOLD;
  }

  // wrapper function to verify transactions
  verifyTransaction(transaction) {
    return Transaction.verifyTransaction(transaction);
  }

  // checks if transactions exists or not
  transactionExists(transaction) {
    return Object.values(this.transactions) // get arrays
      .flat() // flatten to single array
      .some((item) => item.id === transaction.id); // check for match
  }

  // checks if transactions block hash exists or not
  hashExists(hash) {
    return this.transactions[hash] && this.transactions[hash].length > 0;
  }

  // check if other hashes have the same transactions, then move them to the unassigned pool
  // check if the unassigned pool has the same transactions, then remove them
  removeDuplicates(blockHash, transactions) {
    Object.keys(this.transactions).forEach((hash) => {
      if (blockHash === hash || 'unassigned' === hash) {
        return; // skip the current block hash and unassigned pool
      }
      const existingTransactions = this.transactions[hash] || [];
      const existingIds = new Set(existingTransactions.map((item) => item.id));
      const hasDuplicate = transactions.some(
        (item) => existingIds.has(item.id),
      );
      if (hasDuplicate) {
        this.transactions.unassigned = [ ...this.transactions.unassigned, ...existingTransactions ];  
        delete this.transactions[hash];
        delete this.transactionsCreatedAt[hash];
      }
    });
    // Remove duplicates from unassigned pool
    this.transactions.unassigned = this.transactions.unassigned.filter(
      (item, index, self) => index === self.findIndex((t) => t.id === item.id)
    );
    // Filter out transactions that are already in the unassigned pool
    this.transactions.unassigned = this.transactions.unassigned.filter(
      (item) => !transactions.some((t) => t.id === item.id),
    );
  }

  // empties the pool
  clear(hash, data) {
    console.log(`TRANSACTION POOL CLEARED FOR BLOCK #${hash}`);

    if (hash in this.transactions) {
      delete this.transactions[hash];
      delete this.transactionsCreatedAt[hash];
    }
    const removeIds = new Set(data.map((item) => item.id));
    this.transactions.unassigned = this.transactions.unassigned.filter(
      (item) => !removeIds.has(item.id),
    );
  }
}

module.exports = TransactionPool;
