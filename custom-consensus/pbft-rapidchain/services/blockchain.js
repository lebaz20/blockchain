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
const {
  NODES_SUBSET,
  NUMBER_OF_NODES_PER_SHARD,
  SUBSET_INDEX,
  IS_FAULTY,
  MIN_APPROVALS
} = config.get()

class Blockchain {
  constructor(validators, transactionPool, isCore = false) {
    if (!isCore) {
      this.validatorList = validators.generateAddresses(NODES_SUBSET)
      this.transactionPool = transactionPool
      this.chain = {
        [SUBSET_INDEX]: [Block.genesis()]
      }
    } else {
      this.chain = {}
      this.committeeChain = [Block.genesis()]
    }
    // Track the rate of incoming blocks
    this.ratePerMin = {}
  }

  addBlock(block, subsetIndex = SUBSET_INDEX, isCommittee = false) {
    if (isCommittee) {
      this.committeeChain.push(block)
      logger.log('NEW TEMP BLOCK ADDED TO CHAIN')
      return block
    } else {
      if (!this.chain[subsetIndex]) {
        this.chain[subsetIndex] = [Block.genesis()]
      }
      block.createdAt = Date.now()
      if (!this.ratePerMin[subsetIndex]) {
        this.ratePerMin[subsetIndex] = {}
      }
      RateUtility.updateRatePerMin(
        this.ratePerMin[subsetIndex],
        block.createdAt
      )
      this.chain[subsetIndex].push(block)
      logger.log('NEW BLOCK ADDED TO CHAIN')
      return block
    }
  }

  createBlock(transactions, wallet, previousBlock = undefined) {
    const block = Block.createBlock(
      previousBlock ??
        this.chain[SUBSET_INDEX][this.chain[SUBSET_INDEX].length - 1],
      transactions,
      wallet
    )
    return block
  }

  getProposer(blocksCount = undefined, isCommittee = false) {
    const chain = isCommittee ? this.committeeChain : this.chain
    const currentChainLength = chain[SUBSET_INDEX].length
    let blockIndex = (blocksCount ?? currentChainLength) - 1
    if (!chain[SUBSET_INDEX][blockIndex]?.hash) {
      blockIndex = currentChainLength - 1
    }

    const currentMinute = new Date().getMinutes()
    const hashCharCode =
      chain[SUBSET_INDEX][blockIndex].hash[HASH_FIRST_CHAR_INDEX].charCodeAt(0)
    const proposerRotationModulo = NUMBER_OF_NODES_PER_SHARD
    const index = (hashCharCode + currentMinute) % proposerRotationModulo
    return {
      proposer: this.validatorList[index],
      proposerIndex: NODES_SUBSET[index]
    }
  }

  isValidBlock(
    block,
    blocksCount,
    previousBlock = undefined,
    isCommittee = false
  ) {
    const chain = isCommittee ? this.committeeChain : this.chain
    const lastBlock =
      previousBlock ?? chain[SUBSET_INDEX][chain[SUBSET_INDEX].length - 1]
    if (
      lastBlock.sequenceNo + 1 === block.sequenceNo &&
      block.lastHash === lastBlock.hash &&
      block.hash === Block.blockHash(block) &&
      Block.verifyBlock(block) &&
      Block.verifyProposer(
        block,
        this.getProposer(blocksCount, isCommittee).proposer
      )
    ) {
      logger.log('BLOCK VALID')
      return true
    } else {
      logger.log(
        lastBlock.sequenceNo + 1 === block.sequenceNo,
        block.lastHash === lastBlock.hash,
        block.hash === Block.blockHash(block),
        Block.verifyBlock(block),
        Block.verifyProposer(
          block,
          this.getProposer(blocksCount, isCommittee).proposer
        )
      )
      logger.error('BLOCK INVALID')
      return false
    }
  }

