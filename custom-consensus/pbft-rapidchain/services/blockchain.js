// Import total number of nodes used to create validators list
const config = require("../config");

// Used to verify block
const Block = require("./block");
const RateUtility = require("../utils/rate");
const { readCgroupCPUPercentPromise } = require("../utils/cpu");
const { SHARD_STATUS } = require("../constants/status");
const { NODES_SUBSET, NUMBER_OF_NODES_PER_SHARD, SUBSET_INDEX, IS_FAULTY, MIN_APPROVALS } = config.get();

class Blockchain {
  // the constructor takes an argument validators class object
  // this is used to create a list of validators
  constructor(validators, transactionPool, isCore = false) {
    if (!isCore) {
      this.validatorList = validators.generateAddresses(NODES_SUBSET);
      this.transactionPool = transactionPool;
      this.chain = {
        [SUBSET_INDEX]: [Block.genesis()],
      };
    } else {
      this.chain = {};
      this.committeeChain = [Block.genesis()];
    }
    // Track the rate of incoming blocks
    this.ratePerMin = {};
  }

  // pushes confirmed blocks into the chain
  addBlock(block, subsetIndex = SUBSET_INDEX, isCommittee = false) {
    if (isCommittee) {
      this.committeeChain.push(block);
      console.log("NEW TEMP BLOCK ADDED TO CHAIN");
      return block;
    } else {
      if (!this.chain[subsetIndex]) {
        this.chain[subsetIndex] = [Block.genesis()];
      }
      block.createdAt = Date.now();
      if (!this.ratePerMin[subsetIndex]) {
        this.ratePerMin[subsetIndex] = {};
      }
      RateUtility.updateRatePerMin(this.ratePerMin[subsetIndex], block.createdAt);
      this.chain[subsetIndex].push(block);
      console.log("NEW BLOCK ADDED TO CHAIN");
      return block;
    }
  }

  // wrapper function to create blocks
  createBlock(transactions, wallet, previousBlock = undefined) {
    const block = Block.createBlock(
      previousBlock ??
        this.chain[SUBSET_INDEX][this.chain[SUBSET_INDEX].length - 1],
      transactions,
      wallet,
    );
    return block;
  }

  // calculates the next proposer by calculating a random index of the validators list
  // index is calculated using the hash of the latest block
  getProposer(blocksCount = undefined, isCommittee = false) {
    const chain = isCommittee ? this.committeeChain : this.chain;
    const currentChainLength = chain[SUBSET_INDEX].length;
    let blockIndex = (blocksCount ?? currentChainLength) - 1;
    if (!chain[SUBSET_INDEX][blockIndex]?.hash) {
      blockIndex = currentChainLength - 1;
    }

    const currentMinute = new Date().getMinutes(); // 0-59
    const index = (chain[SUBSET_INDEX][blockIndex].hash[0].charCodeAt(0) + currentMinute) % NUMBER_OF_NODES_PER_SHARD;
    return {
      proposer: this.validatorList[index],
      proposerIndex: NODES_SUBSET[index],
    };
  }

  // checks if the received block is valid
  isValidBlock(block, blocksCount, previousBlock = undefined, isCommittee = false) {
    const chain = isCommittee ? this.committeeChain : this.chain;
    const lastBlock =
      previousBlock ??
      chain[SUBSET_INDEX][chain[SUBSET_INDEX].length - 1];
    if (
      lastBlock.sequenceNo + 1 == block.sequenceNo &&
      block.lastHash === lastBlock.hash &&
      block.hash === Block.blockHash(block) &&
      Block.verifyBlock(block) &&
      Block.verifyProposer(block, this.getProposer(blocksCount, isCommittee).proposer)
    ) {
      console.log("BLOCK VALID");
      return true;
    } else {
      console.log(
        lastBlock.sequenceNo + 1 == block.sequenceNo,
        block.lastHash === lastBlock.hash,
        block.hash === Block.blockHash(block),
        Block.verifyBlock(block),
        Block.verifyProposer(block, this.getProposer(blocksCount, isCommittee).proposer),
      );
      console.log("BLOCK INVALID");
      return false;
    }
  }

