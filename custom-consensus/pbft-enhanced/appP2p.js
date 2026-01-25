// Import all required models
const express = require('express')
const bodyParser = require('body-parser')
const config = require('./config')
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

const HTTP_PORT = process.env.HTTP_PORT || 3001;
const P2P_PORT = process.env.P2P_PORT || 5001;
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
const idaGossip = new IDAGossip();
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
  const stats = {
    total: blockchain.getTotal(),
    rate,
  }
  console.log(`REQUEST STATS FOR #${SUBSET_INDEX}:`, JSON.stringify(stats))
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
  if (!IS_FAULTY && SHOULD_REDIRECT_FROM_FAULTY_NODES && Array.isArray(REDIRECT_TO_URL) && REDIRECT_TO_URL.length > 0) {
    let lastError = null
    for (const redirectUrl of REDIRECT_TO_URL) {
      console.log(`Redirect from ${HTTP_PORT} to ${redirectUrl}`)
      try {
        await idaGossip.sendToAnotherShard({
          message: { transactions: hasUnassignedTransactions ? [...unassignedTransactions.map(transaction => transaction.input.data), request.body] : request.body },
          chunkKey: 'transactions',
          targetsSubset: [`${redirectUrl}/transaction`],
        })
        if (hasUnassignedTransactions) {
          transactionPool.transactions.unassigned = [];
        }
        // If successful, return the response immediately
        return response.status(200)
      } catch (error) {
        lastError = error
        // Try next redirectUrl in the array
        console.warn(`Redirect to ${redirectUrl} failed:`, error)
      }
    }
    // If all redirects fail, return the last error
    return response
      .status(lastError?.response?.status || 500)
      .send(lastError?.message || 'All redirects failed')
  } else {
    const data = request.body.transactions ? request.body.transactions : [request.body]
    data.forEach((item) => {
      console.log(`Processing transaction on ${HTTP_PORT}`, JSON.stringify(item))
      const transaction = wallet.createTransaction(item)
      p2pserver.broadcastTransaction(P2P_PORT, transaction)
      p2pserver.parseMessage({ type: MESSAGE_TYPE.transaction, transaction })

      /**
       * Simulate block verification by random shards
       * We need then to mark faulty shards and exclude them from the network activities
       */
      const duplicateTransaction = wallet.createTransaction(item)
      p2pserver.broadcastTransaction(P2P_PORT, duplicateTransaction)
      p2pserver.parseMessage({ type: MESSAGE_TYPE.transaction, transaction: duplicateTransaction })
    })
    response.redirect('/stats')
  }
})

// parse message
app.post('/message', async (request, response) => {
    console.log(`Processing message on ${HTTP_PORT}`, JSON.stringify(request.body))
    p2pserver.parseMessage(request.body)
    response.status(200).send('Ok')
})

// starts the app server
app.listen(HTTP_PORT, () => {
  console.log(`Listening on port ${HTTP_PORT}`)
})

// starts the p2p server
p2pserver.listen()
