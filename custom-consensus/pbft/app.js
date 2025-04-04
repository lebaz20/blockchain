// Import all required models
const express = require("express");
const bodyParser = require("body-parser");
const { NUMBER_OF_NODES } = require("./config");
const Wallet = require("./services/wallet");
const P2pserver = require("./services/p2pserver");
const Validators = require("./services/validators");
const Blockchain = require("./services/blockchain");
const TransactionPool = require("./services/pools/transaction");
const BlockPool = require("./services/pools/block");
const CommitPool = require("./services/pools/commit");
const PreparePool = require("./services/pools/prepare");
const MessagePool = require("./services/pools/message");
const HTTP_PORT = process.env.HTTP_PORT || 3001;

// Instantiate all objects
const app = express();
app.use(bodyParser.json());

const wallet = new Wallet(process.env.SECRET);
const transactionPool = new TransactionPool();
const validators = new Validators(NUMBER_OF_NODES);
const blockchain = new Blockchain(validators);
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
  validators
);

// sends all transactions in the transaction pool to the user
app.get("/transactions", (req, res) => {
  res.json(transactionPool.transactions);
});

// sends the entire chain to the user
app.get("/blocks", (req, res) => {
  res.json(blockchain.chain);
});

// sends the chain total to the user
app.get("/total", (req, res) => {
  const total = { total: blockchain.getTotal(), unassignedTransactions: transactionPool.transactions.length };
  console.log(`TOTAL:`, JSON.stringify(total));
  res.json(total);
});

// check server health
app.get("/health", (req, res) => {
  res.status(200).send('Ok');
});

// creates transactions for the sent data
app.post("/transaction", (req, res) => {
  const data = req.body;
  console.log(`Processing transaction on ${HTTP_PORT}`);
  const transaction = wallet.createTransaction(data);
  p2pserver.broadcastTransaction(transaction);
  res.redirect("/total");
});

// starts the app server
app.listen(HTTP_PORT, () => {
  console.log(`Listening on port ${HTTP_PORT}`);
});

// starts the p2p server
p2pserver.listen();