// Import all required models
const express = require("express");
const axios = require("axios");
const bodyParser = require("body-parser");
const { NODES_SUBSET, SUBSET_INDEX } = require("./config");
const Wallet = require("./services/wallet");
const P2pserver = require("./services/p2pserver");
const Validators = require("./services/validators");
const Blockchain = require("./services/blockchain");
const TransactionPool = require("./services/pools/transaction");
const BlockPool = require("./services/pools/block");
const CommitPool = require("./services/pools/commit");
const PreparePool = require("./services/pools/prepare");
const MessagePool = require("./services/pools/message");
const MESSAGE_TYPE = require("./constants/message");

const HTTP_PORT = process.env.HTTP_PORT || 3001;
const REDIRECT_TO_PORT = process.env.REDIRECT_TO_PORT;

// Instantiate all objects
const app = express();
app.use(bodyParser.json());

const wallet = new Wallet(process.env.SECRET);
const transactionPool = new TransactionPool();
const validators = new Validators(NODES_SUBSET);
const blockchain = new Blockchain(validators, transactionPool);
const blockPool = new BlockPool();
const preparePool = new PreparePool();
const commitPool = new CommitPool();
const messagePool = new MessagePool();
const p2pserver = new P2pserver(
  blockchain,
  transactionPool,
  wallet,
  blockPool,
  preparePool,
  commitPool,
  messagePool,
  validators,
);

// sends all transactions in the transaction pool to the user
app.get("/transactions", (request, response) => {
  response.json(transactionPool.transactions);
});

// sends the entire chain to the user
app.get("/blocks", (request, response) => {
  response.json(blockchain.chain);
});

// sends the chain stats to the user
app.get("/stats", (request, response) => {
  const stats = {
    total: blockchain.getTotal(),
    rate: blockchain.getRate(),
    unassignedTransactions: transactionPool.transactions.unassigned.length,
  };
  console.log(`REQUEST STATS FOR #${SUBSET_INDEX}:`, JSON.stringify(stats));
  response.json(stats);
});

// check server health
app.get("/health", (request, response) => {
  response.status(200).send("Ok");
});

// creates transactions for the sent data
app.post("/transaction", async (request, response) => {
  if (REDIRECT_TO_PORT) {
    console.log(`Redirect from ${HTTP_PORT} to ${REDIRECT_TO_PORT}`);
    try {
      const redirectResponse = await axios({
        method: request.method,
        url: `${REDIRECT_TO_PORT}/transaction`,
        // headers: req.headers,
        data: request.body,
      });
      response.status(redirectResponse.status).send(redirectResponse.data);
    } catch (error) {
      response.status(error.response?.status || 500).send(error.message);
    }
  } else {
    const data = request.body;
    console.log(`Processing transaction on ${HTTP_PORT}`);
    const transaction = wallet.createTransaction(data);
    p2pserver.broadcastTransaction(transaction);
    p2pserver.parseMessage({ type: MESSAGE_TYPE.transaction, transaction });
    response.redirect("/stats");
  }
});

// starts the app server
app.listen(HTTP_PORT, () => {
  console.log(`Listening on port ${HTTP_PORT}`);
});

// starts the p2p server
p2pserver.listen();
