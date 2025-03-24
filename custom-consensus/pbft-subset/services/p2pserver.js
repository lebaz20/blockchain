// import the ws module
const WebSocket = require("ws");
const fs = require('fs');

// Create a write stream to your desired log file
const logStream = fs.createWriteStream('server.log', { flags: 'a' }); // 'a' = append

// Redirect console.log and console.error
console.log = function (...args) {
  logStream.write(`[LOG ${new Date().toISOString()}] ${args.join(' ')}\n`);
  process.stdout.write(`[LOG] ${args.join(' ')}\n`); // Optional: also log to terminal
};

console.error = function (...args) {
  logStream.write(`[ERROR ${new Date().toISOString()}] ${args.join(' ')}\n`);
  process.stderr.write(`[ERROR] ${args.join(' ')}\n`);
};

// import the min approval constant which will be used to compare the count the messages
// import active subset of nodes to use in validation
const { MIN_APPROVALS } = require("../config");

// declare a p2p server port on which it would listen for messages
// we will pass the port through command line
const P2P_PORT = process.env.P2P_PORT || 5001;

// the neighboring nodes socket addresses will be passed in command line
// this statement splits them into an array
const peers = process.env.PEERS ? process.env.PEERS.split(",") : [];

// message types used to avoid typing messages
// also used in switch statement in message handlers
const MESSAGE_TYPE = {
  transaction: "TRANSACTION",
  prepare: "PREPARE",
  pre_prepare: "PRE-PREPARE",
  commit: "COMMIT",
  round_change: "ROUND_CHANGE"
};

class P2pserver {
    constructor(
      blockchain,
      transactionPool,
      wallet,
      blockPool,
      preparePool,
      commitPool,
      messagePool,
      validators
    ) {
      this.sockets = [];
      this.wallet = wallet;
      this.blockchain = blockchain;
      this.transactionPool = transactionPool;
      this.blockPool = blockPool;
      this.preparePool = preparePool;
      this.commitPool = commitPool;
      this.messagePool = messagePool;
      this.validators = validators;
    }
  
    // Creates a server on a given port
    listen() {
      const server = new WebSocket.Server({ port: P2P_PORT });
      server.on("connection", (socket, req) => {
        // console.log(`new connection from outside ${req.socket.remoteAddress}:${req.socket.remotePort} to ${P2P_PORT}`);
        this.connectSocket(socket);
        this.messageHandler(socket);
      });
      this.connectToPeers();
      // console.log(`Listening for peer to peer connection on port : ${P2P_PORT}`);
    }
  
    // connects to a given socket and registers the message handler on it
    connectSocket(socket, peer = P2P_PORT) {
      this.sockets.push(socket);
      // console.log("Socket connected", P2P_PORT, peer);
    }
  
    // connects to the peers passed in command line
    connectToPeers() {
      peers.forEach(peer => {
        const socket = new WebSocket(peer);
        socket.on("open", () => {
          console.log(`new connection from inside ${P2P_PORT} to ${peer.split(':')[2]}`);
          this.connectSocket(socket, peer);
          this.messageHandler(socket);
        });
      });
    }
  
    // broadcasts transactions
    broadcastTransaction(transaction) {
      this.sockets.forEach(socket => {
        console.log("broadcastTransaction", P2P_PORT, this.sockets.length);
        this.sendTransaction(socket, transaction);
      });
    }
  
    // sends transactions to a perticular socket
    sendTransaction(socket, transaction) {
      socket.send(
        JSON.stringify({
          type: MESSAGE_TYPE.transaction,
          transaction: transaction
        })
      );
    }
  
    // broadcasts preprepare
    broadcastPrePrepare(block) {
      this.sockets.forEach(socket => {
        this.sendPrePrepare(socket, block);
      });
    }
  
    // sends preprepare to a particular socket
    sendPrePrepare(socket, block) {
      socket.send(
        JSON.stringify({
          type: MESSAGE_TYPE.pre_prepare,
          block: block
        })
      );
    }
  
    // broadcast prepare
    broadcastPrepare(prepare) {
      this.sockets.forEach(socket => {
        this.sendPrepare(socket, prepare);
      });
    }
  
    // sends prepare to a particular socket
    sendPrepare(socket, prepare) {
      socket.send(
        JSON.stringify({
          type: MESSAGE_TYPE.prepare,
          prepare: prepare
        })
      );
    }
  
    // broadcasts commit
    broadcastCommit(commit) {
      this.sockets.forEach(socket => {
        this.sendCommit(socket, commit);
      });
    }
  
    // sends commit to a particular socket
    sendCommit(socket, commit) {
      socket.send(
        JSON.stringify({
          type: MESSAGE_TYPE.commit,
          commit: commit
        })
      );
    }
  
    // broadcasts round change
    broadcastRoundChange(message) {
      this.sockets.forEach(socket => {
        this.sendRoundChange(socket, message);
      });
    }
  
    // sends round change message to a particular socket
    sendRoundChange(socket, message) {
      socket.send(
        JSON.stringify({
          type: MESSAGE_TYPE.round_change,
          message
        })
      );
    }
  
