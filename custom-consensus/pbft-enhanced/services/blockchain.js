// Import total number of nodes used to create validators list
const config = require('../config')
const logger = require('../utils/logger')

// Used to verify block
const Block = require('./block')

const HASH_FIRST_CHAR_INDEX = 0
const MAX_RETRY_ATTEMPTS = 50
const INITIAL_RETRY_INTERVAL_MS = 1000
const RETRY_INTERVAL_INCREMENT_MS = 1000
const CPU_UNDER_UTILIZED_THRESHOLD = 20
const CPU_OVER_UTILIZED_THRESHOLD = 70
const RateUtility = require('../utils/rate')
const { readCgroupCPUPercentPromise } = require('../utils/cpu')
const { SHARD_STATUS } = require('../constants/status')
const { NODES_SUBSET, NUMBER_OF_NODES_PER_SHARD, SUBSET_INDEX, IS_FAULTY, MIN_APPROVALS } =
  config.get()

const CPU_CACHE_INTERVAL_MS = 5000

class Blockchain {
  constructor(validators, transactionPool, isCore = false) {
    if (!isCore) {
      this.validatorList = validators.generateAddresses(NODES_SUBSET)
      this.transactionPool = transactionPool
      const genesis = Block.genesis()
      this.chain = { [SUBSET_INDEX]: [genesis] }
      // O(1) existingBlock index — one Set per shard chain keyed by block hash.
      // Enhanced has 6 shard chains (own + 5 foreign received via core); a Set
      // lookup eliminates the O(n) array.find on every incoming commit message
      // and every cross-shard block_from_core event.
      this._blockHashSets = { [SUBSET_INDEX]: new Set([genesis.hash]) }
      // O(1) transaction counter for getTotal() — incremented in addBlock.
      // Enhanced's core pod accumulates 6 shard chains and calls getTotal() on
      // every block_to_core message; the O(n) slice+reduce over all blocks was
      // doing ~90 000 iterations over a 90 s test just for stats logging.
      this._txCountCache = { [SUBSET_INDEX]: 0 } // genesis has 0 TXs
      // Separate counters for verification transactions and blocks (tagged with
      // _type:'verification') so stats distinguish normal client throughput from
      // cross-shard re-validation.  Kept at the top level of each tx object
      // (outside `input`) so the original signature inside `input` stays valid.
      this._verificationTxCountCache = { [SUBSET_INDEX]: 0 }
      this._normalBlockCountCache = { [SUBSET_INDEX]: 0 }
      this._verificationBlockCountCache = { [SUBSET_INDEX]: 0 }
    } else {
      this.chain = {}
      this._blockHashSets = {}
      this._txCountCache = {}
      this._verificationTxCountCache = {}
      this._normalBlockCountCache = {}
      this._verificationBlockCountCache = {}
    }
    // Track the rate of incoming blocks
    this.ratePerMin = {}
    // Cache CPU percentage so getRate() responds instantly without a 1s wait
    this._cpuCache = 0
    if (!isCore) {
      this._startCpuCacheUpdater()
    }
  }

  _startCpuCacheUpdater() {
    const update = () => {
      // eslint-disable-next-line promise/catch-or-return
      readCgroupCPUPercentPromise(CPU_CACHE_INTERVAL_MS)
        .then((pct) => {
          this._cpuCache = pct
          return pct
        })
        .catch(() => {
          // keep previous cached value on error
          return null
        })
        .finally(() => {
          this._cpuCacheTimer = setTimeout(update, CPU_CACHE_INTERVAL_MS)
        })
    }
    update()
  }

  stopCpuCacheUpdater() {
    if (this._cpuCacheTimer) {
      clearTimeout(this._cpuCacheTimer)
      this._cpuCacheTimer = null
    }
  }