  // updates the block by appending the prepare and commit messages to the block
  async addUpdatedBlock(hash, blockPool, preparePool, commitPool, isCommittee = false) {
    const blockExists = await this.waitUntilAvailableBlock(hash, (hash) =>
      blockPool.existingBlockByHash(hash, isCommittee),
    );
    if (blockExists) {
      const block = blockPool.getBlock(hash, isCommittee);
      const previousBlockExists = await this.waitUntilAvailableBlock(
        block.lastHash,
        (hash) => this.existingBlock(hash, SUBSET_INDEX, isCommittee),
      );
      if (previousBlockExists && this.transactionPool.hashExists(block.hash, isCommittee)) {
        this.transactionPool.removeDuplicates(block.hash, block.data, isCommittee);
        block.prepareMessages = preparePool.getList(hash, isCommittee);
        block.commitMessages = commitPool.getList(hash, isCommittee);
        this.addBlock(block, SUBSET_INDEX, isCommittee);
        return block;
      }
      console.log(`FAILED TO LOCATE PREVIOUS BLOCK #${block.lastHash}`);
      return false;
    }
    console.log(`FAILED TO LOCATE BLOCK #${hash}`);
    return false;
  }

  // checks if the block already exists
  existingBlock(hash, subsetIndex = SUBSET_INDEX, isCommittee = false) {
    return !!(isCommittee ? this.committeeChain : this.chain[subsetIndex])?.find((b) => b.hash === hash);
  }

  waitUntilAvailableBlock(item, existingCheck) {
    return new Promise((resolve) => {
      function recExistingCheck(retryInterval, retrialCount) {
        if (existingCheck(item)) {
          resolve(true);
        } else if (retrialCount <= 50) {
          setTimeout(
            () => recExistingCheck(retryInterval + 1000, retryInterval + 1),
            retryInterval + 1000,
          );
        } else {
          resolve(false);
        }
      }
      recExistingCheck(1000, 1);
    });
  }

  // get total number of blocks and transactions
  getTotal() {
    const total = {};
    Object.keys(this.chain).forEach((subsetIndex) => {
      const actualBlocksCount = this.chain[subsetIndex].length;
      total[subsetIndex] = {
        blocks: actualBlocksCount,
        transactions: this.chain[subsetIndex].reduce(
          (sum, block) => sum + block.data.length,
          0,
        ),
        unassignedTransactions: this.transactionPool?.transactions.unassigned.length
      };
    });
    return total;
  }

  // get shard rate of blocks and transactions
  async getRate(sockets) {
    let nonFaultyNodesCount = Object.keys(sockets).filter((port) => !sockets[port].isFaulty).length;
    if (!IS_FAULTY) {
      nonFaultyNodesCount++;
    }

    const cpuPercentage = await readCgroupCPUPercentPromise();
    const previousMinute = RateUtility.getPreviousMinute()
    const currentShardTransactionsRate = RateUtility.getRatePerMin(this.transactionPool?.ratePerMin, previousMinute);
    // let currentShardBlocksRate;
    const rate = {
      blocks: {},
      transactions: {
        [SUBSET_INDEX]: currentShardTransactionsRate
      }
    };
    Object.keys(this.chain).forEach((subsetIndex) => {
      const blocksRate = RateUtility.getRatePerMin(this.ratePerMin[subsetIndex], previousMinute);
      rate.blocks[subsetIndex] = blocksRate;
      // if (subsetIndex === SUBSET_INDEX) {
      //   currentShardBlocksRate = blocksRate;
      // }
    });

    // const currentShardProcessedTransactionsPeakRate = currentShardBlocksRate * TRANSACTION_THRESHOLD + TRANSACTION_THRESHOLD;
    let shardStatus = SHARD_STATUS.normal;
    // didn't build a single block or transaction rate is more than double the produced blocks rate
    // TODO: track failed consensus attempts
    // } else if (!currentShardBlocksRate || currentShardTransactionsRate > currentShardProcessedTransactionsPeakRate * 2) {
    if (nonFaultyNodesCount < MIN_APPROVALS) {
      shardStatus = SHARD_STATUS.faulty;
    } else if (cpuPercentage < 20) {
      shardStatus = SHARD_STATUS.under_utilized;
    } else if (cpuPercentage > 70) {
      shardStatus = SHARD_STATUS.over_utilized;
    }

    rate.shardStatus = shardStatus;
    // rate.shardStatus = SUBSET_INDEX === 'SUBSET1' ? SHARD_STATUS.faulty : SHARD_STATUS.normal;
    rate.nodeIndex = `NODE${process.env.HTTP_PORT.slice(1)}`;
    rate.shardIndex = SUBSET_INDEX;
    rate.shardSize = sockets ? Object.keys(sockets).length + 1 : 0;
    rate.cpu = `${cpuPercentage.toString()}%`;
    return rate;
  }
}
module.exports = Blockchain;
