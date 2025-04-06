// Import total number of nodes used to create validators list
const { NODES_SUBSET, NUMBER_OF_NODES } = require("../config");

// Used to verify block
const Block = require("./block");

class Blockchain {
    // the constructor takes an argument validators class object
    // this is used to create a list of validators
    constructor(validators) {
      this.validatorList = validators.generateAddresses(NODES_SUBSET);
      this.chain = [Block.genesis()];
    }
  
    // pushes confirmed blocks into the chain
    addBlock(block) {
      this.chain.push(block);
      console.log("NEW BLOCK ADDED TO CHAIN");
      return block;
    }
  
    // wrapper function to create blocks
    createBlock(transactions, wallet, previousBlock = undefined) {
      const block = Block.createBlock(
        previousBlock ?? this.chain[this.chain.length - 1],
        transactions,
        wallet
      );
      return block;
    }
  
    // calculates the next proposer by calculating a random index of the validators list
    // index is calculated using the hash of the latest block
    getProposer(blocksCount = undefined) {
      // const index = this.chain[(blocksCount ?? this.chain.length) - 1].hash[0].charCodeAt(0) % NUMBER_OF_NODES;
      // TODO: Rotate leadership
      const index = 0;
      return this.validatorList[index];
    }
  
    // checks if the received block is valid
    isValidBlock(block, blocksCount, previousBlock = undefined) {
      const lastBlock = previousBlock ?? this.chain[this.chain.length - 1];
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
        console.log(previousBlock, lastBlock, lastBlock.sequenceNo + 1 == block.sequenceNo ,block.lastHash === lastBlock.hash ,
          block.hash === Block.blockHash(block) ,
          Block.verifyBlock(block) ,
          Block.verifyProposer(block, this.getProposer(blocksCount)))
        console.log("BLOCK INVALID");
        return false;
      }
    }
  
    // updates the block by appending the prepare and commit messages to the block
    async addUpdatedBlock(hash, blockPool, preparePool, commitPool) {
      const blockExists = await this.waitUntilAvailableBlock(hash, (hash) => blockPool.existingBlockByHash(hash));
      if (blockExists) {
        const block = blockPool.getBlock(hash);
        const previousBlockExists = await this.waitUntilAvailableBlock(block.lastHash, (hash) => this.existingBlock(hash));
        if (previousBlockExists)  {
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
    existingBlock(hash) {
      return !!this.chain.find(
        b => b.hash === hash
      );
    }

    waitUntilAvailableBlock(item, existingCheck) {
      return new Promise((resolve) => {
          function recExistingCheck(retryInterval, retrialCount) {
            if (existingCheck(item)) {
              resolve(true);
            } else if (retrialCount <= 50) {
              setTimeout(() => recExistingCheck(retryInterval + 1000, retryInterval + 1), retryInterval + 1000);
            } else {
              resolve(false);
            }
          }
          recExistingCheck(1000, 1);
      });
    }

    // get total number of blocks and transactions
    getTotal() {
      return {
        blocks: this.chain.length,
        transactions: this.chain.reduce((sum, block) => sum + block.data.length, 0)
      }
    }
  }
  module.exports = Blockchain;