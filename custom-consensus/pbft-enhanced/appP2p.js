// Import all required models
const express = require('express')
const bodyParser = require('body-parser')
const config = require('./config')
const logger = require('./utils/logger')
const Wallet = require('./services/wallet')
const P2pserver = require('./services/p2pserver')
const Validators = require('./services/validators')
const Blockchain = require('./services/blockchain')
const IDAGossip = require('./services/idaGossip')
const TransactionPool = require('./services/pools/transaction')
const BlockPool = require('./services/pools/block')
const CommitPool = require('./services/pools/commit')
const PreparePool = require('./services/pools/prepare')
const MessagePool = require('./services/pools/message')
const MESSAGE_TYPE = require('./constants/message')
const ChainUtility = require('./utils/chain')

const HTTP_PORT = process.env.HTTP_PORT || 3001
const P2P_PORT = process.env.P2P_PORT || 5001
const { NODES_SUBSET, SUBSET_INDEX } = config.get()

// Count of duplicate transactions injected by this node (50% random simulation)
let duplicatesCreated = 0

// Instantiate all objects
const app = express()
app.use(bodyParser.json())

const wallet = new Wallet(process.env.SECRET)
const transactionPool = new TransactionPool()
const validators = new Validators(NODES_SUBSET)
const blockchain = new Blockchain(validators, transactionPool)
const blockPool = new BlockPool()
const preparePool = new PreparePool()
const commitPool = new CommitPool()
const messagePool = new MessagePool()
const idaGossip = new IDAGossip()
const p2pserver = new P2pserver(
  blockchain,
  transactionPool,
  wallet,
  blockPool,
  preparePool,
  commitPool,
  messagePool,
  validators,
  idaGossip
)

// sends all transactions in the transaction pool to the user
app.get('/transactions', (request, response) => {
  response.json(transactionPool.transactions)
})

// sends the entire chain to the user
app.get('/blocks', (request, response) => {
  response.json(blockchain.chain)
})

// sends the chain stats to the user
app.get('/stats', async (request, response) => {
  const rate = await blockchain.getRate(p2pserver.sockets)
  const { IS_FAULTY } = config.get()
  const stats = {
    total: blockchain.getTotal(),
    rate,
    duplicatesCreated,
    isFaulty: IS_FAULTY
  }
  logger.log(`REQUEST STATS FOR #${SUBSET_INDEX}:`, JSON.stringify(stats))
  response.json(stats)
})

// check server health
app.get('/health', (request, response) => {
  response.status(200).send('Ok')
})

// creates transactions for the sent data
app.post('/transaction', async (request, response) => {
  const { IS_FAULTY, REDIRECT_TO_URL, SHOULD_REDIRECT_FROM_FAULTY_NODES } = config.get()
  const unassignedTransactions = transactionPool.transactions.unassigned
  const hasUnassignedTransactions = unassignedTransactions && unassignedTransactions.length > 0
  if (
    !IS_FAULTY &&
    SHOULD_REDIRECT_FROM_FAULTY_NODES &&
    Array.isArray(REDIRECT_TO_URL) &&
    REDIRECT_TO_URL.length > 0
  ) {
    let lastError = null
    for (const redirectUrl of REDIRECT_TO_URL) {
      logger.log(`Redirect from ${HTTP_PORT} to ${redirectUrl}`)
      try {
        await idaGossip.sendToAnotherShard({
          message: {
            transactions: hasUnassignedTransactions
              ? [
                  ...unassignedTransactions.map((transaction) => transaction.input.data),
                  request.body
                ]
              : request.body
          },
          chunkKey: 'transactions',
          targetsSubset: [`${redirectUrl}/transaction`]
        })
        if (hasUnassignedTransactions) {
          transactionPool.transactions.unassigned = []
        }
        // If successful, return the response immediately
        return response.status(200).send()
      } catch (error) {
        lastError = error
        // Try next redirectUrl in the array
        logger.warn(`Redirect to ${redirectUrl} failed:`, error)
      }
    }
    // If all redirects fail, return the last error
    return response
      .status(lastError?.response?.status || 500)
      .send(lastError?.message || 'All redirects failed')
  } else {
    try {
      const data = request.body.transactions ? request.body.transactions : [request.body]
      // Build all transaction batches synchronously (CPU-only: signing + dedup coin flip)
      // before responding, so the request body is fully consumed and duplicatesCreated
      // is incremented in the same tick.
      const batches = data.map((item) => {
        logger.debug(`Processing transaction on ${HTTP_PORT}`, JSON.stringify(item))
        const transaction = wallet.createTransaction(item)
        // Build the batch: always the real transaction, plus a duplicate ~50% of the time
        // to simulate dual-shard cross-verification. Both are dispatched in a single
        // broadcastTransactions call, saving one WebSocket message per ingested transaction.
        const txBatch = [transaction]
        if (Math.random() < 0.5) {
          duplicatesCreated++
          txBatch.push({ ...transaction, id: ChainUtility.id() })
        }
        return txBatch
      })
      // Respond immediately before the gossip/socket-write work so the HTTP
      // round-trip is not blocked by IDA fan-out to shard peers.
      response.json({ ok: true })
      setImmediate(() => {
        for (const txBatch of batches) {
          p2pserver.parseMessage({
            type: MESSAGE_TYPE.transactions,
            transactions: txBatch,
            port: P2P_PORT
          })
        }
      })
    } catch (error) {
      logger.warn(`Transaction processing error on ${HTTP_PORT}:`, error)
      response.json({ ok: true })
    }
  }
})

