const WebSocket = require('ws')
const axios = require('axios')
const MESSAGE_TYPE = require('../constants/message')
const logger = require('../utils/logger')
const TIMEOUTS = require('../constants/timeouts')

const config = require('../config')
const {
  NODES_SUBSET,
  MIN_APPROVALS,
  SUBSET_INDEX,
  TRANSACTION_THRESHOLD,
  IS_FAULTY
} = config.get()

const P2P_PORT = process.env.P2P_PORT || 5001

const peers = process.env.PEERS ? process.env.PEERS.split(',') : []
const core = process.env.CORE

class P2pserver {
  // eslint-disable-next-line max-params
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
    this.sockets = {}
    this.wallet = wallet
    this.blockchain = blockchain
    this.transactionPool = transactionPool
    this.blockPool = blockPool
    this.preparePool = preparePool
    this.commitPool = commitPool
    this.messagePool = messagePool
    this.validators = validators
    this.lastTransactionCreatedAt = undefined
    this.idaGossip = idaGossip
  }

  listen() {
    const server = new WebSocket.Server({ port: P2P_PORT })
    server.on('connection', (socket, request) => {
      const parsedUrl = new URL(request.url, `http://${request.headers.host}`)
      const port = parsedUrl.searchParams.get('port')
      const isFaulty = parsedUrl.searchParams.get('isFaulty')
      logger.log(`new connection from ${port} to ${P2P_PORT}`)
      this.connectSocket(socket, port, isFaulty === 'true', false)
      this.messageHandler(socket, false)
    })
    this.connectToPeers(peers)
    this.connectToCore()

    setInterval(async () => {
      const rate = await this.blockchain.getRate(this.sockets)
      const total = this.blockchain.getTotal()
      logger.log(
        `PEERS ${SUBSET_INDEX}`,
        P2P_PORT,
        IS_FAULTY,
        JSON.stringify(
          Object.keys(this.sockets).map((port) => ({
            port,
            isFaulty: this.sockets[port].isFaulty
          }))
        )
      )
      logger.log(
        `RATE INTERVAL BROADCAST ${SUBSET_INDEX}`,
        JSON.stringify(rate)
      )
      logger.log(
        `TOTAL INTERVAL BROADCAST ${SUBSET_INDEX}`,
        JSON.stringify(total)
      )
      this.broadcastRateToCore(rate, total)
    }, TIMEOUTS.RATE_BROADCAST_INTERVAL_MS)
  }

  connectSocket(socket, port, isFaulty, isCore = false) {
    if (!isCore) {
      this.sockets[port] = {
        socket,
        isFaulty
      }
      this.idaGossip.setPeerSockets({ peers: this.sockets })
    } else {
      this.coreSocket = socket
      this.idaGossip.setCoreSocket({ core: this.coreSocket })
    }
  }

  waitForWebServer(url, retryInterval = 1000) {
    return new Promise((resolve) => {
      function checkWebServer() {
        axios
          .get(`${url}/health`)
          .then(() => {
            logger.log(`WebServer is open: ${url}`)
            resolve(true)
            return true
          })
          .catch(() => {
            setTimeout(checkWebServer, retryInterval + 1000)
          })
      }

      checkWebServer()
    })
  }

  // connects to the peers passed in command line
  async connectToPeers(nodes) {
    await Promise.all(
      nodes.map((peer) =>
        this.waitForWebServer(peer.replace('ws', 'http').replace(':5', ':3'))
      )
    )
    nodes.forEach((peer) => {
      const connectPeer = () => {
        const socket = new WebSocket(
          `${peer}?port=${P2P_PORT}&isFaulty=${IS_FAULTY ? 'true' : 'false'}&subsetIndex=${SUBSET_INDEX}&httpPort=${process.env.HTTP_PORT}`
        )
        socket.on('error', (error) => {
          logger.error(`Failed to connect to peer. Retrying in 5s...`, error)
          setTimeout(connectPeer, TIMEOUTS.PEER_RECONNECT_DELAY_MS)
        })
        socket.on('open', () => {
          logger.log(
            `new connection from inside ${P2P_PORT} to ${peer.split(':')[2]}`
          )
          this.connectSocket(socket, peer.split(':')[2], false)
          this.messageHandler(socket, false)
        })
      }
      connectPeer()
    })
  }

  async connectToCore() {
    const connectCore = () => {
      const socket = new WebSocket(
        `${core}?port=${P2P_PORT}&subsetIndex=${SUBSET_INDEX}&httpPort=${process.env.HTTP_PORT}`
      )
      socket.on('error', (error) => {
        logger.error(`Failed to connect to core. Retrying in 5s...`, error)
        setTimeout(connectCore, TIMEOUTS.PEER_RECONNECT_DELAY_MS)
      })
      socket.on('open', () => {
        logger.log(
          `new connection from inside ${P2P_PORT} to ${core.split(':')[2]}`
        )
        this.connectSocket(socket, core.split(':')[2], false, true)
        this.messageHandler(socket, true)
      })
    }
    connectCore()
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
  broadcastPrePrepare(
    senderPort,
    block,
    blocksCount,
    previousBlock = undefined
  ) {
    this.idaGossip.sendToShardPeers({
      message: {
        type: MESSAGE_TYPE.pre_prepare,
        port: P2P_PORT,
        data: {
          block,
          previousBlock,
          blocksCount
        }
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
        prepare
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
        commit
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
        message
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
        subsetIndex: SUBSET_INDEX
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
      }
    })
  }

  _handleTransaction(data) {
    logger.log(
        P2P_PORT,
        'TRANSACTION RECEIVED, TOTAL NOW:',
        JSON.stringify(data),
        this.transactionPool.transactionExists(data.transaction),
        this.transactionPool.verifyTransaction(data.transaction),
        this.validators.isValidValidator(data.transaction.from)
      )
    if (
      !this.transactionPool.transactionExists(data.transaction) &&
      this.transactionPool.verifyTransaction(data.transaction) &&
      this.validators.isValidValidator(data.transaction.from)
    ) {
      if (data.port && data.port in this.sockets) {
        this.sockets[data.port].isFaulty = data.isFaulty
      }
      this.transactionPool.addTransaction(data.transaction)
      logger.log(
        P2P_PORT,
        'TRANSACTION ADDED, TOTAL NOW:',
        this.transactionPool.transactions.unassigned.length
      )
      this.broadcastTransaction(data.port, data.transaction)
      this.initiateBlockCreation(data.port)
    }
  }

  _handlePrePrepare(data) {
    const { block, previousBlock, blocksCount } = data.data
    if (
      !this.blockPool.existingBlock(block) &&
      this.blockchain.isValidBlock(block, blocksCount, previousBlock)
    ) {
      this.blockPool.addBlock(block)
      this.transactionPool.assignTransactions(block)
      this.broadcastPrePrepare(data.port, block, blocksCount, previousBlock)

      if (block?.hash) {
        const prepare = this.preparePool.prepare(block, this.wallet)
        this.broadcastPrepare(data.port, prepare)
      }
    }
  }

  _handlePrepare(data) {
    if (
      !this.preparePool.existingPrepare(data.prepare) &&
      this.preparePool.isValidPrepare(data.prepare, this.wallet) &&
      this.validators.isValidValidator(data.prepare.publicKey)
    ) {
      this.preparePool.addPrepare(data.prepare)
      this.broadcastPrepare(data.port, data.prepare)

      if (
        this.preparePool.list[data.prepare.blockHash].length >= MIN_APPROVALS
      ) {
        const commit = this.commitPool.commit(data.prepare, this.wallet)
        this.broadcastCommit(data.port, commit)
      }
    }
  }

  async _handleCommit(data) {
    if (
      !this.commitPool.existingCommit(data.commit) &&
      this.commitPool.isValidCommit(data.commit) &&
      this.validators.isValidValidator(data.commit.publicKey)
    ) {
      this.commitPool.addCommit(data.commit)
      this.broadcastCommit(data.port, data.commit)

      const commitReached =
        this.commitPool.list[data.commit.blockHash].length >= MIN_APPROVALS
      const blockNotInChain = !this.blockchain.existingBlock(
        data.commit.blockHash
      )

      if (commitReached && blockNotInChain) {
        const result = await this.blockchain.addUpdatedBlock(
          data.commit.blockHash,
          this.blockPool,
          this.preparePool,
          this.commitPool
        )
        if (result !== false) {
          this.broadcastBlockToCore(result)
          logger.log(
            P2P_PORT,
            'NEW BLOCK ADDED TO BLOCK CHAIN, TOTAL NOW:',
            this.blockchain.chain[SUBSET_INDEX].length,
            data.commit.blockHash
          )
          const message = this.messagePool.createMessage(
            this.blockchain.chain[SUBSET_INDEX][
              this.blockchain.chain[SUBSET_INDEX].length - 1
            ],
            this.wallet
          )
          this.broadcastRoundChange(data.port, message)
        } else {
          logger.error(
            P2P_PORT,
            'NEW BLOCK FAILED TO ADD TO BLOCK CHAIN, TOTAL STILL:',
            this.blockchain.chain[SUBSET_INDEX].length
          )
        }
        const rate = await this.blockchain.getRate(this.sockets)
        const stats = {
          total: this.blockchain.getTotal(),
          rate,
          unassignedTransactions:
            this.transactionPool.transactions.unassigned.length
        }
        logger.log(
          P2P_PORT,
          `P2P STATS FOR #${SUBSET_INDEX}:`,
          JSON.stringify(stats)
        )
      }
    }
  }

  _handleRoundChange(data) {
    if (
      !this.messagePool.existingMessage(data.message) &&
      this.messagePool.isValidMessage(data.message) &&
      this.validators.isValidValidator(data.message.publicKey)
    ) {
      this.messagePool.addMessage(data.message)
      this.broadcastRoundChange(data.port, data.message)

      if (
        this.messagePool.list[data.message.blockHash] &&
        this.messagePool.list[data.message.blockHash].length >= MIN_APPROVALS
      ) {
        logger.log(
          P2P_PORT,
          'TRANSACTION POOL TO BE CLEARED, TOTAL NOW:',
          this.transactionPool.transactions[data.message.blockHash]?.length
        )
        this.transactionPool.clear(data.message.blockHash, data.message.data)
      }
    }
  }

  async _handleBlockFromCore(data, isCore) {
    const blockNotInChain = !this.blockchain.existingBlock(
      data.block.hash,
      data.subsetIndex
    )
    const isDifferentShard = data.subsetIndex !== SUBSET_INDEX

    if (blockNotInChain && isDifferentShard && isCore === true) {
      this.blockchain.addBlock(data.block, data.subsetIndex)
      const rate = await this.blockchain.getRate(this.sockets)
      const stats = { total: this.blockchain.getTotal(), rate }
      logger.log(
        P2P_PORT,
        `P2P STATS FOR #${SUBSET_INDEX}:`,
        JSON.stringify(stats)
      )
    }
  }

  _handleConfigFromCore(data, isCore) {
    if (isCore === true) {
      data.config.forEach((item) => {
        config.set(item.key, item.value)
      })
      logger.log(
        P2P_PORT,
        `CONFIG UPDATE FOR #${SUBSET_INDEX}:`,
        JSON.stringify(data.config)
      )
    }
  }

  messageHandler(socket, isCore = false) {
    socket.on('message', (message) => {
      try {
        if (Buffer.isBuffer(message)) {
          message = message.toString()
        }
        const data = JSON.parse(message)
        const processedData = this.idaGossip.handleChunk(data)
        this.parseMessage(processedData, isCore)
      } catch (error) {
        logger.error('Failed to parse message:', error.message)
      }
    })
  }

  _scheduleTimeoutBlockCreation() {
    clearTimeout(this._blockCreationTimeout)
    this._blockCreationTimeout = setTimeout(() => {
      const now = new Date()
      const isInactive =
        this.lastTransactionCreatedAt &&
        now - this.lastTransactionCreatedAt >=
          TIMEOUTS.TRANSACTION_INACTIVITY_THRESHOLD_MS
      const hasTransactions =
        this.transactionPool.transactions.unassigned.length > 0
      const transactionCount =
        this.transactionPool.transactions.unassigned.length
      const proposerObject = this.blockchain.getProposer()
      const isProposer = proposerObject.proposer === this.wallet.getPublicKey()

      // ============================================================================
      // TRANSACTION REDISTRIBUTION MECHANISM (TIMEOUT-BASED WORKAROUND)
      // ============================================================================
      // PROBLEM: In PBFT, only the designated proposer can create blocks. However,
      // load balancers distribute client requests across all nodes. If the proposer
      // doesn't receive enough transactions directly, no blocks are created despite
      // high overall transaction volume across other nodes.
      //
      // SOLUTION: Non-proposer nodes with >= 50 transactions periodically re-broadcast
      // them to the network every 10 seconds, increasing the chance the proposer receives them.
      //
      // WHY THIS CAUSES ISSUES - CRITICAL TRADE-OFFS:
      // ============================================================================
      // 1. NETWORK OVERHEAD
      //    - Same transactions broadcast multiple times by different nodes
      //    - Bandwidth waste proportional to: (number of non-proposer nodes) * (tx count)
      //    - In 4-node network: 3 nodes might re-broadcast 50 txs each = 150 duplicate messages
      //
      // 2. CPU OVERHEAD
      //    - Each node must re-process duplicate transactions
      //    - Though filtered by transactionExists() check, still CPU cycles wasted
      //    - Can impact overall throughput under high load
      //
      // 3. BREAKS PURE DECENTRALIZATION
      //    - Creates implicit dependency on proposer role availability
      //    - If proposer is down/slow, entire network stalls
      //    - Original PBFT design assumes all nodes receive all transactions
      //
      // 4. TIMING ISSUES & RACE CONDITIONS
      //    - Proposer rotation happens every minute based on block hash
      //    - Might rotate proposer before redistributed txs reach old proposer
      //    - Multiple non-proposers might redistribute simultaneously → message storms
      //
      // 5. DOES NOT SCALE
      //    - With more nodes, more duplicates broadcast
      //    - Network bandwidth grows O(n²) instead of O(n)
      //    - Better solutions needed for production: consistent hashing, mempool sync, etc.
      //
      // BETTER ALTERNATIVES (NOT IMPLEMENTED HERE):
      // ============================================================================
      // A) CONSISTENT HASHING: Route client requests to proposer based on hash
      // B) MEMPOOL SYNC: Explicit transaction pool synchronization protocol
      // C) MULTIPLE PROPOSERS: Allow concurrent block proposals (requires consensus changes)
      // D) GOSSIP PROTOCOL: Structured propagation ensuring all nodes receive all txs
      //
      // This timeout-based approach is a WORKAROUND for load balancing issues, not
      // a proper architectural solution. It sacrifices efficiency for availability.
      // ============================================================================
      if (!isProposer && transactionCount >= TRANSACTION_THRESHOLD / 2) {
        logger.log(
          P2P_PORT,
          'NON-PROPOSER WITH MANY TXs - Redistributing to network:',
          transactionCount
        )
        // Re-broadcast accumulated transactions to ensure proposer receives them
        const txToRedistribute =
          this.transactionPool.transactions.unassigned.slice(0, 50)
        txToRedistribute.forEach((tx) => {
          this.broadcastTransaction(P2P_PORT, tx)
        })
      }

      if (isInactive && hasTransactions) {
        this.initiateBlockCreation(P2P_PORT, false)
      }
    }, TIMEOUTS.BLOCK_CREATION_TIMEOUT_MS)
  }

  _canProposeBlock() {
    const lastUnpersistedBlock =
      this.blockPool.blocks[this.blockPool.blocks.length - 1]
    const inflightBlocks = this.transactionPool.getInflightBlocks()

    if (inflightBlocks.length > 1) {
      return this.preparePool.isBlockPrepared(lastUnpersistedBlock, this.wallet)
    }
    return true
  }

  _createAndBroadcastBlock(port) {
    const lastUnpersistedBlock =
      this.blockPool.blocks[this.blockPool.blocks.length - 1]
    const inflightBlocks = this.transactionPool.getInflightBlocks()
    const previousBlock =
      inflightBlocks.length > 1 ? lastUnpersistedBlock : undefined
    const transactionsBatch =
      this.transactionPool.transactions.unassigned.splice(
        0,
        TRANSACTION_THRESHOLD
      )
    const block = this.blockchain.createBlock(
      transactionsBatch,
      this.wallet,
      previousBlock
    )

    logger.log(
      P2P_PORT,
      'CREATED BLOCK',
      JSON.stringify({
        lastHash: block.lastHash,
        hash: block.hash,
        data: block.data
      })
    )

    this.transactionPool.assignTransactions(block)
    this.broadcastPrePrepare(
      port,
      block,
      this.blockchain.chain[SUBSET_INDEX].length,
      previousBlock
    )
  }

  initiateBlockCreation(port, _triggeredByTransaction = true) {
    this.lastTransactionCreatedAt = new Date()
    const thresholdReached = this.transactionPool.poolFull()
    if (!IS_FAULTY && (thresholdReached || !_triggeredByTransaction)) {
      logger.log(
        P2P_PORT,
        'THRESHOLD REACHED, TOTAL NOW:',
        this.transactionPool.transactions.unassigned.length
      )
      const readyToPropose = this._canProposeBlock()
      const proposerObject = this.blockchain.getProposer()
      const inflightBlocks = this.transactionPool.getInflightBlocks()
      const isProposer = proposerObject.proposer === this.wallet.getPublicKey()
      const canCreateBlock =
        isProposer && readyToPropose && inflightBlocks.length <= 4

      logger.log(
        P2P_PORT,
        'PROPOSE BLOCK CONDITION',
        'proposer index:',
        proposerObject.proposerIndex,
        NODES_SUBSET,
        'is proposer:',
        isProposer,
        'is ready to propose:',
        readyToPropose,
        'inflight blocks:',
        inflightBlocks
      )

      if (canCreateBlock) {
        logger.log(P2P_PORT, 'PROPOSING BLOCK')
        this._createAndBroadcastBlock(port)
      }
    } else {
      logger.log(
        P2P_PORT,
        'Transaction Threshold NOT REACHED, TOTAL UNASSIGNED NOW:',
        this.transactionPool.transactions.unassigned.length
      )
    }

    this._scheduleTimeoutBlockCreation()
  }

  async parseMessage(data, isCore) {
    logger.log(P2P_PORT, 'RECEIVED', data.type, data.port)

    if (IS_FAULTY && ![MESSAGE_TYPE.transaction].includes(data.type)) {
      return
    }

    switch (data.type) {
      case MESSAGE_TYPE.transaction:
        this._handleTransaction(data)
        break
      case MESSAGE_TYPE.pre_prepare:
        this._handlePrePrepare(data)
        break
      case MESSAGE_TYPE.prepare:
        this._handlePrepare(data)
        break
      case MESSAGE_TYPE.commit:
        await this._handleCommit(data)
        break
      case MESSAGE_TYPE.round_change:
        this._handleRoundChange(data)
        break
      case MESSAGE_TYPE.block_from_core:
        await this._handleBlockFromCore(data, isCore)
        break
      case MESSAGE_TYPE.config_from_core:
        this._handleConfigFromCore(data, isCore)
        break
    }
  }
}

module.exports = P2pserver