  addBlock(block, subsetIndex = SUBSET_INDEX) {
    if (!this.chain[subsetIndex]) {
      const genesis = Block.genesis()
      this.chain[subsetIndex] = [genesis]
      this._blockHashSets[subsetIndex] = new Set([genesis.hash])
      this._txCountCache[subsetIndex] = 0
    }
    block.createdAt = Date.now()
    if (!this.ratePerMin[subsetIndex]) {
      this.ratePerMin[subsetIndex] = {}
    }
    RateUtility.updateRatePerMin(this.ratePerMin[subsetIndex], block.createdAt)
    this.chain[subsetIndex].push(block)
    // Update O(1) indices
    this._blockHashSets[subsetIndex].add(block.hash)
    // Count txs individually by type so verification txs mixed into normal blocks
    // are still attributed correctly.  All blocks count as normal blocks since
    // they all go through the same PBFT round.
    if (!this._verificationTxCountCache) this._verificationTxCountCache = {}
    if (!this._normalBlockCountCache) this._normalBlockCountCache = {}
    if (!this._verificationBlockCountCache) this._verificationBlockCountCache = {}
    this._normalBlockCountCache[subsetIndex] = (this._normalBlockCountCache[subsetIndex] ?? 0) + 1
    for (const tx of block.data) {
      if (tx?._type === 'verification') {
        this._verificationTxCountCache[subsetIndex] =
          (this._verificationTxCountCache[subsetIndex] ?? 0) + 1
      } else {
        this._txCountCache[subsetIndex] = (this._txCountCache[subsetIndex] ?? 0) + 1
      }
    }
    logger.log('NEW BLOCK ADDED TO CHAIN')
    return block
  }

  createBlock(transactions, wallet, previousBlock = undefined) {
    const block = Block.createBlock(
      previousBlock ?? this.chain[SUBSET_INDEX][this.chain[SUBSET_INDEX].length - 1],
      transactions,
      wallet
    )
    return block
  }

  getProposer(blocksCount = undefined, viewOffset = 0) {
    const currentChainLength = this.chain[SUBSET_INDEX].length
    let blockIndex = (blocksCount ?? currentChainLength) - 1
    if (!this.chain[SUBSET_INDEX][blockIndex]?.hash) {
      blockIndex = currentChainLength - 1
    }

    const hashCharCode =
      this.chain[SUBSET_INDEX][blockIndex].hash[HASH_FIRST_CHAR_INDEX].charCodeAt(0)
    const proposerRotationModulo = NUMBER_OF_NODES_PER_SHARD
    const index = (hashCharCode + viewOffset) % proposerRotationModulo

    return {
      proposer: this.validatorList[index],
      proposerIndex: NODES_SUBSET[index]
    }
  }

  isValidBlock(block, blocksCount, previousBlock = undefined, viewOffset = 0) {
    const lastBlock = previousBlock ?? this.chain[SUBSET_INDEX][this.chain[SUBSET_INDEX].length - 1]
    const isValid =
      lastBlock.sequenceNo + 1 === block.sequenceNo &&
      block.lastHash === lastBlock.hash &&
      block.hash === Block.blockHash(block) &&
      Block.verifyBlock(block) &&
      Block.verifyProposer(block, this.getProposer(blocksCount, viewOffset).proposer)

    if (isValid) {
      logger.log('BLOCK VALID')
    } else {
      logger.error('BLOCK INVALID')
    }
    return isValid
  }

  async addUpdatedBlock(hash, blockPool, preparePool, commitPool) {
    const blockExists = await this.waitUntilAvailableBlock(hash, (hash) =>
      blockPool.existingBlockByHash(hash)
    )
    if (blockExists) {
      const block = blockPool.getBlock(hash)
      const previousBlockExists = await this.waitUntilAvailableBlock(block.lastHash, (hash) =>
        this.existingBlock(hash)
      )
      if (previousBlockExists && this.transactionPool.hashExists(block.hash)) {
        this.transactionPool.removeDuplicates(block.hash, block.data)
        block.prepareMessages = preparePool.getList(hash)
        block.commitMessages = commitPool.getList(hash)
        this.addBlock(block)
        return block
      }
      logger.error(`FAILED TO LOCATE PREVIOUS BLOCK #${block.lastHash}`)
      return false
    }
    logger.error(`FAILED TO LOCATE BLOCK #${hash}`)
    return false
  }

  existingBlock(hash, subsetIndex = SUBSET_INDEX) {
    // O(1) Set lookup replaces O(n) array.find — chain length grows throughout
    // the test and existingBlock is called on every incoming commit and every
    // cross-shard block_from_core event (5x per committed block in Enhanced).
    const hashSet = this._blockHashSets[subsetIndex]
    if (hashSet) return hashSet.has(hash)
    return !!this.chain[subsetIndex]?.find((b) => b.hash === hash)
  }

