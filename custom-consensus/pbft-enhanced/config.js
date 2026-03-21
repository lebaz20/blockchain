const fs = require('fs')
const path = require('path')

const CONFIG_PATH = path.join(__dirname, `config.persisted.${process.env.HTTP_PORT}.json`)

// Load config from file or fallback to env/defaults
function loadConfig() {
  if (fs.existsSync(CONFIG_PATH)) {
    return JSON.parse(fs.readFileSync(CONFIG_PATH, 'utf8'))
  }

  // Maximum number of transactions that can be present in a block and transaction pool
  const TRANSACTION_THRESHOLD = process.env.TRANSACTION_THRESHOLD
    ? parseInt(process.env.TRANSACTION_THRESHOLD, 10)
    : 5

  // Maximum number of transactions sent per redirect drain cycle.
  // Decoupled from TRANSACTION_THRESHOLD so broken shards can flush larger backlogs
  // in one HTTP round-trip while healthy shards still form smaller, faster blocks.
  // Defaults to 2× TRANSACTION_THRESHOLD (e.g. drain 100 TX/cycle, confirm in 50-TX blocks).
  const DRAIN_BATCH_SIZE = process.env.DRAIN_BATCH_SIZE
    ? parseInt(process.env.DRAIN_BATCH_SIZE, 10)
    : TRANSACTION_THRESHOLD * 2

  // total number of nodes in the network
  const NUMBER_OF_NODES_PER_SHARD = process.env.NUMBER_OF_NODES_PER_SHARD
    ? parseInt(process.env.NUMBER_OF_NODES_PER_SHARD, 10)
    : 4

  const DEFAULT_TTL = process.env.DEFAULT_TTL ? parseInt(process.env.DEFAULT_TTL, 10) : 6
  const NUMBER_OF_NODES = process.env.NUMBER_OF_NODES
    ? parseInt(process.env.NUMBER_OF_NODES, 10)
    : 8
  const NODES_SUBSET = process.env.NODES_SUBSET ? JSON.parse(process.env.NODES_SUBSET) : []

  const SHOULD_REDIRECT_FROM_FAULTY_NODES = process.env.SHOULD_REDIRECT_FROM_FAULTY_NODES === 'true'
  const IS_FAULTY = process.env.IS_FAULTY === 'true'

  // improve performance by using a subset of nodes in the network
  const NUMBER_OF_FAULTY_NODES = process.env.NUMBER_OF_FAULTY_NODES || 0

  // Minimum number of positive votes required for the message/block to be valid
  // Standard PBFT safety threshold: 2f+1 where f = floor((n-1)/3)
  // This tolerates up to floor((n-1)/3) faulty nodes per shard.
  // The naive formula 2*(n/3) gives 5.33 for n=8 (requires 6 votes) which is
  // stricter than necessary — shards with 3 faulty out of 8 only have 5 honest
  // nodes and would never reach consensus even though PBFT allows it.
  const MIN_APPROVALS = 2 * Math.floor((NUMBER_OF_NODES_PER_SHARD - 1) / 3) + 1

  // SUBSET INDEX
  const SUBSET_INDEX = process.env.SUBSET_INDEX ?? 'SUBSET1'

  // CPU limit for each node in the network
  const CPU_LIMIT = process.env.CPU_LIMIT ?? '1'

  const REDIRECT_TO_URL = process.env.REDIRECT_TO_URL ?? []

  // Each shard is the designated verifier for ALL other shards in the pool.
  // Computed statically at pod creation time by prepare-config.js and injected
  // as a JSON array env var — dead shards simply never emit block_from_core.
  const VERIFICATION_SOURCE_SUBSETS = process.env.VERIFICATION_SOURCE_SUBSETS
    ? JSON.parse(process.env.VERIFICATION_SOURCE_SUBSETS)
    : []

  const config = {
    TRANSACTION_THRESHOLD,
    DRAIN_BATCH_SIZE,
    NUMBER_OF_NODES_PER_SHARD,
    NUMBER_OF_NODES,
    NUMBER_OF_FAULTY_NODES,
    MIN_APPROVALS,
    SUBSET_INDEX,
    NODES_SUBSET,
    CPU_LIMIT,
    REDIRECT_TO_URL,
    IS_FAULTY,
    SHOULD_REDIRECT_FROM_FAULTY_NODES,
    DEFAULT_TTL,
    VERIFICATION_SOURCE_SUBSETS
  }
  fs.writeFileSync(CONFIG_PATH, JSON.stringify(config, null, 2))
  return config
}

module.exports = {
  get: () => loadConfig(),
  set: (key, value) => {
    const config = loadConfig()
    config[key] = value
    fs.writeFileSync(CONFIG_PATH, JSON.stringify(config, null, 2))
  }
}
