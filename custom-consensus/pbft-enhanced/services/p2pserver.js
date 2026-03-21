const WebSocket = require('ws')
const axios = require('axios')
const MESSAGE_TYPE = require('../constants/message')
const logger = require('../utils/logger')
const TIMEOUTS = require('../constants/timeouts')

const config = require('../config')
const {
  MIN_APPROVALS,
  SUBSET_INDEX,
  TRANSACTION_THRESHOLD,
  IS_FAULTY,
  VERIFICATION_SOURCE_SUBSETS
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
    // View-change: incremented when the designated proposer is faulty/silent
    this._viewOffset = 0
    this._inactivityViewRotated = false
    this._poolWasFullThisEpoch = false
    // Vote pool for atomic view-change: targetView → Set<publicKey>.
    // A rotation only applies once MIN_APPROVALS distinct validator votes
    // arrive, so all shard nodes advance to the same view simultaneously.
    this._viewChangeVotes = new Map()
    // (no pending verification queue — verification TXs bypass the threshold ceiling)
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
      logger.log(`RATE INTERVAL BROADCAST ${SUBSET_INDEX}`, JSON.stringify(rate))
      logger.log(`TOTAL INTERVAL BROADCAST ${SUBSET_INDEX}`, JSON.stringify(total))
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
      nodes.map((peer) => this.waitForWebServer(peer.replace('ws', 'http').replace(':5', ':3')))
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
          logger.log(`new connection from inside ${P2P_PORT} to ${peer.split(':')[2]}`)
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
        logger.log(`new connection from inside ${P2P_PORT} to ${core.split(':')[2]}`)
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

  // broadcasts a batch of transactions in a single message
  broadcastTransactions(senderPort, transactions) {
    this.idaGossip.sendToShardPeers({
      message: {
        type: MESSAGE_TYPE.transactions,
        port: P2P_PORT,
        transactions,
        isFaulty: IS_FAULTY
      },
      senderPort
    })
  }

  // broadcasts preprepare
  // eslint-disable-next-line max-params
  broadcastPrePrepare(senderPort, block, blocksCount, previousBlock = undefined, viewOffset = 0) {
    this.idaGossip.sendToShardPeers({
      message: {
        type: MESSAGE_TYPE.pre_prepare,
        port: P2P_PORT,
        data: {
          block,
          previousBlock,
          blocksCount,
          viewOffset
        }
      },
      chunkKey: 'data',
      senderPort,
      consensusMessage: true
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
      senderPort,
      consensusMessage: true
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
      senderPort,
      consensusMessage: true
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
      senderPort,
      consensusMessage: true
    })
  }

  // broadcasts a view-change vote — sent by non-proposer nodes on inactivity;
  // _viewOffset only advances once MIN_APPROVALS votes are collected so all
  // shard nodes rotate atomically to the same view.
  broadcastViewChange(senderPort, viewChange) {
    this.idaGossip.sendToShardPeers({
      message: {
        type: MESSAGE_TYPE.view_change,
        port: P2P_PORT,
        viewChange
      },
      chunkKey: 'viewChange',
      senderPort,
      consensusMessage: true
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
    // Guard: core WebSocket may not be established yet (race between the
    // setInterval timer and connectToCore's async handshake).  Skip silently —
    // the next interval tick will retry once the connection is ready.
    if (!this.idaGossip.socketGossipCore) return
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
    if (
      !this.transactionPool.transactionExists(data.transaction) &&
      this.transactionPool.verifyTransaction(data.transaction) &&
      this.validators.isValidValidator(data.transaction.from)
    ) {
      if (data.port && data.port in this.sockets) {
        this.sockets[data.port].isFaulty = data.isFaulty
      }
      this.transactionPool.addTransaction(data.transaction)
      logger.debug(
        P2P_PORT,
        'TRANSACTION ADDED, TOTAL NOW:',
        this.transactionPool.transactions.unassigned.length
      )
      this.broadcastTransaction(data.port, data.transaction)
      this.initiateBlockCreation(data.port)
    }
  }

  // handles a batched array of transactions — adds each valid one to the pool
  // then broadcasts all accepted transactions in a single outbound message
  _handleTransactions(data) {
    // When this shard is in redirect mode (broken shard), suppress intra-shard gossip.
    // All peers in a broken shard would otherwise each receive the same TX via gossip
    // and each independently drain it — creating duplicate committed transactions on
    // the healthy target shard (one per broken-shard node) and a drain rate > 100%.
    const { REDIRECT_TO_URL, SHOULD_REDIRECT_FROM_FAULTY_NODES } = config.get()
    const isRedirectMode =
      SHOULD_REDIRECT_FROM_FAULTY_NODES &&
      Array.isArray(REDIRECT_TO_URL) &&
      REDIRECT_TO_URL.length > 0

    const toForward = []
    for (const transaction of data.transactions) {
      if (
        !this.transactionPool.transactionExists(transaction) &&
        this.transactionPool.verifyTransaction(transaction) &&
        this.validators.isValidValidator(transaction.from)
      ) {
        if (data.port && data.port in this.sockets) {
          this.sockets[data.port].isFaulty = data.isFaulty
        }
        this.transactionPool.addTransaction(transaction)
        logger.debug(
          P2P_PORT,
          'TRANSACTION ADDED, TOTAL NOW:',
          this.transactionPool.transactions.unassigned.length
        )
        toForward.push(transaction)
      }
    }
    if (toForward.length > 0 && !isRedirectMode) {
      this.broadcastTransactions(data.port, toForward)
      this.initiateBlockCreation(data.port)
    }
  }

  _handlePrePrepare(data) {
    const { block, previousBlock, blocksCount, viewOffset = 0 } = data.data
    // Sync view offset forward so we validate against the same proposer.
    if (viewOffset > (this._viewOffset || 0)) this._viewOffset = viewOffset
    // Proposer is working — cancel the view-change countdown
    clearTimeout(this._blockCreationTimeout)
    this._blockCreationTimeout = null
    if (
      !this.blockPool.existingBlock(block) &&
      this.blockchain.isValidBlock(block, blocksCount, previousBlock, viewOffset)
    ) {
      this.blockPool.addBlock(block)
      this.transactionPool.assignTransactions(block)
      this.broadcastPrePrepare(data.port, block, blocksCount, previousBlock, viewOffset)

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

      if (this.preparePool.list[data.prepare.blockHash].length >= MIN_APPROVALS) {
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

      const commitReached = this.commitPool.list[data.commit.blockHash].length >= MIN_APPROVALS
      const blockNotInChain = !this.blockchain.existingBlock(data.commit.blockHash)

      if (commitReached && blockNotInChain) {
        const result = await this.blockchain.addUpdatedBlock(
          data.commit.blockHash,
          this.blockPool,
          this.preparePool,
          this.commitPool
        )
        if (result !== false) {
          // Block committed — cancel view-change countdown and reset offset for next round
          clearTimeout(this._blockCreationTimeout)
          this._blockCreationTimeout = null
          this._viewOffset = 0
          this._inactivityViewRotated = false
          this._poolWasFullThisEpoch = false
          this._viewChangeVotes = new Map()
          this.broadcastBlockToCore(result)
          logger.log(
            P2P_PORT,
            'NEW BLOCK ADDED TO BLOCK CHAIN, TOTAL NOW:',
            this.blockchain.chain[SUBSET_INDEX].length,
            data.commit.blockHash
          )
          // Don't wait for a round-change quorum before clearing the pool and
          // starting the next block round. The PBFT commit phase already
          // guarantees 2f+1 agreement — all honest nodes that reach here have
          // already committed.  Clearing immediately eliminates one full P2P
          // gossip round-trip (propose→gossip→ MIN_APPROVALS replies) of dead
          // time between every consecutive block. _handleRoundChange.clear()
          // is idempotent (no-op if the hash bucket is already gone).
          this.transactionPool.clear(data.commit.blockHash, result.data)
          if (this.transactionPool.transactions.unassigned.length > 0) {
            this.initiateBlockCreation(P2P_PORT, false)
          }
          const message = this.messagePool.createMessage(
            this.blockchain.chain[SUBSET_INDEX][this.blockchain.chain[SUBSET_INDEX].length - 1],
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
          unassignedTransactions: this.transactionPool.transactions.unassigned.length
        }
        logger.log(P2P_PORT, `P2P STATS FOR #${SUBSET_INDEX}:`, JSON.stringify(stats))
      }
    }
  }

  _handleViewChange(data) {
    const { targetView, publicKey } = data.viewChange
    if (!this.validators.isValidValidator(publicKey)) return
    if (!this._viewChangeVotes.has(targetView)) this._viewChangeVotes.set(targetView, new Set())
    const votes = this._viewChangeVotes.get(targetView)
    if (votes.has(publicKey)) return // deduplicate
    votes.add(publicKey)
    // Relay so all shard peers receive this vote
    this.broadcastViewChange(data.port, data.viewChange)
    // Quorum reached and this view is ahead of where we are — rotate atomically
    if (votes.size >= MIN_APPROVALS && targetView > (this._viewOffset || 0)) {
      this._viewOffset = targetView
      // Reset both epoch flags so initiateBlockCreation (called immediately below)
      // can fire another vote right away if the NEW proposer at this view is also
      // faulty — eliminates the 10 s timeout wait for consecutive faulty proposers.
      this._poolWasFullThisEpoch = false
      this._inactivityViewRotated = false
      // Return all TX that are assigned to the abandoned block back to the
      // unassigned pool immediately — new proposer can pick them up at once
      // instead of waiting up to 30 s for the safety-reassignment timers.
      this.transactionPool.releaseAssigned()
      logger.log(P2P_PORT, 'VIEW CHANGE (quorum) — rotating to view', this._viewOffset)
      this.initiateBlockCreation(P2P_PORT, false)
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
        // Re-arm block creation if there are still unassigned transactions.
        // Without this, the pool stalls after JMeter stops because no new
        // TRANSACTION_RECEIVED events arrive to call _scheduleTimeoutBlockCreation.
        if (this.transactionPool.transactions.unassigned.length > 0) {
          this.initiateBlockCreation(P2P_PORT, false)
        }
      }
    }
  }

  // Cross-shard verification: re-validate every original transaction from the
  // designated source shard's committed block and inject tagged copies into the
  // local pool for a second independent PBFT round on this shard.
  //
  // Tag (_type:'verification') is at the top level of the transaction object
  // (outside `input`) so verifyTransaction() — which only hashes `tx.input` —
  // still passes.  Transactions already tagged are skipped to prevent cascade.

  _injectVerificationTransactions(block) {
    // Inject verification TXs directly into the pool, bypassing TRANSACTION_THRESHOLD.
    // They are a separate _type:'verification' category so they don't displace normal TXs
    // once committed — the pool clear only removes assigned normal TXs.
    // let injected = 0
    for (const tx of block.data) {
      if (tx._type === 'verification') continue // already verified once — skip
      if (!this.transactionPool.verifyTransaction(tx)) {
        logger.error(
          P2P_PORT,
          'VERIFICATION: invalid signature from shard',
          block.subsetIndex,
          tx.id
        )
        continue
      }
      const taggedTx = { ...tx, _type: 'verification' }
      if (this.transactionPool.transactionExists(taggedTx)) continue
      this.transactionPool.addTransaction(taggedTx)
      // injected++
    }
    // if (injected > 0) {
    //   logger.log(P2P_PORT, `VERIFICATION: injected ${injected} txs from shard ${block.subsetIndex}`)
    //   this.initiateBlockCreation(P2P_PORT, false)
    // }
  }

  async _handleBlockFromCore(data, isCore) {
    const blockNotInChain = !this.blockchain.existingBlock(data.block.hash, data.subsetIndex)
    const isDifferentShard = data.subsetIndex !== SUBSET_INDEX

    if (blockNotInChain && isDifferentShard && isCore === true) {
      this.blockchain.addBlock(data.block, data.subsetIndex)

      if (
        !IS_FAULTY &&
        VERIFICATION_SOURCE_SUBSETS.length > 0 &&
        VERIFICATION_SOURCE_SUBSETS.includes(data.subsetIndex) /*&&
        Math.random() < 0.5*/
      ) {
        this._injectVerificationTransactions({ ...data.block, subsetIndex: data.subsetIndex })
      }

      const rate = await this.blockchain.getRate(this.sockets)
      const stats = { total: this.blockchain.getTotal(), rate }
      logger.log(P2P_PORT, `P2P STATS FOR #${SUBSET_INDEX}:`, JSON.stringify(stats))
    }
  }

  _handleConfigFromCore(data, isCore) {
    if (isCore === true) {
      data.config.forEach((item) => {
        config.set(item.key, item.value)
      })
      logger.log(P2P_PORT, `CONFIG UPDATE FOR #${SUBSET_INDEX}:`, JSON.stringify(data.config))
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
        if (processedData) {
          this.parseMessage(processedData, isCore)
        }
      } catch (error) {
        logger.error('Failed to parse message:', error.message)
      }
    })
  }

  _scheduleTimeoutBlockCreation() {
    // Once a timer is running, never reset it — let it fire on its own schedule.
    // Previously the pool-not-full branch called clearTimeout() on every incoming
    // transaction, meaning the 10s countdown reset every ~1.4s under normal load
    // and never fired until the pool happened to be full. With threshold=30 at
    // ~0.7 TX/s per shard that took 42s + 10s = 52s just to get the first block.
    // Now the timer fires every BLOCK_CREATION_TIMEOUT_MS regardless, and decides
    // at that point what to do (view-change, sub-threshold create, or reschedule).
    if (this._blockCreationTimeout) {
      return // already counting down — let it fire naturally
    }
    this._blockCreationTimeout = setTimeout(() => {
      this._blockCreationTimeout = null
      this._onBlockCreationTimeout()
    }, TIMEOUTS.BLOCK_CREATION_TIMEOUT_MS)
  }

  _onBlockCreationTimeout() {
    const now = new Date()
    const isInactive =
      this.lastTransactionCreatedAt &&
      now - this.lastTransactionCreatedAt >= TIMEOUTS.TRANSACTION_INACTIVITY_THRESHOLD_MS
    const hasTransactions = this.transactionPool.transactions.unassigned.length > 0
    // Use the current _viewOffset so isProposer reflects whoever is actually
    // elected this round, not always the viewOffset=0 slot.
    const proposerObject = this.blockchain.getProposer(undefined, this._viewOffset || 0)
    const isProposer = proposerObject.proposer === this.wallet.getPublicKey()

    if (hasTransactions && this.transactionPool.poolFull()) {
      this._handlePoolFullTimeout(isProposer)
    } else if (isInactive && hasTransactions) {
      this._handleInactivityTimeout(isProposer)
    } else if (hasTransactions) {
      // Pool has TX but neither full nor inactive yet — reschedule so we keep
      // checking every BLOCK_CREATION_TIMEOUT_MS until conditions are met.
      this._scheduleTimeoutBlockCreation()
    }
  }

  // Pool still full after BLOCK_CREATION_TIMEOUT_MS — proposer still silent.
  // Vote via broadcast so all shard nodes rotate to the same view atomically.
  // Map-level dedup prevents re-broadcasting a vote already cast this epoch.
  //
  // TRANSACTION REDISTRIBUTION MECHANISM (TIMEOUT-BASED WORKAROUND)
  // PROBLEM: In PBFT, only the designated proposer can create blocks. However,
  // load balancers distribute client requests across all nodes. If the proposer
  // doesn't receive enough transactions directly, no blocks are created despite
  // high overall transaction volume across other nodes.
  // DISABLED: Under Kubernetes with CPU limits (0.2 vcpu/pod), the 50-tx burst
  // (3 non-proposer nodes × 50 broadcasts = 150 WebSocket messages every 10 s)
  // saturates the Node.js event loop and causes JMeter HTTP request timeouts.
  _handlePoolFullTimeout(isProposer) {
    if (!isProposer) {
      // Only non-proposers vote — the proposer should be creating blocks,
      // not voting to skip itself. If the proposer is stuck the inactivity
      // path will escalate after TRANSACTION_INACTIVITY_THRESHOLD_MS.
      this._poolWasFullThisEpoch = true
      const targetView = (this._viewOffset || 0) + 1
      if (!this._viewChangeVotes.has(targetView)) this._viewChangeVotes.set(targetView, new Set())
      if (!this._viewChangeVotes.get(targetView).has(this.wallet.getPublicKey())) {
        this._viewChangeVotes.get(targetView).add(this.wallet.getPublicKey())
        logger.log(P2P_PORT, 'VIEW CHANGE VOTE (timeout) — proposing view', targetView)
        this.broadcastViewChange(P2P_PORT, {
          targetView,
          publicKey: this.wallet.getPublicKey()
        })
      }
    }
    this.initiateBlockCreation(P2P_PORT, false)
  }

  // Cast a view-change vote when this node is not the current proposer,
  // the pool-full path has not already rotated this epoch, and this node
  // has not yet broadcast its vote.  The offset only changes once
  // MIN_APPROVALS votes arrive in _handleViewChange so all shard peers
  // rotate atomically to the same view.
  _handleInactivityTimeout(isProposer) {
    if (!isProposer && !this._poolWasFullThisEpoch && !this._inactivityViewRotated) {
      this._inactivityViewRotated = true
      const targetView = (this._viewOffset || 0) + 1
      if (!this._viewChangeVotes.has(targetView)) this._viewChangeVotes.set(targetView, new Set())
      this._viewChangeVotes.get(targetView).add(this.wallet.getPublicKey())
      logger.log(P2P_PORT, 'VIEW CHANGE VOTE — proposing view', targetView)
      this.broadcastViewChange(P2P_PORT, { targetView, publicKey: this.wallet.getPublicKey() })
    }
    // Sub-threshold drain: if this node is the proposer and ready, create a
    // block with whatever TX are available instead of waiting for view-change
    // quorum that can never produce a block (threshold will never be reached).
    if (isProposer && this._canProposeBlock()) {
      this._createAndBroadcastBlock(P2P_PORT, this._viewOffset || 0)
    } else {
      // Keep trying with the current offset while waiting for quorum
      this.initiateBlockCreation(P2P_PORT, false)
    }
  }

  _canProposeBlock() {
    const lastUnpersistedBlock = this.blockPool.blocks[this.blockPool.blocks.length - 1]
    const inflightBlocks = this.transactionPool.getInflightBlocks()

    if (inflightBlocks.length > 1) {
      return this.preparePool.isBlockPrepared(lastUnpersistedBlock, this.wallet)
    }
    return true
  }

  _createAndBroadcastBlock(port, viewOffset = 0) {
    const lastUnpersistedBlock = this.blockPool.blocks[this.blockPool.blocks.length - 1]
    const inflightBlocks = this.transactionPool.getInflightBlocks()
    const previousBlock = inflightBlocks.length > 1 ? lastUnpersistedBlock : undefined
    // Normal TXs take priority — sort in-place so verification TXs fill only
    // the remaining capacity after normal ones are picked first.
    this.transactionPool.transactions.unassigned.sort(
      (a, b) => (a._type === 'verification' ? 1 : 0) - (b._type === 'verification' ? 1 : 0)
    )
    const transactionsBatch = this.transactionPool.transactions.unassigned.splice(
      0,
      TRANSACTION_THRESHOLD
    )
    const block = this.blockchain.createBlock(transactionsBatch, this.wallet, previousBlock)

    logger.log(P2P_PORT, 'CREATED BLOCK', block.hash, 'txCount:', block.data.length)

    this.transactionPool.assignTransactions(block)
    // Proposer adds block to its own pool (needed for addUpdatedBlock look-up on commit)
    this.blockPool.addBlock(block)
    // Standard PBFT: the proposer implicitly casts a prepare for its own block.
    // Broadcast it immediately so non-proposer nodes reach MIN_APPROVALS even when
    // one shard peer is faulty (only 3 non-faulty nodes, all three must vote).
    const ownPrepare = this.preparePool.prepare(block, this.wallet)
    this.broadcastPrePrepare(
      port,
      block,
      this.blockchain.chain[SUBSET_INDEX].length,
      previousBlock,
      viewOffset
    )
    this.broadcastPrepare(port, ownPrepare)
  }

  initiateBlockCreation(port, _triggeredByTransaction = true) {
    // Only update inactivity clock for real incoming transactions.
    // Timeout-path calls (_triggeredByTransaction=false) must not reset the
    // clock or isInactive will always be false during active JMeter load.
    if (_triggeredByTransaction) this.lastTransactionCreatedAt = new Date()
    const thresholdReached = this.transactionPool.poolFull()
    if (!IS_FAULTY && (thresholdReached || !_triggeredByTransaction)) {
      logger.debug(
        P2P_PORT,
        'THRESHOLD REACHED, TOTAL NOW:',
        this.transactionPool.transactions.unassigned.length
      )
      const readyToPropose = this._canProposeBlock()
      const viewOffset = this._viewOffset || 0
      const proposerObject = this.blockchain.getProposer(undefined, viewOffset)
      const inflightBlocks = this.transactionPool.getInflightBlocks()
      const isProposer = proposerObject.proposer === this.wallet.getPublicKey()
      const canCreateBlock = isProposer && readyToPropose && inflightBlocks.length <= 8
      // Check if the elected proposer is already a known-faulty peer (isFaulty set at
      // connection time or via transaction relay). If so, vote to skip immediately
      // instead of waiting 10 s for the timeout — eliminates per-rotation stall.
      const proposerPort =
        proposerObject.proposerIndex !== null ? String(5001 + proposerObject.proposerIndex) : null
      const proposerKnownFaulty =
        proposerPort !== null && this.sockets[proposerPort]?.isFaulty === true

      if (canCreateBlock) {
        logger.log(P2P_PORT, 'PROPOSING BLOCK')
        // We are the proposer — clear any pending view-change countdown
        clearTimeout(this._blockCreationTimeout)
        this._blockCreationTimeout = null
        this._createAndBroadcastBlock(port, viewOffset)
      } else if (
        thresholdReached &&
        !isProposer &&
        proposerKnownFaulty &&
        !this._poolWasFullThisEpoch &&
        !this._inactivityViewRotated
      ) {
        // Pool is at threshold and proposer is known-faulty — vote to skip immediately
        // regardless of whether this was triggered by an incoming TX or by a view-change
        // quorum handler. This covers drain phase where no new TX arrive but the pool
        // still has 30+ unprocessed TX after releaseAssigned().
        this._poolWasFullThisEpoch = true
        const targetView = viewOffset + 1
        if (!this._viewChangeVotes.has(targetView)) this._viewChangeVotes.set(targetView, new Set())
        this._viewChangeVotes.get(targetView).add(this.wallet.getPublicKey())
        logger.log(
          P2P_PORT,
          'VIEW CHANGE VOTE (known-faulty proposer) — proposing view',
          targetView
        )
        this.broadcastViewChange(port, { targetView, publicKey: this.wallet.getPublicKey() })
        // NOTE: Removed immediate "pool full + _triggeredByTransaction" view-change vote.
        // When redirect is active, all shard-2 nodes reach poolFull() within milliseconds
        // of each other. If non-proposers voted immediately they would form a 3-vote
        // quorum before the proposer's pre-prepare propagates, triggering a view change
        // that discards the proposer's assignTransactions() call — leaving 150 txs stuck
        // in reassignment for 30 s and creating near-empty replacement blocks.
        // The BLOCK_CREATION_TIMEOUT_MS (5 s) path handles silent/faulty proposers;
        // the proposerKnownFaulty path above handles explicitly-flagged ones.
      }
    } else if (!IS_FAULTY) {
      logger.debug(
        P2P_PORT,
        'Transaction Threshold NOT REACHED, TOTAL UNASSIGNED NOW:',
        this.transactionPool.transactions.unassigned.length
      )
    }

    this._scheduleTimeoutBlockCreation()
  }

  async parseMessage(data, isCore) {
    logger.debug(P2P_PORT, 'RECEIVED', data.type, data.port)

    if (IS_FAULTY && ![MESSAGE_TYPE.transaction, MESSAGE_TYPE.transactions].includes(data.type)) {
      return
    }

    switch (data.type) {
      case MESSAGE_TYPE.transaction:
        this._handleTransaction(data)
        break
      case MESSAGE_TYPE.transactions:
        this._handleTransactions(data)
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
      case MESSAGE_TYPE.view_change:
        this._handleViewChange(data)
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