  waitUntilAvailableBlock(item, existingCheck) {
    return new Promise((resolve) => {
      function recExistingCheck(retryInterval, retrialCount) {
        if (existingCheck(item)) {
          resolve(true)
        } else if (retrialCount <= MAX_RETRY_ATTEMPTS) {
          setTimeout(
            () => recExistingCheck(retryInterval + RETRY_INTERVAL_INCREMENT_MS, retrialCount + 1),
            retryInterval + RETRY_INTERVAL_INCREMENT_MS
          )
        } else {
          resolve(false)
        }
      }
      recExistingCheck(INITIAL_RETRY_INTERVAL_MS, 1)
    })
  }

  // get total number of blocks and transactions
  getTotal() {
    const total = {}
    Object.keys(this.chain).forEach((subsetIndex) => {
      // Subtract 1 to exclude the genesis block (always present, always has 0 transactions)
      const actualBlocksCount = Math.max(0, this.chain[subsetIndex].length - 1)
      total[subsetIndex] = {
        // Total blocks in chain (normal + verification) minus genesis.
        blocks: actualBlocksCount,
        // Normal client transactions only — used for Drain Rate and Effective TX Rate.
        transactions: this._txCountCache[subsetIndex] ?? 0,
        // Verification transactions committed when acting as ring-assigned verifier.
        // Reported separately — excluded from all primary performance metrics.
        verificationTransactions: this._verificationTxCountCache?.[subsetIndex] ?? 0,
        // Block-level split mirrors tx-level split; used for Avg TX per Normal Block.
        normalBlocks: this._normalBlockCountCache?.[subsetIndex] ?? 0,
        verificationBlocks: this._verificationBlockCountCache?.[subsetIndex] ?? 0,
        // Only this node's own pool is visible to it; report 0 for foreign shards
        // so the stats collection script does not multiply the pool size by shard count.
        unassignedTransactions:
          subsetIndex === SUBSET_INDEX
            ? (this.transactionPool?.transactions.unassigned.length ?? 0)
            : 0,
        // How many of those unassigned are verification (cross-shard re-validation) TXs.
        // A non-zero value here means VTXs are piling up faster than the shard can commit them.
        verificationUnassignedTransactions:
          subsetIndex === SUBSET_INDEX
            ? (this.transactionPool?.transactions.unassigned.filter(
                (tx) => tx._type === 'verification'
              ).length ?? 0)
            : 0
      }
    })
    return total
  }

  // Calculate shard status based on non-faulty nodes and CPU usage
  calculateShardStatus(nonFaultyNodesCount, cpuPercentage) {
    if (nonFaultyNodesCount < MIN_APPROVALS) {
      return SHARD_STATUS.faulty
    }
    if (cpuPercentage < CPU_UNDER_UTILIZED_THRESHOLD) {
      return SHARD_STATUS.under_utilized
    }
    if (cpuPercentage > CPU_OVER_UTILIZED_THRESHOLD) {
      return SHARD_STATUS.over_utilized
    }
    return SHARD_STATUS.normal
  }

  // get shard rate of blocks and transactions
  async getRate(sockets) {
    const faultyNodesCount = Object.keys(sockets).filter((port) => sockets[port].isFaulty).length
    const totalNodesCount = Object.keys(sockets).length + (IS_FAULTY ? 0 : 1)
    const nonFaultyNodesCount = totalNodesCount - faultyNodesCount

    // Use cached CPU value — updated in background every CPU_CACHE_INTERVAL_MS
    const cpuPercentage = this._cpuCache
    const previousMinute = RateUtility.getPreviousMinute()
    const currentShardTransactionsRate = RateUtility.getRatePerMin(
      this.transactionPool?.ratePerMin,
      previousMinute
    )
    const rate = {
      blocks: {},
      transactions: {
        [SUBSET_INDEX]: currentShardTransactionsRate
      }
    }
    Object.keys(this.chain).forEach((subsetIndex) => {
      const blocksRatePerMinute = RateUtility.getRatePerMin(
        this.ratePerMin[subsetIndex],
        previousMinute
      )
      rate.blocks[subsetIndex] = blocksRatePerMinute
    })

    rate.shardStatus = this.calculateShardStatus(nonFaultyNodesCount, cpuPercentage)
    rate.nodeIndex = `NODE${process.env.HTTP_PORT.slice(1)}`
    rate.shardIndex = SUBSET_INDEX
    rate.shardSize = sockets ? Object.keys(sockets).length + 1 : 0
    rate.cpu = `${cpuPercentage.toString()}%`
    return rate
  }
}
module.exports = Blockchain
