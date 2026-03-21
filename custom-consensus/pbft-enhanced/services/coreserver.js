// import the ws module
const WebSocket = require('ws')
const MESSAGE_TYPE = require('../constants/message')
const { SHARD_STATUS } = require('../constants/status')
const config = require('../config')
const logger = require('../utils/logger')

class Coreserver {
  constructor(port, blockchain, idaGossip) {
    this.port = port
    this.sockets = {}
    this.socketsMap = {}
    this.blockchain = blockchain
    this.rates = {}
    this.idaGossip = idaGossip
    this.config = config.get()
    // Idempotency cache: last JSON-serialised config sent to each shard.
    // clearRedirectConfiguration fires on every rate_to_core update, pushing
    // {REDIRECT_TO_URL:[]} to all healthy shards even when nothing changed.
    // Skipping no-op sends eliminates ~60 spurious WebSocket calls/sec from core.
    this._lastSentConfig = new Map() // shardIndex → JSON string of last config
  }

  // Creates a server on a given port
  listen() {
    const server = new WebSocket.Server({ port: this.port })
    logger.log(`Listening on port ${this.port}`)
    server.on('connection', (socket, request) => {
      const parsedUrl = new URL(request.url, `http://${request.headers.host}`)
      const subsetIndex = parsedUrl.searchParams.get('subsetIndex')
      const port = parsedUrl.searchParams.get('port')
      const httpPort = parsedUrl.searchParams.get('httpPort')
      this.connectSocket(socket, port, subsetIndex, httpPort)
      this.messageHandler(socket, false)
      logger.log('core sockets', JSON.stringify(this.socketsMap))
    })
  }

  // connects to a given socket and registers the message handler on it
  connectSocket(socket, port, subsetIndex, httpPort) {
    if (!this.sockets[subsetIndex]) {
      this.sockets[subsetIndex] = {}
      this.socketsMap[subsetIndex] = []
    }
    this.sockets[subsetIndex][port] = {
      socket,
      url: `http://p2p-server-${Number(port) - 5001}:${httpPort}`
    }
    this.socketsMap[subsetIndex].push(port)
    this.idaGossip.setNodeSockets(this.sockets)
  }

  // broadcast block
  broadcastBlock(block, subsetIndex) {
    this.idaGossip.broadcastFromCore({
      message: {
        type: MESSAGE_TYPE.block_from_core,
        block,
        subsetIndex
      },
      chunkKey: 'block',
      sendersSubsetIndex: subsetIndex
    })
  }

  // update config
  updateConfig(config, subsetIndex) {
    // Skip if the config value for this shard hasn't changed — prevents
    // clearRedirectConfiguration from spamming healthy shards with no-op
    // {REDIRECT_TO_URL:[]} messages on every incoming rate_to_core event.
    const configKey = JSON.stringify(config)
    if (this._lastSentConfig.get(subsetIndex) === configKey) return
    this._lastSentConfig.set(subsetIndex, configKey)
    this.idaGossip.sendFromCoreToSpecificShard({
      message: {
        type: MESSAGE_TYPE.config_from_core,
        config
      },
      targetsSubsetIndex: subsetIndex
    })
  }

  // Calculate shard status mapping from rates
  calculateShardStatusMap() {
    const shardStatusMap = {}
    Object.values(SHARD_STATUS).forEach((status) => {
      shardStatusMap[status] = Object.entries(this.rates)
        .filter(([, rate]) => rate.shardStatus === status)
        .map(([shardIndex]) => shardIndex)
    })
    return shardStatusMap
  }

  // Find best candidate shard for faulty shard redirection.
  // over_utilized shards are excluded: redirecting to them would flood an already-saturated
  // shard, causing view-change storms and reducing total throughput. Broken shards hold
  // transactions locally until an under_utilized or normal candidate is available.
  findRedirectCandidate(assignedIndices, shardStatusMap) {
    const candidateSets = [
      {
        shards: shardStatusMap[SHARD_STATUS.under_utilized] || [],
        status: SHARD_STATUS.under_utilized
      },
      {
        shards: shardStatusMap[SHARD_STATUS.normal] || [],
        status: SHARD_STATUS.normal
      }
    ]

    for (const { shards, status } of candidateSets) {
      const available = shards.filter((index) => !assignedIndices.has(index))
      if (available.length > 0) {
        const randomIndex = Math.floor(Math.random() * available.length)
        return { selected: available[randomIndex], status }
      }
    }
    return null
  }

