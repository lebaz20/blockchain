class BlockPool {
  constructor() {
    this.blocks = [];
    this.latestInflightBlock = undefined;
  }

  // check if the block exists or not
  existingBlock(block) {
    return !!this.blocks?.find((b) => b.hash === block.hash);
  }
  existingBlockByHash(hash) {
    return !!this.blocks?.find((b) => b.hash === hash);
  }

  // pushes block to the chain
  addBlock(block) {
    this.blocks.push(block);
    console.log("added block to pool");
  }

  // pushes block to the chain
  setLatestInflightBlock(block) {
    this.latestInflightBlock = block;
    console.log("set latest Inflight Block#", block.hash);
  }

  // returns the block for the given hash
  getBlock(hash) {
    return this.blocks.find((b) => b.hash === hash);
  }
}

module.exports = BlockPool;
