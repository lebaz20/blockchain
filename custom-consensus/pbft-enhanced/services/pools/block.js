const logger = require('../../utils/logger')

class BlockPool {
  constructor() {
    this.blocks = []
  }

  // check if the block exists or not
  existingBlock(block) {
    return !!this.blocks?.find((b) => b.hash === block.hash)
  }
  existingBlockByHash(hash) {
    return !!this.blocks?.find((b) => b.hash === hash)
  }

  // pushes block to the chain
  addBlock(block) {
    this.blocks.push(block)
    logger.log('added block to pool')
  }

  // returns the block for the given hash
  getBlock(hash) {
    return this.blocks.find((b) => b.hash === hash)
  }
}

module.exports = BlockPool