  // Build faulty shard redirect assignment mapping.
  // Each faulty shard always gets an entry: either a redirect target or null meaning
  // no viable candidate exists right now (applyRedirectConfiguration will clear the URL
  // so the broken shard buffers locally until capacity opens up).
  //
  // Multiple broken shards may map to the same healthy shard — the TRANSACTION_THRESHOLD
  // batch cap in the drain timer prevents flooding, so the old one-to-one dedup was an
  // artificial constraint that left some broken shards with no URL at all.
  buildFaultyShardRedirectAssignment(faultyShards, shardStatusMap) {
    const faultyShardRedirectAssignment = {}

    faultyShards.forEach((faultyShardIndex) => {
      // Pass an empty Set so every broken shard independently picks from all healthy shards.
      const result = this.findRedirectCandidate(new Set(), shardStatusMap)
      if (result) {
        faultyShardRedirectAssignment[faultyShardIndex] = { redirectSubset: result.selected }
      } else {
        // No viable candidate — will clear redirect URL so broken shard holds TX locally
        faultyShardRedirectAssignment[faultyShardIndex] = { redirectSubset: null }
      }
    })

    return faultyShardRedirectAssignment
  }

  // Apply redirect configuration to faulty shards.
  // When no candidate is available (redirectSubset === null), clears the URL so the
  // broken shard buffers locally rather than flooding a saturated target.
  applyRedirectConfiguration(faultyShardRedirectAssignment) {
    Object.entries(faultyShardRedirectAssignment).forEach(
      ([faultyShardIndex, { redirectSubset }]) => {
        if (redirectSubset && this.sockets[redirectSubset]) {
          const redirectUrls = Object.values(this.sockets[redirectSubset]).map(
            (object) => object.url
          )
          this.updateConfig([{ key: 'REDIRECT_TO_URL', value: redirectUrls }], faultyShardIndex)
        } else {
          // No healthy candidate right now — clear redirect URL
          this.updateConfig([{ key: 'REDIRECT_TO_URL', value: [] }], faultyShardIndex)
        }
      }
    )
  }

  // Clear redirect configuration for healthy shards
  clearRedirectConfiguration(shards) {
    shards.forEach((shardIndex) => {
      const config = [{ key: 'REDIRECT_TO_URL', value: [] }]
      this.updateConfig(config, shardIndex)
    })
  }

  // Handle faulty shard redirection logic
  handleFaultyShardRedirection() {
    const shardStatusMap = this.calculateShardStatusMap()
    const faultyShards = shardStatusMap[SHARD_STATUS.faulty] || []
    const underUtilizedShards = shardStatusMap[SHARD_STATUS.under_utilized] || []
    const normalShards = shardStatusMap[SHARD_STATUS.normal] || []
    const overUtilizedShards = shardStatusMap[SHARD_STATUS.over_utilized] || []

    const faultyShardRedirectAssignment = this.buildFaultyShardRedirectAssignment(
      faultyShards,
      shardStatusMap
    )

    this.applyRedirectConfiguration(faultyShardRedirectAssignment)
    this.clearRedirectConfiguration([
      ...underUtilizedShards,
      ...normalShards,
      ...overUtilizedShards
    ])
  }

  // handles any message sent to the current node
  messageHandler(socket) {
    // registers message handler
    socket.on('message', async (message) => {
      if (Buffer.isBuffer(message)) {
        message = message.toString() // Convert Buffer to string
      }
      const receivedData = JSON.parse(message)
      const data = this.idaGossip.handleChunk(receivedData)
      if (data) {
        logger.log(this.port, 'RECEIVED', data.type)

        // select a particular message handler
        switch (data.type) {
          case MESSAGE_TYPE.block_to_core:
            // add updated block to chain
            if (!this.blockchain.existingBlock(data.block.hash, data.subsetIndex)) {
              this.blockchain.addBlock(data.block, data.subsetIndex)
              const stats = {
                total: this.blockchain.getTotal(),
                rate: this.rates
              }
              logger.log(`CORE TOTAL:`, JSON.stringify(stats))
              this.broadcastBlock(data.block, data.subsetIndex)
            }
            break
          case MESSAGE_TYPE.rate_to_core:
            // collect shards rates
            if (
              !this.rates[data.rate.shardIndex] ||
              this.rates[data.rate.shardIndex].transactions <
                data.rate.transactions[data.rate.shardIndex]
            ) {
              this.rates[data.rate.shardIndex] = {
                transactions: data.rate.transactions?.[data.rate.shardIndex],
                blocks: data.rate.blocks?.[data.rate.shardIndex],
                shardStatus: data.rate.shardStatus
              }
              const { SHOULD_REDIRECT_FROM_FAULTY_NODES } = this.config
              if (SHOULD_REDIRECT_FROM_FAULTY_NODES) {
                this.handleFaultyShardRedirection()
              }
            }
            logger.log(`CORE RATE:`, JSON.stringify(this.rates))
            logger.log(`CORE TOTAL:`, JSON.stringify(data.total))
            break
        }
      }
    })
  }
}

module.exports = Coreserver
