// Maximum number of transactions that can be present in a block and transaction pool
const TRANSACTION_THRESHOLD = process.env.TRANSACTION_THRESHOLD ? parseInt(process.env.TRANSACTION_THRESHOLD, 10) : 5;

// total number of nodes in the network
const NUMBER_OF_NODES = process.env.NUMBER_OF_NODES ? parseInt(process.env.NUMBER_OF_NODES, 10) : 3;

// Minimum number of positive votes required for the message/block to be valid
const MIN_APPROVALS = 2 * (NUMBER_OF_NODES / 3) + 1;

module.exports = {
  TRANSACTION_THRESHOLD,
  NUMBER_OF_NODES,
  MIN_APPROVALS
};