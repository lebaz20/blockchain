// Import all required models
const express = require('express')
const bodyParser = require('body-parser')
const axios = require('axios')
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

const HTTP_PORT = process.env.HTTP_PORT || 3001
const P2P_PORT = process.env.P2P_PORT || 5001
const { NODES_SUBSET, SUBSET_INDEX } = config.get()

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
  try {
    const data = request.body.transactions ? request.body.transactions : [request.body]
    // Respond immediately — defer all CPU work (signing, hashing, P2P fan-out)
    // to after the HTTP round-trip so JMeter threads are not blocked by ECDSA crypto.
    response.json({ ok: true })
    setImmediate(() => {
      for (const item of data) {
        logger.debug(`Processing transaction on ${HTTP_PORT}`, JSON.stringify(item))
        const transaction = wallet.createTransaction(item)
        p2pserver.parseMessage({
          type: MESSAGE_TYPE.transactions,
          transactions: [transaction],
          port: P2P_PORT
        })
      }
    })
  } catch (error) {
    logger.warn(`Transaction processing error on ${HTTP_PORT}:`, error)
    response.json({ ok: true })
  }
})

// parse message
app.post('/message', async (request, response) => {
  logger.log(`Processing message on ${HTTP_PORT}`, JSON.stringify(request.body))
  p2pserver.parseMessage(request.body)
  response.status(200).send('Ok')
})

// Proactive redirect drain: every DRAIN_INTERVAL_MS, if this shard has accumulated
// unassigned transactions AND the core has assigned a redirect target, forward up to
// TRANSACTION_THRESHOLD transactions to that target.
//
// Design:
//   • Broken shards always buffer TX locally (no immediate redirect on receipt).
//   • Every 500 ms the timer fires; if a redirect URL is set it forwards one batch of
//     up to TRANSACTION_THRESHOLD TX — enough for one full block on the target shard.
//   • If the URL is empty (all healthy shards over-utilized) TX sit in pool until
//     a healthy shard cools down and the core re-assigns a redirect URL.
// Net effect: at most one block's worth of extra load is added to the target per
// drain cycle (200 TX/s capacity per broken shard vs the ~17 TX/s it receives at
// 100 req/s load), so the backlog clears within seconds rather than accumulating.
//
// Jitter: each node delays its first tick by a random amount in [0, DRAIN_INTERVAL_MS)
// so that broken-shard nodes whose Kubernetes pods start within milliseconds of each
// other do NOT all fire simultaneously, preventing synchronized TX bursts on the
// healthy shard that would trigger unnecessary view-change timeouts.
{
  const DRAIN_INTERVAL_MS = 500
  const startupJitter = Math.floor(Math.random() * DRAIN_INTERVAL_MS)

  const drainOnce = async () => {
    const { IS_FAULTY, REDIRECT_TO_URL, SHOULD_REDIRECT_FROM_FAULTY_NODES, DRAIN_BATCH_SIZE } =
      config.get()
    if (
      IS_FAULTY ||
      !SHOULD_REDIRECT_FROM_FAULTY_NODES ||
      !Array.isArray(REDIRECT_TO_URL) ||
      !REDIRECT_TO_URL.length
    )
      return

    const unassigned = transactionPool.transactions.unassigned
    if (!unassigned.length) return

    const batchSize = Math.min(DRAIN_BATCH_SIZE, unassigned.length)

    // Snapshot and remove from pool BEFORE yielding to the event loop so concurrent
    // handlers cannot pick up the same transactions.
    const toForward = unassigned.splice(0, batchSize)
    toForward.forEach((t) => transactionPool.transactionIds.delete(t.id))

    logger.log(
      `REDIRECT DRAIN: forwarding ${toForward.length} txs (batch cap ${DRAIN_BATCH_SIZE}, ` +
        `${unassigned.length} remaining)`
    )

    let forwarded = false
    for (const redirectUrl of REDIRECT_TO_URL) {
      try {
        await axios.post(`${redirectUrl}/transaction`, {
          transactions: toForward.map((t) => t.input.data)
        })
        forwarded = true
        break
      } catch (error) {
        logger.warn(`REDIRECT DRAIN: redirect to ${redirectUrl} failed, trying next…`, error)
      }
    }

    // All redirect URLs failed — restore items so the next cycle can retry.
    if (!forwarded) {
      toForward.forEach((t) => transactionPool.transactionIds.add(t.id))
      transactionPool.transactions.unassigned.unshift(...toForward)
      logger.warn('REDIRECT DRAIN: all redirect URLs failed, restored pool for next cycle')
    }
  }

  // Delay the first tick by a random jitter, then settle into a fixed interval.
  // This prevents all broken-shard nodes (which start nearly simultaneously under
  // Kubernetes) from firing their drain timers in lock-step.
  setTimeout(() => {
    drainOnce()
    setInterval(drainOnce, DRAIN_INTERVAL_MS)
  }, startupJitter)
}

// starts the app server
app.listen(HTTP_PORT, () => {
  logger.log(`Listening on port ${HTTP_PORT}`)
})

// starts the p2p server
p2pserver.listen()
