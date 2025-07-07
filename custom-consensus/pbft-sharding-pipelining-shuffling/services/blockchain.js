// Import total number of nodes used to create validators list
const { NODES_SUBSET, NUMBER_OF_NODES, SUBSET_INDEX, TRANSACTION_THRESHOLD } = require("../config");

// Used to verify block
const Block = require("./block");
const RateUtility = require("../utils/rate");
const { SHARD_STATUS } = require("../constants/status");

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
    }
    // Track the rate of incoming blocks
    this.ratePerMin = {};
  }

  // pushes confirmed blocks into the chain
  addBlock(block, subsetIndex = SUBSET_INDEX) {
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
  getProposer(blocksCount = undefined) {
    const index =
      this.chain[SUBSET_INDEX][
        (blocksCount ?? this.chain[SUBSET_INDEX].length) - 1
      ].hash[0].charCodeAt(0) % NUMBER_OF_NODES;
    return this.validatorList[index];
  }

  // checks if the received block is valid
  isValidBlock(block, blocksCount, previousBlock = undefined) {
    const lastBlock =
      previousBlock ??
      this.chain[SUBSET_INDEX][this.chain[SUBSET_INDEX].length - 1];
    if (
      lastBlock.sequenceNo + 1 == block.sequenceNo &&
      block.lastHash === lastBlock.hash &&
      block.hash === Block.blockHash(block) &&
      Block.verifyBlock(block) &&
      Block.verifyProposer(block, this.getProposer(blocksCount))
    ) {
      console.log("BLOCK VALID");
      return true;
    } else {
      console.log(
        previousBlock,
        lastBlock,
        lastBlock.sequenceNo + 1 == block.sequenceNo,
        block.lastHash === lastBlock.hash,
        block.hash === Block.blockHash(block),
        Block.verifyBlock(block),
        Block.verifyProposer(block, this.getProposer(blocksCount)),
      );
      console.log("BLOCK INVALID");
      return false;
    }
  }

  // updates the block by appending the prepare and commit messages to the block
  async addUpdatedBlock(hash, blockPool, preparePool, commitPool) {
    const blockExists = await this.waitUntilAvailableBlock(hash, (hash) =>
      blockPool.existingBlockByHash(hash),
    );
    if (blockExists) {
      const block = blockPool.getBlock(hash);
      const previousBlockExists = await this.waitUntilAvailableBlock(
        block.lastHash,
        (hash) => this.existingBlock(hash),
      );
      if (previousBlockExists && this.transactionPool.hashExists(block.hash)) {
        this.transactionPool.removeDuplicates(block.hash, block.data);
        block.prepareMessages = preparePool.getList(hash);
        block.commitMessages = commitPool.getList(hash);
        this.addBlock(block);
        return block;
      }
      console.log(`FAILED TO LOCATE PREVIOUS BLOCK #${block.lastHash}`);
      return false;
    }
    console.log(`FAILED TO LOCATE BLOCK #${hash}`);
    return false;
  }

  // checks if the block already exists
  existingBlock(hash, subsetIndex = SUBSET_INDEX) {
    return !!this.chain[subsetIndex]?.find((b) => b.hash === hash);
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
      };
    });
    return total;
  }

  // get shard rate of blocks and transactions
  getRate() {
    const previousMinute = RateUtility.getPreviousMinute()
    const currentShardTransactionsRate = RateUtility.getRatePerMin(this.transactionPool?.ratePerMin, previousMinute);
    let currentShardBlocksRate;
    const rate = {
      blocks: {},
      transactions: {
        [SUBSET_INDEX]: currentShardTransactionsRate
      }
    };
    Object.keys(this.chain).forEach((subsetIndex) => {
      const blocksRate = RateUtility.getRatePerMin(this.ratePerMin[subsetIndex], previousMinute);
      rate.blocks[subsetIndex] = blocksRate;
      if (subsetIndex === SUBSET_INDEX) {
        currentShardBlocksRate = blocksRate;
      }
    });

    const currentShardProcessedTransactionsPeakRate = currentShardBlocksRate * TRANSACTION_THRESHOLD + TRANSACTION_THRESHOLD;
    let shardStatus = SHARD_STATUS.normal;
    // transaction rate less than threshold needed for a single block or less than a lower-bound threshold or no transactions at all
    if (!currentShardTransactionsRate || currentShardTransactionsRate < TRANSACTION_THRESHOLD || currentShardTransactionsRate < 20) {
      shardStatus = SHARD_STATUS.under_utilized;
      // didn't build a single block or transaction rate is more than double the produced blocks rate
      // TODO: track failed consensus attempts
    } else if (!currentShardBlocksRate || currentShardTransactionsRate > currentShardProcessedTransactionsPeakRate * 2) {
      shardStatus = SHARD_STATUS.faulty;
      // transaction rate is more than the peak rate of processed transactions by a margin
    } else if (currentShardBlocksRate > 0 && currentShardTransactionsRate > currentShardProcessedTransactionsPeakRate * 1.2) {
      shardStatus = SHARD_STATUS.over_utilized;
    }

    rate.shardStatus = shardStatus;
    rate.nodeIndex = `NODE${process.env.HTTP_PORT.slice(1)}`;
    rate.shardIndex = SUBSET_INDEX;
    return rate;
  }
}
module.exports = Blockchain;
