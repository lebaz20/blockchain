// import the ws module
const WebSocket = require("ws");
const fs = require("fs");
const axios = require('axios');
const MESSAGE_TYPE = require("../constants/message");

// Create a write stream to your desired log file
const logStream = fs.createWriteStream("server.log", { flags: "a" }); // 'a' = append

// Redirect console.log and console.error
console.log = function (...arguments_) {
  logStream.write(`[LOG ${new Date().toISOString()}] ${arguments_.join(" ")}\n`);
  process.stdout.write(`[LOG] ${arguments_.join(" ")}\n`); // Optional: also log to terminal
};

console.error = function (...arguments_) {
  logStream.write(`[ERROR ${new Date().toISOString()}] ${arguments_.join(" ")}\n`);
  process.stderr.write(`[ERROR] ${arguments_.join(" ")}\n`);
};

// import the min approval constant which will be used to compare the count the messages
// import active subset of nodes to use in validation
const config = require("../config");
const { NODES_SUBSET, MIN_APPROVALS, SUBSET_INDEX, TRANSACTION_THRESHOLD, IS_FAULTY } = config.get();

// declare a p2p server port on which it would listen for messages
// we will pass the port through command line
const P2P_PORT = process.env.P2P_PORT || 5001;

// the neighboring nodes socket addresses will be passed in command line
// this statement splits them into an array
const peers = process.env.PEERS ? process.env.PEERS.split(",") : [];
const core = process.env.CORE;

class P2pserver {
  constructor(
    blockchain,
    transactionPool,
    wallet,
    blockPool,
    preparePool,
    commitPool,
    messagePool,
    validators,
    idaGossip
  ) {
    this.sockets = {};
    this.wallet = wallet;
    this.blockchain = blockchain;
    this.transactionPool = transactionPool;
    this.blockPool = blockPool;
    this.preparePool = preparePool;
    this.commitPool = commitPool;
    this.messagePool = messagePool;
    this.validators = validators;
    this.lastTransactionCreatedAt = undefined;
    this.idaGossip = idaGossip;
  }

  // Creates a server on a given port
  listen() {
    const server = new WebSocket.Server({ port: P2P_PORT });
    server.on("connection", (socket, request) => {
      const parsedUrl = new URL(request.url, `http://${request.headers.host}`);
      const port = parsedUrl.searchParams.get("port");
      const isFaulty = parsedUrl.searchParams.get("isFaulty");
      console.log(
        `new connection from ${port} to ${P2P_PORT}`,
      );
      this.connectSocket(socket, port, isFaulty === 'true');
      this.messageHandler(socket);
    });
    this.connectToPeers();
    this.connectToCore();

    setInterval(async () => {
      const rate = await this.blockchain.getRate(this.sockets);
      const total = this.blockchain.getTotal();
      console.log(`PEERS ${SUBSET_INDEX}`, P2P_PORT, IS_FAULTY, JSON.stringify(Object.keys(this.sockets).map((port) => ({ port, isFaulty: this.sockets[port].isFaulty}))));
      console.log(`RATE INTERVAL BROADCAST ${SUBSET_INDEX}`, JSON.stringify(rate));
      console.log(`TOTAL INTERVAL BROADCAST ${SUBSET_INDEX}`, JSON.stringify(total));
      this.broadcastRateToCore(rate, total);
    }, 60000); // every 1 minute
  }

  // connects to a given socket and registers the message handler on it
  connectSocket(socket, port, isFaulty, isCore = false) {
    if (!isCore) {
      this.sockets[port] = {
        socket,
        isFaulty
      };
      this.idaGossip.setPeerSockets(this.sockets);
    } else {
      this.coreSocket = socket;
      this.idaGossip.setCoreSocket(socket);
    }
  }

  waitForWebServer(url, retryInterval = 1000) {
    return new Promise((resolve) => {
      function checkWebServer() {
        axios
          .get(url + '/health')
          .then(() => {
            console.log(`WebServer is open: ${url}`)
            resolve(true)
            return true
          })
          .catch(() => {
            // console.log(`WebServer ${url} not available, retrying...`);
            setTimeout(checkWebServer, retryInterval + 1000)
          })
      }
  
      checkWebServer()
    })
  }

