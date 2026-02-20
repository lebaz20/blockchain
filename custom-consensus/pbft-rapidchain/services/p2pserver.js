const WebSocket = require('ws')
const axios = require('axios')
const MESSAGE_TYPE = require('../constants/message')
const TIMEOUTS = require('../constants/timeouts')
const logger = require('../utils/logger')

const config = require('../config')
const {
  NODES_SUBSET,
  MIN_APPROVALS,
  SUBSET_INDEX,
  TRANSACTION_THRESHOLD,
  BLOCK_THRESHOLD,
  IS_FAULTY,
  CORE,
  PEERS,
  COMMITTEE_PEERS
} = config.get()

const P2P_PORT = process.env.P2P_PORT || 5001

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
    this.sockets = {
      peers: {},
      committeePeers: {}
    }
    this.coreSocket = {
      core: null,
      committeeCore: null
    }
    this.wallet = wallet
    this.blockchain = blockchain
    this.transactionPool = transactionPool
    this.blockPool = blockPool
    this.preparePool = preparePool
    this.commitPool = commitPool
    this.messagePool = messagePool
    this.validators = validators
    this.lastTransactionCreatedAt = undefined
    this.lastCommitteeTransactionCreatedAt = undefined
    this.idaGossip = idaGossip
  }

  listen() {
    const server = new WebSocket.Server({ port: P2P_PORT })
    server.on('connection', (socket, request) => {
      const parsedUrl = new URL(request.url, `http://${request.headers.host}`)
      const port = parsedUrl.searchParams.get('port')
      const isFaulty = parsedUrl.searchParams.get('isFaulty')
      const isCommittee = parsedUrl.searchParams.get('isCommittee')
      const isCommitteeFlag = isCommittee === 'true'
      logger.log(`new connection from ${port} to ${P2P_PORT}`)
      this.connectSocket(
        socket,
        port,
        isFaulty === 'true',
        false,
        isCommitteeFlag
      )
      this.messageHandler(socket, false, isCommitteeFlag)
    })
    this.connectToPeers()
    this.connectToCore(false)
    if (COMMITTEE_PEERS.length > 0) {
      this.connectToCommitteePeers()
      this.connectToCore(true)
    }

    setInterval(async () => {
      const rate = await this.blockchain.getRate(this.sockets.peers)
      const total = this.blockchain.getTotal()
      logger.log(
        `PEERS ${SUBSET_INDEX}`,
        P2P_PORT,
        IS_FAULTY,
        JSON.stringify(
          Object.keys(this.sockets.peers).map((port) => ({
            port,
            isFaulty: this.sockets.peers[port].isFaulty
          }))
        )
      )
      logger.log(
        `COMMITTEE PEERS`,
        P2P_PORT,
        JSON.stringify(
          Object.keys(this.sockets.committeePeers).map((port) => ({ port }))
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

  // eslint-disable-next-line max-params
  connectSocket(socket, port, isFaulty, isCore = false, isCommittee = false) {
    if (!isCore) {
      if (isCommittee) {
        this.sockets.committeePeers[port] = {
          socket,
          isFaulty
        }
      } else {
        this.sockets.peers[port] = {
          socket,
          isFaulty
        }
      }
      this.idaGossip.setPeerSockets({
        peers: this.sockets.peers,
        committeePeers: this.sockets.committeePeers
      })
    } else {
      if (isCommittee) {
        this.coreSocket.committeeCore = socket
      } else {
        this.coreSocket.core = socket
      }
      this.idaGossip.setCoreSocket({
        core: this.coreSocket.core,
        committeeCore: this.coreSocket.committeeCore
      })
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
            setTimeout(
              checkWebServer,
              retryInterval + TIMEOUTS.HEALTH_CHECK_RETRY_MS
            )
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
    )
    PEERS.forEach((peer) => {
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
          this.connectSocket(socket, peer.split(':')[2], false, false, false)
          this.messageHandler(socket, false, false)
        })
      }
      connectPeer()
    })
  }

  async connectToCommitteePeers() {
    await Promise.all(
      COMMITTEE_PEERS.map((committeePeer) =>
        this.waitForWebServer(
          committeePeer.replace('ws', 'http').replace(':5', ':3')
        )
      )
    )
    COMMITTEE_PEERS.forEach((committeePeer) => {
      const connectCommitteePeer = () => {
        const socket = new WebSocket(
          `${committeePeer}?port=${P2P_PORT}&isFaulty=${IS_FAULTY ? 'true' : 'false'}&isCommittee=true&subsetIndex=${SUBSET_INDEX}&httpPort=${process.env.HTTP_PORT}`
        )
        socket.on('error', (error) => {
          logger.error(
            `Failed to connect to committee peer. Retrying in 5s...`,
            error
          )
          setTimeout(connectCommitteePeer, TIMEOUTS.PEER_RECONNECT_DELAY_MS)
        })
        socket.on('open', () => {
          logger.log(
            `new connection from inside ${P2P_PORT} to ${committeePeer.split(':')[2]}`
          )
          this.connectSocket(
            socket,
            committeePeer.split(':')[2],
            false,
            false,
            true
          )
          this.messageHandler(socket, false, true)
        })
      }
      connectCommitteePeer()
    })
  }

  async connectToCore(isCommittee = false) {
    const connectCore = () => {
      const socket = new WebSocket(
        `${CORE}?port=${P2P_PORT}&isCommittee=${isCommittee ? 'true' : 'false'}&subsetIndex=${SUBSET_INDEX}&httpPort=${process.env.HTTP_PORT}`
      )
      socket.on('error', (error) => {
        logger.error(`Failed to connect to core. Retrying in 5s...`, error)
        setTimeout(connectCore, TIMEOUTS.PEER_RECONNECT_DELAY_MS)
      })
      socket.on('open', () => {
        logger.log(
          `new connection from inside ${P2P_PORT} to ${CORE.split(':')[2]}`
        )
        this.connectSocket(socket, CORE.split(':')[2], false, true, isCommittee)
        this.messageHandler(socket, true, isCommittee)
      })
    }
    connectCore()
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
  // eslint-disable-next-line max-params
  broadcastPrePrepare(
    senderPort,
    block,
    blocksCount,
    previousBlock = undefined,
    isCommittee = false
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
        prepare
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
        commit
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
        message
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
        subsetIndex: SUBSET_INDEX
      },
      chunkKey: 'block',
      socketsKey: isCommittee ? 'committeeCore' : 'core'
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

  messageHandler(socket, isCore = false, isCommittee = false) {
    socket.on('message', (message) => {
      try {
        if (Buffer.isBuffer(message)) {
          message = message.toString()
        }
        const data = JSON.parse(message)
        const processedData = this.idaGossip.handleChunk(data)
        this.parseMessage(processedData, isCore, isCommittee)
      } catch (error) {
        logger.error('Failed to parse message:', error.message)
      }
    })
  }

  _scheduleTimeoutBlockCreation(isCommittee) {
    clearTimeout(this._blockCreationTimeout)
    this._blockCreationTimeout = setTimeout(() => {
      const now = new Date()
      const lastTransactionTime = isCommittee
        ? this.lastCommitteeTransactionCreatedAt
        : this.lastTransactionCreatedAt
      const unassignedCount = isCommittee
        ? this.transactionPool.committeeTransactions.unassigned.length
        : this.transactionPool.transactions.unassigned.length
      const proposerObject = this.blockchain.getProposer(undefined, isCommittee)
      const isProposer = proposerObject.proposer === this.wallet.getPublicKey()

      const isInactive =
        lastTransactionTime &&
        now - lastTransactionTime >=
          TIMEOUTS.TRANSACTION_INACTIVITY_THRESHOLD_MS

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
      // RAPIDCHAIN-SPECIFIC: Handles both committee and regular transactions separately.
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
      if (!isProposer && unassignedCount >= TRANSACTION_THRESHOLD / 2) {
        logger.log(
          P2P_PORT,
          'NON-PROPOSER WITH MANY TXs - Redistributing:',
          unassignedCount
        )
        const txArray = isCommittee
          ? this.transactionPool.committeeTransactions.unassigned
          : this.transactionPool.transactions.unassigned
        const txToRedistribute = txArray.slice(0, 50)
        txToRedistribute.forEach((tx) => {
          this.broadcastTransaction(P2P_PORT, tx, isCommittee)
        })
      }

      if (isInactive && unassignedCount > 0) {
        this.initiateBlockCreation(P2P_PORT, false, isCommittee)
      }
    }, TIMEOUTS.BLOCK_CREATION_TIMEOUT_MS)
  }

  _canProposeBlock(isCommittee) {
    const blocksPool = isCommittee
      ? this.blockPool.committeeBlocks
      : this.blockPool.blocks
    const lastUnpersistedBlock = blocksPool[blocksPool.length - 1]
    const inflightBlocks = this.transactionPool.getInflightBlocks(
      undefined,
      isCommittee
    )

    if (inflightBlocks.length > 1) {
      return this.preparePool.isBlockPrepared(
        lastUnpersistedBlock,
        this.wallet,
        isCommittee
      )
    }
    return true
  }

  _createAndBroadcastBlock(port, isCommittee) {
    const blocksPool = isCommittee
      ? this.blockPool.committeeBlocks
      : this.blockPool.blocks
    const lastUnpersistedBlock = blocksPool[blocksPool.length - 1]
    const inflightBlocks = this.transactionPool.getInflightBlocks(
      undefined,
      isCommittee
    )
    const threshold = isCommittee ? BLOCK_THRESHOLD : TRANSACTION_THRESHOLD
    const unassignedTransactions = isCommittee
      ? this.transactionPool.committeeTransactions.unassigned
      : this.transactionPool.transactions.unassigned

    const previousBlock =
      inflightBlocks.length > 1 ? lastUnpersistedBlock : undefined
    const transactionsBatch = unassignedTransactions.splice(0, threshold)
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

    this.transactionPool.assignTransactions(block, isCommittee)
    const blocksCount = isCommittee
      ? this.blockchain.committeeChain.length
      : this.blockchain.chain[SUBSET_INDEX].length

    this.broadcastPrePrepare(
      port,
      block,
      blocksCount,
      previousBlock,
      isCommittee
    )
  }

  initiateBlockCreation(
    port,
    _triggeredByTransaction = true,
    isCommittee = false
  ) {
    if (isCommittee) {
      this.lastCommitteeTransactionCreatedAt = new Date()
    } else {
      this.lastTransactionCreatedAt = new Date()
    }
    const thresholdReached = this.transactionPool.poolFull(isCommittee)

    if (IS_FAULTY || !thresholdReached) {
      if (!IS_FAULTY && !thresholdReached) {
        const unassignedCount = isCommittee
          ? this.transactionPool.committeeTransactions.unassigned.length
          : this.transactionPool.transactions.unassigned.length
        logger.log(
          P2P_PORT,
          'Transaction Threshold NOT REACHED, TOTAL UNASSIGNED NOW:',
          unassignedCount
        )
      }
      this._scheduleTimeoutBlockCreation(isCommittee)
      return
    }

    const unassignedCount = isCommittee
      ? this.transactionPool.committeeTransactions.unassigned.length
      : this.transactionPool.transactions.unassigned.length
    logger.log(P2P_PORT, 'THRESHOLD REACHED, TOTAL NOW:', unassignedCount)

    const readyToPropose = this._canProposeBlock(isCommittee)
    const proposerObject = this.blockchain.getProposer(undefined, isCommittee)
    const inflightBlocks = this.transactionPool.getInflightBlocks(
      undefined,
      isCommittee
    )
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
      this._createAndBroadcastBlock(port, isCommittee)
    } else {
      const unassignedCount = isCommittee
        ? this.transactionPool.committeeTransactions.unassigned.length
        : this.transactionPool.transactions.unassigned.length
      logger.log(
        P2P_PORT,
        'Transaction Threshold NOT REACHED, TOTAL UNASSIGNED NOW:',
        unassignedCount
      )
    }

    this._scheduleTimeoutBlockCreation(isCommittee)
  }

  _handleTransaction(data, isCommittee) {
    if (
      !this.transactionPool.transactionExists(data.transaction) &&
      this.transactionPool.verifyTransaction(data.transaction) &&
      this.validators.isValidValidator(data.transaction.from)
    ) {
      if (data.port && data.port in this.sockets.peers) {
        this.sockets.peers[data.port].isFaulty = data.isFaulty
      }
      this.transactionPool.addTransaction(data.transaction, isCommittee)
      logger.log(
        P2P_PORT,
        'TRANSACTION ADDED, TOTAL NOW:',
        isCommittee
          ? this.transactionPool.committeeTransactions.unassigned.length
          : this.transactionPool.transactions.unassigned.length
      )
      this.broadcastTransaction(data.port, data.transaction, isCommittee)
      this.initiateBlockCreation(data.port, false, isCommittee)
    }
  }

  _handlePrePrepare(data, isCommittee) {
    const { block, previousBlock, blocksCount } = data.data
    if (
      !this.blockPool.existingBlock(block, isCommittee) &&
      this.blockchain.isValidBlock(
        block,
        blocksCount,
        previousBlock,
        isCommittee
      )
    ) {
      this.blockPool.addBlock(block, isCommittee)
      this.transactionPool.assignTransactions(block, isCommittee)
      this.broadcastPrePrepare(
        data.port,
        block,
        blocksCount,
        previousBlock,
        isCommittee
      )

      if (block?.hash) {
        const prepare = this.preparePool.prepare(
          block,
          this.wallet,
          isCommittee
        )
        this.broadcastPrepare(data.port, prepare, isCommittee)
      }
    }
  }

  _handlePrepare(data, isCommittee) {
    if (
      !this.preparePool.existingPrepare(data.prepare, isCommittee) &&
      this.preparePool.isValidPrepare(data.prepare, this.wallet) &&
      this.validators.isValidValidator(data.prepare.publicKey)
    ) {
      this.preparePool.addPrepare(data.prepare, isCommittee)
      this.broadcastPrepare(data.port, data.prepare, isCommittee)

      const prepareList = isCommittee
        ? this.preparePool.committeeList[data.prepare.blockHash]
        : this.preparePool.list[data.prepare.blockHash]

      if (prepareList.length >= MIN_APPROVALS) {
        const commit = this.commitPool.commit(
          data.prepare,
          this.wallet,
          isCommittee
        )
        this.broadcastCommit(data.port, commit, isCommittee)
      }
    }
  }

  async _handleCommit(data, isCommittee) {
    if (
      !this.commitPool.existingCommit(data.commit, isCommittee) &&
      this.commitPool.isValidCommit(data.commit) &&
      this.validators.isValidValidator(data.commit.publicKey)
    ) {
      this.commitPool.addCommit(data.commit, isCommittee)
      this.broadcastCommit(data.port, data.commit, isCommittee)

      const commitList = this.commitPool.getList(
        data.commit.blockHash,
        isCommittee
      )
      const blockNotInChain = !this.blockchain.existingBlock(
        data.commit.blockHash,
        isCommittee
      )

      if (commitList.length >= MIN_APPROVALS && blockNotInChain) {
        const result = await this.blockchain.addUpdatedBlock(
          data.commit.blockHash,
          this.blockPool,
          this.preparePool,
          this.commitPool,
          isCommittee
        )

        if (result !== false) {
          this.broadcastBlockToCore(result, isCommittee)
          const chainLength = isCommittee
            ? this.blockchain.committeeChain.length
            : this.blockchain.chain[SUBSET_INDEX].length

          logger.log(
            P2P_PORT,
            'NEW BLOCK ADDED TO BLOCK CHAIN, TOTAL NOW:',
            chainLength,
            data.commit.blockHash
          )

          const latestBlock = isCommittee
            ? this.blockchain.committeeChain[
                this.blockchain.committeeChain.length - 1
              ]
            : this.blockchain.chain[SUBSET_INDEX][
                this.blockchain.chain[SUBSET_INDEX].length - 1
              ]

          const message = this.messagePool.createMessage(
            latestBlock,
            this.wallet
          )
          this.broadcastRoundChange(data.port, message, isCommittee)
        } else {
          const chainLength = isCommittee
            ? this.blockchain.committeeChain.length
            : this.blockchain.chain[SUBSET_INDEX].length

          logger.error(
            P2P_PORT,
            'NEW BLOCK FAILED TO ADD TO BLOCK CHAIN, TOTAL STILL:',
            chainLength
          )
        }

        if (!isCommittee) {
          const rate = await this.blockchain.getRate(this.sockets.peers)
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
  }

  _handleRoundChange(data, isCommittee) {
    if (
      !this.messagePool.existingMessage(data.message, isCommittee) &&
      this.messagePool.isValidMessage(data.message) &&
      this.validators.isValidValidator(data.message.publicKey)
    ) {
      this.messagePool.addMessage(data.message, isCommittee)
      this.broadcastRoundChange(data.port, data.message, isCommittee)

      const messageList = isCommittee
        ? this.messagePool.committeeList[data.message.blockHash]
        : this.messagePool.list[data.message.blockHash]

      if (messageList && messageList.length >= MIN_APPROVALS) {
        const transactionList = isCommittee
          ? this.transactionPool.committeeTransactions[data.message.blockHash]
          : this.transactionPool.transactions[data.message.blockHash]

        logger.log(
          P2P_PORT,
          'TRANSACTION POOL TO BE CLEARED, TOTAL NOW:',
          transactionList?.length
        )
        this.transactionPool.clear(
          data.message.blockHash,
          data.message.data,
          isCommittee
        )
      }
    }
  }

  async _handleBlockFromCore(data, isCore, isCommittee) {
    const blockNotInChain = !this.blockchain.existingBlock(
      data.block.hash,
      data.subsetIndex
    )
    const isDifferentShard = data.subsetIndex !== SUBSET_INDEX

    if (blockNotInChain && isDifferentShard && isCore === true) {
      if (!isCommittee) {
        this.blockchain.addBlock(data.block, data.subsetIndex)
        const rate = await this.blockchain.getRate(this.sockets.peers)
        const stats = { total: this.blockchain.getTotal(), rate }
        logger.log(
          P2P_PORT,
          `P2P STATS FOR #${SUBSET_INDEX}:`,
          JSON.stringify(stats)
        )
      } else {
        const transaction = this.wallet.createTransaction({
          data: data.block.data,
          subsetIndex: data.subsetIndex
        })

        if (
          !this.transactionPool.transactionExists(transaction, isCommittee) &&
          this.transactionPool.verifyTransaction(transaction) &&
          this.validators.isValidValidator(transaction.from)
        ) {
          this.transactionPool.addTransaction(transaction, isCommittee)
          logger.log(
            P2P_PORT,
            'COMMITTEE TRANSACTION ADDED, TOTAL NOW:',
            this.transactionPool.committeeTransactions.unassigned.length
          )
          this.broadcastTransaction(data.port, transaction, isCommittee)
          this.initiateBlockCreation(data.port, true, isCommittee)
        }
      }
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

  async parseMessage(data, isCore, isCommittee = false) {
    logger.log(P2P_PORT, 'RECEIVED', data.type, data.port)

    if (IS_FAULTY && ![MESSAGE_TYPE.transaction].includes(data.type)) {
      return
    }

    switch (data.type) {
      case MESSAGE_TYPE.transaction:
        this._handleTransaction(data, isCommittee)
        break
      case MESSAGE_TYPE.pre_prepare:
        this._handlePrePrepare(data, isCommittee)
        break
      case MESSAGE_TYPE.prepare:
        await this._handlePrepare(data, isCommittee)
        break
      case MESSAGE_TYPE.commit:
        await this._handleCommit(data, isCommittee)
        break
      case MESSAGE_TYPE.round_change:
        this._handleRoundChange(data, isCommittee)
        break
      case MESSAGE_TYPE.block_from_core:
        await this._handleBlockFromCore(data, isCore, isCommittee)
        break
      case MESSAGE_TYPE.config_from_core:
        this._handleConfigFromCore(data, isCore)
        break
    }
  }
}

module.exports = P2pserver