  // eslint-disable-next-line max-params
  async addUpdatedBlock(
    hash,
    blockPool,
    preparePool,
    commitPool,
    isCommittee = false
  ) {
    const blockExists = await this.waitUntilAvailableBlock(hash, (hash) =>
      blockPool.existingBlockByHash(hash, isCommittee)
    )
    if (blockExists) {
      const block = blockPool.getBlock(hash, isCommittee)
      const previousBlockExists = await this.waitUntilAvailableBlock(
        block.lastHash,
        (hash) => this.existingBlock(hash, SUBSET_INDEX, isCommittee)
      )
      if (
        previousBlockExists &&
        this.transactionPool.hashExists(block.hash, isCommittee)
      ) {
        this.transactionPool.removeDuplicates(
          block.hash,
          block.data,
          isCommittee
        )
        block.prepareMessages = preparePool.getList(hash, isCommittee)
        block.commitMessages = commitPool.getList(hash, isCommittee)
        this.addBlock(block, SUBSET_INDEX, isCommittee)
        return block
      }
      logger.error(`FAILED TO LOCATE PREVIOUS BLOCK #${block.lastHash}`)
      return false
    }
    logger.error(`FAILED TO LOCATE BLOCK #${hash}`)
    return false
  }

  existingBlock(hash, subsetIndex = SUBSET_INDEX, isCommittee = false) {
    return !!(
      isCommittee ? this.committeeChain : this.chain[subsetIndex]
    )?.find((b) => b.hash === hash)
  }

  waitUntilAvailableBlock(item, existingCheck) {
    return new Promise((resolve) => {
      function recExistingCheck(retryInterval, retrialCount) {
        if (existingCheck(item)) {
          resolve(true)
        } else if (retrialCount <= MAX_RETRY_ATTEMPTS) {
          setTimeout(
            () =>
              recExistingCheck(
                retryInterval + RETRY_INTERVAL_INCREMENT_MS,
                retryInterval + 1
              ),
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
      const actualBlocksCount = this.chain[subsetIndex].length
      total[subsetIndex] = {
        blocks: actualBlocksCount,
        transactions: this.chain[subsetIndex].reduce(
          (sum, block) => sum + block.data.length,
          0
        ),
        unassignedTransactions:
          this.transactionPool?.transactions.unassigned.length
      }
    })
    return total
  }

  // get shard rate of blocks and transactions
  async getRate(sockets) {
    let nonFaultyNodesCount = Object.keys(sockets).filter(
      (port) => !sockets[port].isFaulty
    ).length
    if (!IS_FAULTY) {
      nonFaultyNodesCount++
    }

    const cpuPercentage = await readCgroupCPUPercentPromise()
    const previousMinute = RateUtility.getPreviousMinute()
    const currentShardTransactionsRate = RateUtility.getRatePerMin(
      this.transactionPool?.ratePerMin,
      previousMinute
    )
    // let currentShardBlocksRate;
    const rate = {
      blocks: {},
      transactions: {
        [SUBSET_INDEX]: currentShardTransactionsRate
      }
    }
    Object.keys(this.chain).forEach((subsetIndex) => {
      const blocksRate = RateUtility.getRatePerMin(
        this.ratePerMin[subsetIndex],
        previousMinute
      )
      rate.blocks[subsetIndex] = blocksRate
      // if (subsetIndex === SUBSET_INDEX) {
      //   currentShardBlocksRate = blocksRate;
      // }
    })

    // const currentShardProcessedTransactionsPeakRate = currentShardBlocksRate * TRANSACTION_THRESHOLD + TRANSACTION_THRESHOLD;
    let shardStatus = SHARD_STATUS.normal
    // didn't build a single block or transaction rate is more than double the produced blocks rate
    // TODO: track failed consensus attempts
    // } else if (!currentShardBlocksRate || currentShardTransactionsRate > currentShardProcessedTransactionsPeakRate * 2) {
    if (nonFaultyNodesCount < MIN_APPROVALS) {
      shardStatus = SHARD_STATUS.faulty
    } else if (cpuPercentage < CPU_UNDER_UTILIZED_THRESHOLD) {
      shardStatus = SHARD_STATUS.under_utilized
    } else if (cpuPercentage > CPU_OVER_UTILIZED_THRESHOLD) {
      shardStatus = SHARD_STATUS.over_utilized
    }

    rate.shardStatus = shardStatus
    // rate.shardStatus = SUBSET_INDEX === 'SUBSET1' ? SHARD_STATUS.faulty : SHARD_STATUS.normal;
    rate.nodeIndex = `NODE${process.env.HTTP_PORT.slice(1)}`
    rate.shardIndex = SUBSET_INDEX
    rate.shardSize = sockets ? Object.keys(sockets).length + 1 : 0
    rate.cpu = `${cpuPercentage.toString()}%`
    return rate
  }
}
module.exports = Blockchain