  // connects to the peers passed in command line
  async connectToPeers() {
    await Promise.all(
      peers.map((peer) =>
        this.waitForWebServer(peer.replace('ws', 'http').replace(':5', ':3'))
      )
    );
    peers.forEach((peer) => {
      const connectPeer = () => {
        const socket = new WebSocket(
        `${peer}?port=${P2P_PORT}&isFaulty=${IS_FAULTY ? 'true' : 'false'}&subsetIndex=${SUBSET_INDEX}&httpPort=${process.env.HTTP_PORT}`,
        );
        socket.on("error", (error) => {
          console.error(`Failed to connect to peer. Retrying in 5s...`, error);
          setTimeout(connectPeer, 5000);
        });
        socket.on("open", () => {
          console.log(
            `new connection from inside ${P2P_PORT} to ${peer.split(":")[2]}`,
          );
          this.connectSocket(socket, peer.split(":")[2], false);
          this.messageHandler(socket);
        });
      };
      connectPeer();
    });
  }

  async connectToCore() {
    const connectCore = () => {
      const socket = new WebSocket(
      `${core}?port=${P2P_PORT}&subsetIndex=${SUBSET_INDEX}&httpPort=${process.env.HTTP_PORT}`,
      );
      socket.on("error", (error) => {
      console.error(`Failed to connect to core. Retrying in 5s...`, error);
      setTimeout(connectCore, 5000);
      });
      socket.on("open", () => {
      console.log(
        `new connection from inside ${P2P_PORT} to ${core.split(":")[2]}`,
      );
      this.connectSocket(socket, core.split(":")[2], false, true);
      this.messageHandler(socket, true);
      });
    };
    connectCore();
  }

  // broadcasts transactions
  broadcastTransaction(senderPort, transaction) {
    this.idaGossip.sendToShardPeers({
      message: {
        type: MESSAGE_TYPE.transaction,
        port: P2P_PORT,
        transaction: transaction,
        isFaulty: IS_FAULTY
      },
      senderPort
    })
  }

  // broadcasts preprepare
  broadcastPrePrepare(senderPort, block, blocksCount, previousBlock = undefined) {
    this.idaGossip.sendToShardPeers({
      message: {
        type: MESSAGE_TYPE.pre_prepare,
        port: P2P_PORT,
        data: {
          block,
          previousBlock,
          blocksCount,
        },
      },
      chunkKey: 'data',
      senderPort
    })
  }

  // broadcast prepare
  broadcastPrepare(senderPort, prepare) {
    this.idaGossip.sendToShardPeers({
      message: {
        type: MESSAGE_TYPE.prepare,
        port: P2P_PORT,
        prepare,
      },
      chunkKey: 'prepare',
      senderPort
    })
  }

  // broadcasts commit
  broadcastCommit(senderPort, commit) {
    this.idaGossip.sendToShardPeers({
      message: {
        type: MESSAGE_TYPE.commit,
        port: P2P_PORT,
        commit,
      },
      chunkKey: 'commit',
      senderPort
    })
  }

  // broadcasts round change
  broadcastRoundChange(senderPort, message) {
    this.idaGossip.sendToShardPeers({
      message: {
        type: MESSAGE_TYPE.round_change,
        port: P2P_PORT,
        message,
      },
      chunkKey: 'message',
      senderPort
    })
  }

  // broadcasts block to core
  broadcastBlockToCore(block) {
    this.idaGossip.sendToCore({
      message: {
        type: MESSAGE_TYPE.block_to_core,
        block,
        subsetIndex: SUBSET_INDEX,
      },
      chunkKey: 'block'
    })
  }

  // broadcasts rate to core
  broadcastRateToCore(rate, total) {
    this.idaGossip.sendToCore({
      message: {
        type: MESSAGE_TYPE.rate_to_core,
        port: P2P_PORT,
        rate,
        total
      },
    })
  }

  // handles any message sent to the current node
  messageHandler(socket, isCore = false) {
    // registers message handler
    socket.on("message", (message) => {
      if (Buffer.isBuffer(message)) {
        message = message.toString(); // Convert Buffer to string
      }
      const data = JSON.parse(message);

      this.parseMessage(data, isCore);
    });
  }