    // handles any message sent to the current node
    messageHandler(socket) {
      // registers message handler
      socket.on("message", message => {
        if (Buffer.isBuffer(message)) {
          message = message.toString(); // Convert Buffer to string
        }
        const data = JSON.parse(message);
  
        console.log("RECEIVED", data.type, P2P_PORT);
  
        // select a particular message handler
        switch (data.type) {
          case MESSAGE_TYPE.transaction:
            // check if transactions is valid
            if (
              !this.transactionPool.transactionExists(data.transaction) &&
              this.transactionPool.verifyTransaction(data.transaction) &&
              this.validators.isValidValidator(data.transaction.from)
            ) {
              let thresholdReached = this.transactionPool.addTransaction(
                data.transaction
              );
              // send transactions to other nodes
              this.broadcastTransaction(data.transaction);
  
              // check if limit reached
              if (thresholdReached) {
                console.log("THRESHOLD REACHED, TOTAL NOW:", this.transactionPool.transactions.length, P2P_PORT);
                // check the current node is the proposer
                if (this.blockchain.getProposer() == this.wallet.getPublicKey()) {
                  console.log("PROPOSING BLOCK", P2P_PORT);
                  // if the node is the proposer, create a block and broadcast it
                  let block = this.blockchain.createBlock(
                    this.transactionPool.transactions,
                    this.wallet
                  );
                  console.log("CREATED BLOCK", { lastHash: block.lastHash, hash: block.hash , data: block.data } , P2P_PORT);
                  this.broadcastPrePrepare(block);
                }
              } else {
                console.log("Transaction Added", P2P_PORT);
              }
            }
            break;
          case MESSAGE_TYPE.pre_prepare:
            // check if block is valid
            if (
              !this.blockPool.existingBlock(data.block) &&
              this.blockchain.isValidBlock(data.block)
            ) {
              // add block to pool
              this.blockPool.addBlock(data.block);
  
              // send to other nodes
              this.broadcastPrePrepare(data.block);
  
              // create and broadcast a prepare message
              let prepare = this.preparePool.prepare(data.block, this.wallet);
              this.broadcastPrepare(prepare);
            }
            break;
          case MESSAGE_TYPE.prepare:
            // check if the prepare message is valid
            if (
              !this.preparePool.existingPrepare(data.prepare) &&
              this.preparePool.isValidPrepare(data.prepare, this.wallet) &&
              this.validators.isValidValidator(data.prepare.publicKey)
            ) {
              // add prepare message to the pool
              this.preparePool.addPrepare(data.prepare);
  
              // send to other nodes
              this.broadcastPrepare(data.prepare);
  
              // if no of prepare messages reaches minimum required
              // send commit message
              if (
                this.preparePool.list[data.prepare.blockHash].length >=
                MIN_APPROVALS
              ) {
                let commit = this.commitPool.commit(data.prepare, this.wallet);
                this.broadcastCommit(commit);
              }
            }
            break;
          case MESSAGE_TYPE.commit:
            // check the validity commit messages
            if (
              !this.commitPool.existingCommit(data.commit) &&
              this.commitPool.isValidCommit(data.commit) &&
              this.validators.isValidValidator(data.commit.publicKey)
            ) {
              // add to pool
              this.commitPool.addCommit(data.commit);
  
              // send to other nodes
              this.broadcastCommit(data.commit);
  
              // if no of commit messages reaches minimum required
              // add updated block to chain
              if (
                this.commitPool.list[data.commit.blockHash].length >=
                MIN_APPROVALS && !this.blockchain.existingBlock(data.commit.blockHash)
              ) {
                this.blockchain.addUpdatedBlock(
                  data.commit.blockHash,
                  this.blockPool,
                  this.preparePool,
                  this.commitPool
                );
                console.log('NEW BLOCK ADDED TO BLOCK CHAIN, TOTAL NOW:', this.blockchain.chain.length, P2P_PORT);
                const total = { total: this.blockchain.getTotal(), unassignedTransactions: this.transactionPool.transactions.length };
                console.log(`TOTAL:`, JSON.stringify(total));
              }
              // Send a round change message to nodes
              let message = this.messagePool.createMessage(
                this.blockchain.chain[this.blockchain.chain.length - 1].hash,
                this.wallet
              );
              // phase 1 -> use subset of validators all the time
              // phase 2 -> randomly switch between subset and all validators
              // phase 3 -> weigh towards subset more
              // phase 4 -> track faulty nodes and do not use them later
              this.broadcastRoundChange(message);
            }
            break;
  
          case MESSAGE_TYPE.round_change:
            // check the validity of the round change message
            if (
              !this.messagePool.existingMessage(data.message) &&
              this.messagePool.isValidMessage(data.message) &&
              this.validators.isValidValidator(data.message.publicKey)
            ) {
              // add to pool
              this.messagePool.addMessage(data.message);
  
              // send to other nodes
              this.broadcastRoundChange(data.message);
  
              // if enough messages are received, clear the pools
              if (
                this.messagePool.list[data.message.blockHash] && this.messagePool.list[data.message.blockHash].length >=
                MIN_APPROVALS
              ) {
                console.log("TRANSACTION POOL TO BE CLEARED, TOTAL NOW:", this.transactionPool.transactions.length, P2P_PORT);
                this.transactionPool.clear();
              }
            }
            break;
        }
      });
    }
  }
  
  module.exports = P2pserver;