// Maximum number of transactions that can be present in a block and transaction pool
const TRANSACTION_THRESHOLD = process.env.TRANSACTION_THRESHOLD ? parseInt(process.env.TRANSACTION_THRESHOLD, 10) : 5;

// total number of nodes in the network
const NUMBER_OF_NODES = process.env.NUMBER_OF_NODES ? parseInt(process.env.NUMBER_OF_NODES, 10) : 3;
const NODES_SUBSET = process.env.NODES_SUBSET ? JSON.parse(process.env.NODES_SUBSET) : [];

// improve performance by using a subset of nodes in the network
const ACTIVE_SUBSET_OF_NODES = process.env.ACTIVE_SUBSET_OF_NODES ||  0.5;

// Minimum number of positive votes required for the message/block to be valid
const MIN_APPROVALS = 2 * (NUMBER_OF_NODES / 3) + 1;

// SUBSET INDEX
const SUBSET_INDEX = process.env.SUBSET_INDEX ?? 'SUBSET1';

// IS_LEADER 
// TODO: Rotate leadership among all nodes
const IS_LEADER = process.env.IS_LEADER === 'true';

module.exports = {
  TRANSACTION_THRESHOLD,
  NUMBER_OF_NODES,
  ACTIVE_SUBSET_OF_NODES,
  MIN_APPROVALS,
  SUBSET_INDEX,
  NODES_SUBSET,
  IS_LEADER
};