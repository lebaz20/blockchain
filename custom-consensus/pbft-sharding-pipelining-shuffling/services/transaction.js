// Import the ChainUtil class used for hashing and verification
const ChainUtil = require("../utils/chain");

class Transaction {
  // the wallet instance will be passed as a parameter to the constructor
  // along with the data to be stored.
  constructor(data, wallet) {
    this.id = ChainUtil.id();
    this.from = wallet.publicKey;
    this.input = { data: data, timestamp: Date.now() };
    this.hash = ChainUtil.hash(this.input);
    this.signature = wallet.sign(this.hash);
    // console.log({
    //   id: this.id, from: this.from, input: this.input, signature: this.signature, hash: this.hash
    // });
  }

  // this method verifies whether the transaction is valid
  static verifyTransaction(transaction) {
    return ChainUtil.verifySignature(
      transaction.from,
      transaction.signature,
      ChainUtil.hash(transaction.input),
    );
  }
}

module.exports = Transaction;