  initiateBlockCreation(port, triggeredByTransaction = true) {
    this.lastTransactionCreatedAt = new Date();
    const thresholdReached = this.transactionPool.poolFull();
    // check if limit reached
    if (!IS_FAULTY && (thresholdReached || !triggeredByTransaction)) {
      console.log(
        P2P_PORT,
        "THRESHOLD REACHED, TOTAL NOW:",
        this.transactionPool.transactions.unassigned.length,
      );
      // check the current node is the proposer
      let readyToPropose = true;
      const lastUnpersistedBlock =
        this.blockPool.blocks[this.blockPool.blocks.length - 1];
      if (this.transactionPool.getInflightBlocks().length > 1) {
        readyToPropose = this.preparePool.isBlockPrepared(
          lastUnpersistedBlock,
          this.wallet,
        );
      }
      const proposerObject = this.blockchain.getProposer();
      console.log(
        P2P_PORT,
        "PROPOSE BLOCK CONDITION",
        "proposer index:", proposerObject.proposerIndex, NODES_SUBSET,
        "is proposer:", proposerObject.proposer == this.wallet.getPublicKey(),
        "is ready to propose:", readyToPropose,
        "inflight blocks:", this.transactionPool.getInflightBlocks(),
      );
      if (
        proposerObject.proposer == this.wallet.getPublicKey() &&
        readyToPropose &&
        this.transactionPool.getInflightBlocks().length <= 4
      ) {
        console.log(P2P_PORT, "PROPOSING BLOCK");
        // if the node is the proposer, create a block and broadcast it
        const previousBlock =
          this.transactionPool.getInflightBlocks().length > 1
            ? lastUnpersistedBlock
            : undefined;
        const transactionsBatch = this.transactionPool.transactions.unassigned.splice(0, TRANSACTION_THRESHOLD);
        const block = this.blockchain.createBlock(
          transactionsBatch,
          this.wallet,
          previousBlock,
        );
        console.log(P2P_PORT, "CREATED BLOCK", JSON.stringify({
          lastHash: block.lastHash,
          hash: block.hash,
          data: block.data,
        }));
        // assign block transactions to the block
        // Release assignment after x time in case block creation doesn't succeed
        this.transactionPool.assignTransactions(block);

        this.broadcastPrePrepare(
          port,
          block,
          this.blockchain.chain[SUBSET_INDEX].length,
          previousBlock,
        );
      }
    } else {
      console.log(P2P_PORT, "Transaction Threshold NOT REACHED, TOTAL UNASSIGNED NOW:", this.transactionPool.transactions.unassigned.length);
    }

    // If lastTransactionCreatedAt is more than 1 minute ago, run after timeout, else run immediately  
    // Debounce block creation: only call after timeout if not triggered by normal traffic
    clearTimeout(this._blockCreationTimeout);
    this._blockCreationTimeout = setTimeout(() => {
      const now = new Date();
      // If no new transaction has triggered initiateBlockCreation in the last 60s, call it manually
      if (
      this.lastTransactionCreatedAt &&
      now - this.lastTransactionCreatedAt >= 8 * 1000 /* 8 seconds */ && 
      this.transactionPool.transactions.unassigned.length > 0
      ) {
      this.initiateBlockCreation(P2P_PORT,false);
      }
    }, 1 * 10 * 1000); // 10 seconds
  }

