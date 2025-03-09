// Import transaction class used for verification
const Transaction = require("../transaction");

// Transaction threshold is the limit or the holding capacity of the nodes
// Once this exceeds a new block is generated
const { TRANSACTION_THRESHOLD } = require("../../config");

class TransactionPool {
    constructor() {
      this.transactions = [];
    }
  
    // pushes transactions in the list
    // returns true if it is full
    // else returns false
    addTransaction(transaction) {
      this.transactions.push(transaction);
      return this.poolFull();
    }
  
    // returns true if transaction pool is full
    // else returns false
    poolFull() {
      return this.transactions.length >= TRANSACTION_THRESHOLD;
    }

    // wrapper function to verify transactions
    verifyTransaction(transaction) {
      return Transaction.verifyTransaction(transaction);
    }
  
    // checks if transactions exists or not
    transactionExists(transaction) {
      return !!this.transactions.find(t => t.id === transaction.id);
    }
  
    // empties the pool
    clear() {
    //   console.log("TRANSACTION POOL CLEARED");
      this.transactions = [];
    }
  }
  
  module.exports = TransactionPool;