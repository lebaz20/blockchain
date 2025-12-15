// Import transaction class used for verification
const Transaction = require("../transaction");
const RateUtility = require("../../utils/rate");

// Transaction threshold is the limit or the holding capacity of the nodes
// Once this exceeds a new block is generated
const config = require("../../config");
const { TRANSACTION_THRESHOLD, BLOCK_THRESHOLD } = config.get();

class TransactionPool {
  constructor() {
    this.transactions = { unassigned: [] };
    this.transactionsCreatedAt = {}
    this.committeeTransactions = { unassigned: [] };
    // Track the rate of incoming transactions
    this.ratePerMin = {};
  }

  // pushes transactions in the list
  addTransaction(transaction, isCommittee = false) {
    if (isCommittee) {
      if (!this.committeeTransactions) {
        this.committeeTransactions = { unassigned: [] };
      }
      this.committeeTransactions.unassigned.push(transaction);
    } else {
      this.transactions.unassigned.push(transaction);
      RateUtility.updateRatePerMin(this.ratePerMin, transaction.createdAt);
    }
  }

  // assign block transactions to the block via block hash
  // Release assignment after x time in case block creation doesn't succeed
  assignTransactions(block, isCommittee = false) {
    const assignedTransactions = block.data;
    if (!isCommittee) {
      const removeIds = new Set(assignedTransactions.map((item) => item.id));
      this.transactions.unassigned = this.transactions.unassigned.filter(
        (item) => !removeIds.has(item.id),
      );

      const hash = block.hash;
      this.transactions[hash] = assignedTransactions;
      this.transactionsCreatedAt[hash] = Date.now();

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
    } else {
      const removeIds = new Set(assignedTransactions.map((item) => item.id));
      this.committeeTransactions.unassigned = this.committeeTransactions.unassigned.filter(
        (item) => !removeIds.has(item.id),
      );

      const hash = block.hash;
      this.committeeTransactions[hash] = assignedTransactions;
      setTimeout(() => {
        // remove the block hash after 2 minutes
        if (this.committeeTransactions[hash] && this.committeeTransactions[hash].length > 0) {
          this.committeeTransactions.unassigned = [ ...this.committeeTransactions.unassigned, ...this.committeeTransactions[hash] ];  
          delete this.committeeTransactions[hash];
          // Remove duplicates from unassigned pool
          this.committeeTransactions.unassigned = this.committeeTransactions.unassigned.filter(
            (item, index, self) => index === self.findIndex((t) => t.id === item.id)
          );
        }
      }, 2 * 60 * 1000); // 2 minutes
    }
  }

  // get inflight blocks
  getInflightBlocks(block = undefined, isCommittee = false) {
    // unassigned is the only key we have in case no inbound transactions
    let inflightBlocks = Object.keys(isCommittee ? this.committeeTransactions :this.transactions);
    if (block?.hash) {
      inflightBlocks = inflightBlocks.filter((hash) => hash !== block.hash);
    }
    return inflightBlocks;
  }

  // returns true if transaction pool is full
  // else returns false
  poolFull(isCommittee = false) {
    if (isCommittee) {
    return this.committeeTransactions.unassigned.length >= BLOCK_THRESHOLD;
    }
    return this.transactions.unassigned.length >= TRANSACTION_THRESHOLD;
  }

  // wrapper function to verify transactions
  verifyTransaction(transaction) {
    return Transaction.verifyTransaction(transaction);
  }

  // checks if transactions exists or not
  transactionExists(transaction, isCommittee = false) {
    return (isCommittee ? this.committeeTransactions : Object.values(this.transactions) // get arrays
      .flat() // flatten to single array
  ).some((item) => item.id === transaction.id); // check for match
  }

  // checks if transactions block hash exists or not
  hashExists(hash, isCommittee = false) {
    return (isCommittee ? this.committeeTransactions : this.transactions)[hash] && (isCommittee ? this.committeeTransactions : this.transactions)[hash].length > 0;
  }

  // check if other hashes have the same transactions, then move them to the unassigned pool
  // check if the unassigned pool has the same transactions, then remove them
  removeDuplicates(blockHash, transactions, isCommittee = false) {
    if (isCommittee) {
      Object.keys(this.committeeTransactions).forEach((hash) => {
        if (blockHash === hash || 'unassigned' === hash) {
          return; // skip the current block hash and unassigned pool
        }
        const existingTransactions = this.committeeTransactions[hash] || [];
        const existingIds = new Set(existingTransactions.map((item) => item.id));
        const hasDuplicate = transactions.some(
          (item) => existingIds.has(item.id),
        );
        if (hasDuplicate) {
          this.committeeTransactions.unassigned = [ ...this.committeeTransactions.unassigned, ...existingTransactions ];  
          delete this.committeeTransactions[hash];
        }
      });
      // Remove duplicates from unassigned pool
      this.committeeTransactions.unassigned = this.committeeTransactions.unassigned.filter(
        (item, index, self) => index === self.findIndex((t) => t.id === item.id)
      );
      // Filter out transactions that are already in the unassigned pool
      this.committeeTransactions.unassigned = this.committeeTransactions.unassigned.filter(
        (item) => !transactions.some((t) => t.id === item.id),
      );
    } else {
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
  }

  // empties the pool
  clear(hash, data, isCommittee = false) {
    console.log(`TRANSACTION POOL CLEARED FOR BLOCK #${hash}`);

    if (isCommittee) {
      if (hash in this.committeeTransactions) {
        delete this.committeeTransactions[hash];
        delete this.committeeTransactionsCreatedAt[hash];
      }
      const removeIds = new Set(data.map((item) => item.id));
      this.committeeTransactions.unassigned = this.committeeTransactions.unassigned.filter(
        (item) => !removeIds.has(item.id),
      );
    } else {
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
}

module.exports = TransactionPool;
