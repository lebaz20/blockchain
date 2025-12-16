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
const { NODES_SUBSET, MIN_APPROVALS, SUBSET_INDEX, TRANSACTION_THRESHOLD, BLOCK_THRESHOLD, IS_FAULTY, CORE, PEERS, COMMITTEE_PEERS } = config.get();

// declare a p2p server port on which it would listen for messages
// we will pass the port through command line
const P2P_PORT = process.env.P2P_PORT || 5001;

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
    this.sockets = {
      peers: {},
      committeePeers: {}
    };
    this.coreSocket = {
      core: null,
      committeeCore: null
    };
    this.wallet = wallet;
    this.blockchain = blockchain;
    this.transactionPool = transactionPool;
    this.blockPool = blockPool;
    this.preparePool = preparePool;
    this.commitPool = commitPool;
    this.messagePool = messagePool;
    this.validators = validators;
    this.lastTransactionCreatedAt = undefined;
    this.lastCommitteeTransactionCreatedAt = undefined;
    this.idaGossip = idaGossip;
  }

  // Creates a server on a given port
  listen() {
    const server = new WebSocket.Server({ port: P2P_PORT });
    server.on("connection", (socket, request) => {
      const parsedUrl = new URL(request.url, `http://${request.headers.host}`);
      const port = parsedUrl.searchParams.get("port");
      const isFaulty = parsedUrl.searchParams.get("isFaulty");
      const isCommittee = parsedUrl.searchParams.get("isCommittee");
      const isCommitteeFlag = isCommittee === 'true'
      console.log(
        `new connection from ${port} to ${P2P_PORT}`,
      );
      this.connectSocket(socket, port, isFaulty === 'true', false, isCommitteeFlag);
      this.messageHandler(socket, false, isCommitteeFlag);
    });
    this.connectToPeers();
    this.connectToCore(false);
    if (COMMITTEE_PEERS.length > 0) {
      this.connectToCommitteePeers();
      this.connectToCore(true);
    }

    setInterval(async () => {
      const rate = await this.blockchain.getRate(this.sockets.peers);
      const total = this.blockchain.getTotal();
      console.log(`PEERS ${SUBSET_INDEX}`, P2P_PORT, IS_FAULTY, JSON.stringify(Object.keys(this.sockets.peers).map((port) => ({ port, isFaulty: this.sockets.peers[port].isFaulty}))));
      console.log(`COMMITTEE PEERS`, P2P_PORT, JSON.stringify(Object.keys(this.sockets.committeePeers).map((port) => ({ port }))));
      console.log(`RATE INTERVAL BROADCAST ${SUBSET_INDEX}`, JSON.stringify(rate));
      console.log(`TOTAL INTERVAL BROADCAST ${SUBSET_INDEX}`, JSON.stringify(total));
      this.broadcastRateToCore(rate, total);
    }, 60000); // every 1 minute
  }

  // connects to a given socket and registers the message handler on it
  connectSocket(socket, port, isFaulty, isCore = false, isCommittee = false) {
    if (!isCore) {
      if (isCommittee) {
        this.sockets.committeePeers[port] = {
          socket,
          isFaulty
        };
      } else {
        this.sockets.peers[port] = {
          socket,
          isFaulty
        };
      }
      this.idaGossip.setPeerSockets({ peers: this.sockets.peers, committeePeers: this.sockets.committeePeers });
    } else {
      if (isCommittee) {
        this.coreSocket.committeeCore = socket;
      } else {
        this.coreSocket.core = socket;
      }
      this.idaGossip.setCoreSocket({ core: this.coreSocket.core, committeeCore: this.coreSocket.committeeCore });
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
      PEERS.map((peer) =>
        this.waitForWebServer(peer.replace('ws', 'http').replace(':5', ':3'))
      )
    );
    PEERS.forEach((peer) => {
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
          this.connectSocket(socket, peer.split(":")[2], false, false, false);
          this.messageHandler(socket, false, false);
        });
      };
      connectPeer();
    });
  }

  async connectToCommitteePeers() {
    await Promise.all(
      COMMITTEE_PEERS.map((committeePeer) =>
        this.waitForWebServer(committeePeer.replace('ws', 'http').replace(':5', ':3'))
      )
    );
    COMMITTEE_PEERS.forEach((committeePeer) => {
      const connectCommitteePeer = () => {
        const socket = new WebSocket(
        `${committeePeer}?port=${P2P_PORT}&isFaulty=${IS_FAULTY ? 'true' : 'false'}&isCommittee=true&subsetIndex=${SUBSET_INDEX}&httpPort=${process.env.HTTP_PORT}`,
        );
        socket.on("error", (error) => {
          console.error(`Failed to connect to committee peer. Retrying in 5s...`, error);
          setTimeout(connectCommitteePeer, 5000);
        });
        socket.on("open", () => {
          console.log(
            `new connection from inside ${P2P_PORT} to ${committeePeer.split(":")[2]}`,
          );
          this.connectSocket(socket, committeePeer.split(":")[2], false, false, true);
          this.messageHandler(socket, false, true);
        });
      };
      connectCommitteePeer();
    });
  }

  async connectToCore(isCommittee = false) {
    const connectCore = () => {
      const socket = new WebSocket(
      `${CORE}?port=${P2P_PORT}&isCommittee=${isCommittee ? 'true' : 'false'}&subsetIndex=${SUBSET_INDEX}&httpPort=${process.env.HTTP_PORT}`,
      );
      socket.on("error", (error) => {
      console.error(`Failed to connect to core. Retrying in 5s...`, error);
      setTimeout(connectCore, 5000);
      });
      socket.on("open", () => {
      console.log(
        `new connection from inside ${P2P_PORT} to ${CORE.split(":")[2]}`,
      );
      this.connectSocket(socket, CORE.split(":")[2], false, true, isCommittee);
      this.messageHandler(socket, true, isCommittee);
      });
    };
    connectCore();
  }

  // broadcasts transactions
  broadcastTransaction(senderPort, transaction, isCommittee = false) {
    this.idaGossip.sendToShardPeers({
      message: {
        type: MESSAGE_TYPE.transaction,
        port: P2P_PORT,
        transaction: transaction,
        isFaulty: IS_FAULTY
      },
      socketsKey: isCommittee ? 'committeePeers' : 'peers',
      senderPort
    })
  }

  // broadcasts preprepare
  broadcastPrePrepare(senderPort, block, blocksCount, previousBlock = undefined, isCommittee = false) {
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
      socketsKey: isCommittee ? 'committeePeers' : 'peers',
      senderPort
    })
  }

  // broadcast prepare
  broadcastPrepare(senderPort, prepare, isCommittee = false) {
    this.idaGossip.sendToShardPeers({
      message: {
        type: MESSAGE_TYPE.prepare,
        port: P2P_PORT,
        prepare,
      },
      chunkKey: 'prepare',
      socketsKey: isCommittee ? 'committeePeers' : 'peers',
      senderPort
    })
  }

  // broadcasts commit
  broadcastCommit(senderPort, commit, isCommittee = false) {
    this.idaGossip.sendToShardPeers({
      message: {
        type: MESSAGE_TYPE.commit,
        port: P2P_PORT,
        commit,
      },
      chunkKey: 'commit',
      socketsKey: isCommittee ? 'committeePeers' : 'peers',
      senderPort
    })
  }

  // broadcasts round change
  broadcastRoundChange(senderPort, message, isCommittee = false) {
    this.idaGossip.sendToShardPeers({
      message: {
        type: MESSAGE_TYPE.round_change,
        port: P2P_PORT,
        message,
      },
      chunkKey: 'message',
      socketsKey: isCommittee ? 'committeePeers' : 'peers',
      senderPort
    })
  }

  // broadcasts block to core
  broadcastBlockToCore(block, isCommittee = false) {
    this.idaGossip.sendToCore({
      message: {
        type: MESSAGE_TYPE.block_to_core,
        block,
        subsetIndex: SUBSET_INDEX,
      },
      chunkKey: 'block',
      socketsKey: isCommittee ? 'committeeCore' : 'core',
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
  messageHandler(socket, isCore = false, isCommittee = false) {
    // registers message handler
    socket.on("message", (message) => {
      if (Buffer.isBuffer(message)) {
        message = message.toString(); // Convert Buffer to string
      }
      const data = JSON.parse(message);
      const processedData = this.idaGossip.handleChunk(data);
      this.parseMessage(processedData, isCore, isCommittee);
    });
  }

  initiateBlockCreation(port, triggeredByTransaction = true, isCommittee = false) {
    if (isCommittee) {
      this.lastCommitteeTransactionCreatedAt = new Date();
    } else {
      this.lastTransactionCreatedAt = new Date();
    }
    const thresholdReached = this.transactionPool.poolFull(isCommittee);
    // check if limit reached
    if (!IS_FAULTY && (thresholdReached || !triggeredByTransaction)) {
      console.log(
        P2P_PORT,
        "THRESHOLD REACHED, TOTAL NOW:",
        isCommittee ? this.transactionPool.committeeTransactions.unassigned.length : this.transactionPool.transactions.unassigned.length,
      );
      // check the current node is the proposer
      let readyToPropose = true;
      const blocksPool = isCommittee ? this.blockPool.committeeBlocks : this.blockPool.blocks;
      const lastUnpersistedBlock =
        blocksPool[blocksPool.length - 1];
      if (this.transactionPool.getInflightBlocks(undefined, isCommittee).length > 1) {
        readyToPropose = this.preparePool.isBlockPrepared(
          lastUnpersistedBlock,
          this.wallet,
          isCommittee
        );
      }
      const proposerObject = this.blockchain.getProposer(undefined, isCommittee);
      console.log(
        P2P_PORT,
        "PROPOSE BLOCK CONDITION",
        "proposer index:", proposerObject.proposerIndex, NODES_SUBSET,
        "is proposer:", proposerObject.proposer == this.wallet.getPublicKey(),
        "is ready to propose:", readyToPropose,
        "inflight blocks:", this.transactionPool.getInflightBlocks(undefined, isCommittee),
      );
      if (
        proposerObject.proposer == this.wallet.getPublicKey() &&
        readyToPropose &&
        this.transactionPool.getInflightBlocks(undefined, isCommittee).length <= 4
      ) {
        console.log(P2P_PORT, "PROPOSING BLOCK");
        // if the node is the proposer, create a block and broadcast it
        const previousBlock =
          this.transactionPool.getInflightBlocks(undefined, isCommittee).length > 1
            ? lastUnpersistedBlock
            : undefined;
        const transactionsBatch = isCommittee ? this.transactionPool.committeeTransactions.unassigned.splice(0, BLOCK_THRESHOLD) : this.transactionPool.transactions.unassigned.splice(0, TRANSACTION_THRESHOLD);
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
        this.transactionPool.assignTransactions(block, isCommittee);

        this.broadcastPrePrepare(
          port,
          block,
          isCommittee ? this.blockchain.committeeChain.length : this.blockchain.chain[SUBSET_INDEX].length,
          previousBlock,
          isCommittee
        );
      }
    } else {
      console.log(P2P_PORT, "Transaction Threshold NOT REACHED, TOTAL UNASSIGNED NOW:", isCommittee ? this.transactionPool.committeeTransactions.unassigned.length : this.transactionPool.transactions.unassigned.length);
    }

    // If lastTransactionCreatedAt is more than 1 minute ago, run after timeout, else run immediately  
    // Debounce block creation: only call after timeout if not triggered by normal traffic
    clearTimeout(this._blockCreationTimeout);
    this._blockCreationTimeout = setTimeout(() => {
      const now = new Date();
      if (isCommittee) {
        if (
          this.lastCommitteeTransactionCreatedAt &&
          now - this.lastCommitteeTransactionCreatedAt >= 8 * 1000 /* 8 seconds */ && 
          this.transactionPool.committeeTransactions.unassigned.length > 0
        ) {
          this.initiateBlockCreation(P2P_PORT,false, true);
        }
      } else {
        // If no new transaction has triggered initiateBlockCreation in the last 60s, call it manually
        if (
          this.lastTransactionCreatedAt &&
          now - this.lastTransactionCreatedAt >= 8 * 1000 /* 8 seconds */ && 
          this.transactionPool.transactions.unassigned.length > 0
        ) {
          this.initiateBlockCreation(P2P_PORT,false, false);
        }
      }
    }, 1 * 10 * 1000); // 10 seconds
  }

  // parse message
  async parseMessage(data, isCore, isCommittee = false) {
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
          if (data.port && data.port in this.sockets.peers) {
            this.sockets.peers[data.port].isFaulty = data.isFaulty;
          }
          this.transactionPool.addTransaction(
            data.transaction,
            isCommittee
          );
          console.log(
            P2P_PORT,
            "TRANSACTION ADDED, TOTAL NOW:",
            isCommittee ? this.transactionPool.committeeTransactions.unassigned.length : this.transactionPool.transactions.unassigned.length,
          );
          // send transactions to other nodes
          this.broadcastTransaction(data.port, data.transaction, isCommittee);

          this.initiateBlockCreation(data.port, false, isCommittee);
        }
        break;
      case MESSAGE_TYPE.pre_prepare: {
        const { block, previousBlock, blocksCount } = data.data;
        // check if block is valid
        if (
          !this.blockPool.existingBlock(block, isCommittee) &&
          this.blockchain.isValidBlock(
            block,
            blocksCount,
            previousBlock,
            isCommittee
          )
        ) {
          // add block to pool
          this.blockPool.addBlock(block, isCommittee);

          // assign block transactions to the block
          // Release assignment after x time in case block creation doesn't succeed
          this.transactionPool.assignTransactions(block, isCommittee);
          // send to other nodes
          this.broadcastPrePrepare(
            data.port,
            block,
            blocksCount,
            previousBlock,
            isCommittee
          );

          if (block?.hash) {
            // create and broadcast a prepare message
            let prepare = this.preparePool.prepare(block, this.wallet, isCommittee);
            this.broadcastPrepare(data.port, prepare, isCommittee);
          }
        }
        break;
      }
      case MESSAGE_TYPE.prepare:
        // check if the prepare message is valid
        if (
          !this.preparePool.existingPrepare(data.prepare, isCommittee) &&
          this.preparePool.isValidPrepare(data.prepare, this.wallet) &&
          this.validators.isValidValidator(data.prepare.publicKey)
        ) {
          // add prepare message to the pool
          this.preparePool.addPrepare(data.prepare, isCommittee);

          // send to other nodes
          this.broadcastPrepare(data.port, data.prepare, isCommittee);

          if (isCommittee) {
            if (
              this.preparePool.committeeList[data.prepare.blockHash].length >=
              MIN_APPROVALS
            ) {
              let commit = this.commitPool.commit(data.prepare, this.wallet, isCommittee);
              this.broadcastCommit(data.port, commit, isCommittee);
            }
          } else {
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
        }
        break;
      case MESSAGE_TYPE.commit:
        // check the validity commit messages
        if (
          !this.commitPool.existingCommit(data.commit, isCommittee) &&
          this.commitPool.isValidCommit(data.commit) &&
          this.validators.isValidValidator(data.commit.publicKey)
        ) {
          // add to pool
          this.commitPool.addCommit(data.commit, isCommittee);

          // send to other nodes
          this.broadcastCommit(data.port, data.commit, isCommittee);

          // if no of commit messages reaches minimum required
          // add updated block to chain
          if (
            this.commitPool.getList(data.commit.blockHash, isCommittee).length >=
              MIN_APPROVALS &&
            !this.blockchain.existingBlock(data.commit.blockHash, isCommittee)
          ) {
            const result = await this.blockchain.addUpdatedBlock(
              data.commit.blockHash,
              this.blockPool,
              this.preparePool,
              this.commitPool,
              isCommittee
            );
            if (result !== false) {
              this.broadcastBlockToCore(result, isCommittee);
              console.log(
                P2P_PORT,
                "NEW BLOCK ADDED TO BLOCK CHAIN, TOTAL NOW:",
                isCommittee ? this.blockchain.committeeChain.length : this.blockchain.chain[SUBSET_INDEX].length,
                data.commit.blockHash,
              );
              // Send a round change message to nodes
              let message = this.messagePool.createMessage(
                isCommittee ? this.blockchain.committeeChain[this.blockchain.committeeChain.length - 1] : this.blockchain.chain[SUBSET_INDEX][this.blockchain.chain[SUBSET_INDEX].length - 1],
                this.wallet,
              );
              this.broadcastRoundChange(data.port, message, isCommittee);

            } else {
              console.log(
                P2P_PORT,
                "NEW BLOCK FAILED TO ADD TO BLOCK CHAIN, TOTAL STILL:",
                isCommittee ? this.blockchain.committeeChain.length : this.blockchain.chain[SUBSET_INDEX].length,
              );
            }
            if (!isCommittee) {
              const rate = await this.blockchain.getRate(this.sockets.peers);
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
        }
        break;

      case MESSAGE_TYPE.round_change:
        // check the validity of the round change message
        if (
          !this.messagePool.existingMessage(data.message, isCommittee) &&
          this.messagePool.isValidMessage(data.message) &&
          this.validators.isValidValidator(data.message.publicKey)
        ) {
          // add to pool
          this.messagePool.addMessage(data.message, isCommittee);

          // send to other nodes
          this.broadcastRoundChange(data.port, data.message, isCommittee);

          // if enough messages are received, clear the pools
          if (
            (isCommittee ? this.messagePool.committeeList[data.message.blockHash] : this.messagePool.list[data.message.blockHash]) &&
            (isCommittee ? this.messagePool.committeeList[data.message.blockHash] : this.messagePool.list[data.message.blockHash]).length >=
              MIN_APPROVALS
          ) {
            console.log(
              P2P_PORT,
              "TRANSACTION POOL TO BE CLEARED, TOTAL NOW:",
              (isCommittee ? this.transactionPool.committeeTransactions[data.message.blockHash] : this.transactionPool.transactions[data.message.blockHash])?.length,
            );
            this.transactionPool.clear(data.message.blockHash, data.message.data, isCommittee);
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
          if (!isCommittee) {
            this.blockchain.addBlock(data.block, data.subsetIndex);
            const rate = await this.blockchain.getRate(this.sockets.peers);
            const stats = { total: this.blockchain.getTotal(), rate };
            console.log(
              P2P_PORT,
              `P2P STATS FOR #${SUBSET_INDEX}:`,
              JSON.stringify(stats),
            );
          } else {
            const transaction = this.wallet.createTransaction({
              data: data.block.data,
              subsetIndex: data.subsetIndex,
            })
            if (
              !this.transactionPool.transactionExists(transaction, isCommittee) &&
              this.transactionPool.verifyTransaction(transaction) &&
              this.validators.isValidValidator(transaction.from)
            ) {
              this.transactionPool.addTransaction(
                transaction,
                isCommittee
              );
              console.log(
                P2P_PORT,
                "COMMITTEE TRANSACTION ADDED, TOTAL NOW:",
                this.transactionPool.committeeTransactions.unassigned.length,
              );
              // send transactions to other nodes
              this.broadcastTransaction(data.port, transaction, isCommittee);
              this.initiateBlockCreation(data.port, true, isCommittee);
            }
          }
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
