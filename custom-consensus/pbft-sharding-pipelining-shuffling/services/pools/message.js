const ChainUtil = require("../../utils/chain");

class MessagePool {
  // list object is a map that holds a list of messages for a hash of a block
  constructor() {
    this.list = {};
    this.message = "INITIATE NEW ROUND";
  }

  // creates a round change message for the given block hash
  createMessage(blockHash, wallet) {
    let roundChange = {
      publicKey: wallet.getPublicKey(),
      message: this.message,
      blockHash,
      signature: wallet.sign(ChainUtil.hash(this.message + blockHash)),
    };

    this.list[blockHash] = [roundChange];
    return roundChange;
  }

  // pushes the message for a block hash into the list
  addMessage(message) {
    if (!(message.blockHash in this.list)) {
      return;
    }
    this.list[message.blockHash].push(message);
  }

  // checks if the message already exists
  existingMessage(message) {
    if (this.list[message.blockHash]) {
      return !!this.list[message.blockHash]?.find(
        (p) => p.publicKey === message.publicKey,
      );
    }
    return false;
  }

  // checks if the message is valid or not
  isValidMessage(message) {
    return ChainUtil.verifySignature(
      message.publicKey,
      message.signature,
      ChainUtil.hash(message.message + message.blockHash),
    );
  }
}

module.exports = MessagePool;