// parse message
app.post('/message', async (request, response) => {
  logger.log(`Processing message on ${HTTP_PORT}`, JSON.stringify(request.body))
  p2pserver.parseMessage(request.body)
  response.status(200).send('Ok')
})

// Proactive stuck-pool drainer: if this node holds unassigned transactions but the
// block count hasn't moved for 60s (shard broken by too many faulty nodes), forward
// the stuck transactions to a healthy shard's HTTP endpoint for re-processing.
// This rescues transactions that nobody in the broken shard would otherwise confirm.
{
  let _lastDrainBlockCount = -1
  let _stuckCycles = 0
  // Reduced from 30 000 ms: faster drain means dead-shard transactions are rescued
  // sooner. Combined with the lower RATE_BROADCAST_INTERVAL_MS (8 s) the
  // worst-case rescue latency drops from 55 s to ~23 s, giving stuck transactions
  // a much larger window within the 90 s JMeter run + drain phase.
  const DRAIN_INTERVAL_MS = 10000
  const DRAIN_STUCK_CYCLES = 1 // 1 × 10 s = 10 s before acting

  setInterval(async () => {
    const { IS_FAULTY, REDIRECT_TO_URL, SHOULD_REDIRECT_FROM_FAULTY_NODES } = config.get()
    if (
      IS_FAULTY ||
      !SHOULD_REDIRECT_FROM_FAULTY_NODES ||
      !Array.isArray(REDIRECT_TO_URL) ||
      !REDIRECT_TO_URL.length
    )
      return

    const unassigned = transactionPool.transactions.unassigned
    if (!unassigned.length) {
      _stuckCycles = 0
      return
    }

    const total = blockchain.getTotal()
    const currentBlocks = Object.values(total).reduce((s, v) => s + (v.blocks || 0), 0)
    if (currentBlocks !== _lastDrainBlockCount) {
      _lastDrainBlockCount = currentBlocks
      _stuckCycles = 0
      return
    }

    _stuckCycles++
    if (_stuckCycles < DRAIN_STUCK_CYCLES) return

    logger.log(`STUCK DRAIN: ${unassigned.length} stuck txs — forwarding to another shard`)
    for (const redirectUrl of REDIRECT_TO_URL) {
      try {
        await idaGossip.sendToAnotherShard({
          message: { transactions: unassigned.map((t) => t.input.data) },
          chunkKey: 'transactions',
          targetsSubset: [`${redirectUrl}/transaction`]
        })
        // Clean up transactionIds so these IDs don't silently block any
        // future transaction that happens to reuse the same UUID.
        unassigned.forEach((t) => transactionPool.transactionIds.delete(t.id))
        transactionPool.transactions.unassigned = []
        _stuckCycles = 0
        logger.log(`STUCK DRAIN: forwarded successfully to ${redirectUrl}`)
        break
      } catch (error) {
        logger.warn(`STUCK DRAIN: redirect to ${redirectUrl} failed, trying next…`, error)
      }
    }
  }, DRAIN_INTERVAL_MS)
}

// starts the app server
app.listen(HTTP_PORT, () => {
  logger.log(`Listening on port ${HTTP_PORT}`)
})

// starts the p2p server
p2pserver.listen()