  // parse message
  async parseMessage(data, isCore) {
    console.log(P2P_PORT, "RECEIVED", data.type, data.port);

    if (IS_FAULTY && ![MESSAGE_TYPE.transaction].includes(data.type)) {
      return;
    }
    // select a particular message handler
    switch (data.type) {
      case MESSAGE_TYPE.transaction:
        // check if transactions is valid
        if (
          !this.transactionPool.transactionExists(data.transaction) &&
          this.transactionPool.verifyTransaction(data.transaction) &&
          this.validators.isValidValidator(data.transaction.from)
        ) {
          if (data.port && data.port in this.sockets) {
            this.sockets[data.port].isFaulty = data.isFaulty;
          }
          this.transactionPool.addTransaction(
            data.transaction,
          );
          console.log(
            P2P_PORT,
            "TRANSACTION ADDED, TOTAL NOW:",
            this.transactionPool.transactions.unassigned.length,
          );
          // send transactions to other nodes
          this.broadcastTransaction(data.port, data.transaction);

          this.initiateBlockCreation(data.port);
        }
        break;
      case MESSAGE_TYPE.pre_prepare: {
        const { block, previousBlock, blocksCount } = data.data;
        // check if block is valid
        if (
          !this.blockPool.existingBlock(block) &&
          this.blockchain.isValidBlock(
            block,
            blocksCount,
            previousBlock,
          )
        ) {
          // add block to pool
          this.blockPool.addBlock(block);

          // assign block transactions to the block
          // Release assignment after x time in case block creation doesn't succeed
          this.transactionPool.assignTransactions(block);

          // send to other nodes
          this.broadcastPrePrepare(
            data.port,
            block,
            blocksCount,
            previousBlock,
          );

          if (block?.hash) {
            // create and broadcast a prepare message
            let prepare = this.preparePool.prepare(block, this.wallet);
            this.broadcastPrepare(data.port, prepare);
          }
        }
        break;
      }
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
          this.broadcastPrepare(data.port, data.prepare);

          // if no of prepare messages reaches minimum required
          // send commit message
          if (
            this.preparePool.list[data.prepare.blockHash].length >=
            MIN_APPROVALS
          ) {
            let commit = this.commitPool.commit(data.prepare, this.wallet);
            this.broadcastCommit(data.port, commit);
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
          this.broadcastCommit(data.port, data.commit);

          // if no of commit messages reaches minimum required
          // add updated block to chain
          if (
            this.commitPool.list[data.commit.blockHash].length >=
              MIN_APPROVALS &&
            !this.blockchain.existingBlock(data.commit.blockHash)
          ) {
            const result = await this.blockchain.addUpdatedBlock(
              data.commit.blockHash,
              this.blockPool,
              this.preparePool,
              this.commitPool,
            );
            if (result !== false) {
              this.broadcastBlockToCore(result);
              console.log(
                P2P_PORT,
                "NEW BLOCK ADDED TO BLOCK CHAIN, TOTAL NOW:",
                this.blockchain.chain[SUBSET_INDEX].length,
                data.commit.blockHash,
              );
              // Send a round change message to nodes
              let message = this.messagePool.createMessage(
                this.blockchain.chain[SUBSET_INDEX][
                  this.blockchain.chain[SUBSET_INDEX].length - 1
                ],
                this.wallet,
              );
              this.broadcastRoundChange(data.port, message);

            } else {
              console.log(
                P2P_PORT,
                "NEW BLOCK FAILED TO ADD TO BLOCK CHAIN, TOTAL STILL:",
                this.blockchain.chain[SUBSET_INDEX].length,
              );
            }
            const rate = await this.blockchain.getRate(this.sockets);
            const stats = {
              total: this.blockchain.getTotal(),
              rate,
              unassignedTransactions:
                this.transactionPool.transactions.unassigned.length,
            };
            console.log(
              P2P_PORT,
              `P2P STATS FOR #${SUBSET_INDEX}:`,
              JSON.stringify(stats),
            );
          }
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
          this.broadcastRoundChange(data.port, data.message);

          // if enough messages are received, clear the pools
          if (
            this.messagePool.list[data.message.blockHash] &&
            this.messagePool.list[data.message.blockHash].length >=
              MIN_APPROVALS
          ) {
            console.log(
              P2P_PORT,
              "TRANSACTION POOL TO BE CLEARED, TOTAL NOW:",
              this.transactionPool.transactions[data.message.blockHash]?.length,
            );
            this.transactionPool.clear(data.message.blockHash, data.message.data);
          }
        }
        break;

      case MESSAGE_TYPE.block_from_core:
        // add updated block to chain
        if (
          !this.blockchain.existingBlock(data.block.hash, data.subsetIndex) &&
          data.subsetIndex != SUBSET_INDEX &&
          isCore === true
        ) {
          this.blockchain.addBlock(data.block, data.subsetIndex);
          const rate = await this.blockchain.getRate(this.sockets);
          const stats = { total: this.blockchain.getTotal(), rate };
          console.log(
            P2P_PORT,
            `P2P STATS FOR #${SUBSET_INDEX}:`,
            JSON.stringify(stats),
          );
        }
        break;
      
      case MESSAGE_TYPE.config_from_core:
        // update config from core
        if (isCore === true) {
          data.config.forEach((item) => {
            config.set(item.key, item.value);
          });
          console.log(
            P2P_PORT,
            `CONFIG UPDATE FOR #${SUBSET_INDEX}:`,
            JSON.stringify(data.config),
          );
        }
        break;
    }
  }
}

module.exports = P2pserver;
