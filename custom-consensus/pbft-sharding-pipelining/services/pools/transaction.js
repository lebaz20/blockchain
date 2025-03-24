// Import transaction class used for verification
const Transaction = require("../transaction");

// Transaction threshold is the limit or the holding capacity of the nodes
// Once this exceeds a new block is generated
const { TRANSACTION_THRESHOLD } = require("../../config");

class TransactionPool {
    constructor() {
      this.transactions = { unassigned: [] };
    }
  
    // pushes transactions in the list
    // returns true if it is full
    // else returns false
    addTransaction(transaction) {
      this.transactions.unassigned.push(transaction);
      return this.poolFull();
    }
  
    assignTransactions(block) {
      const assignedTransactions = block.data;
      const removeIds = new Set(assignedTransactions.map(item => item.id));
      this.transactions.unassigned = this.transactions.unassigned.filter(item => !removeIds.has(item.id));
      const hash = block.hash;
      this.transactions[hash] = assignedTransactions;
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
        .some(item => item.id === transaction.id); // check for match
    }
  
    // empties the pool
    clear(hash) {
      console.log(`TRANSACTION POOL CLEARED FOR BLOCK#${hash}`);

      if (hash in this.transactions) {
        delete this.transactions[hash];
      }
    }
  }
  
  module.exports = TransactionPool;