// Import all required models
const express = require("express");
const axios = require("axios");
const fs = require('fs');
const bodyParser = require("body-parser");
const { NODES_SUBSET, SUBSET_INDEX, CPU_LIMIT } = require("./config");
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

const readCgroupCPUPercentPromise = (interval = 1000) => {
  const usagePathV1 = '/sys/fs/cgroup/cpuacct/cpuacct.usage';
  const usagePathV2 = '/sys/fs/cgroup/cpu.stat';
  let usagePath;
  let isV2 = false;
  if (fs.existsSync(usagePathV1)) {
    usagePath = usagePathV1;
  } else if (fs.existsSync(usagePathV2)) {
    usagePath = usagePathV2;
    isV2 = true;
  } else {
    return Promise.reject('No cgroup CPU usage file found');
  }

  function getUsage(path, v2) {
    const content = fs.readFileSync(path, 'utf8');
    if (v2) {
      // Find usage_usec value and convert to nanoseconds
      const match = content.match(/usage_usec (\d+)/);
      if (match) {
        return parseInt(match[1], 10) * 1000;
      }
      throw new Error('usage_usec not found in cpu.stat');
    } else {
      return parseInt(content.trim(), 10);
    }
  }

  return new Promise((resolve, reject) => {
    let startUsage;
    let startTime;
    try {
      startUsage = getUsage(usagePath, isV2);
      startTime = process.hrtime.bigint();
    } catch (error) {
      return reject('Error reading cgroup cpu usage: ' + error.message);
    }

    setTimeout(() => {
      try {
        const endUsage = getUsage(usagePath, isV2);
        const endTime = process.hrtime.bigint();

        const cpuUsed = endUsage - startUsage; // nanoseconds
        const wallClock = Number(endTime - startTime); // nanoseconds
        const percent = wallClock > 0 ? (cpuUsed / wallClock) * 100 : 0;

        // Read CPU limit from cgroup (if available)
        let cpuLimit = Number(CPU_LIMIT);
        const cpuLimitPathV1 = '/sys/fs/cgroup/cpuacct/cpu.cfs_quota_us';
        const cpuPeriodPathV1 = '/sys/fs/cgroup/cpuacct/cpu.cfs_period_us';
        const cpuLimitPathV2 = '/sys/fs/cgroup/cpu.max';

        if (fs.existsSync(cpuLimitPathV1) && fs.existsSync(cpuPeriodPathV1)) {
          const quota = parseInt(fs.readFileSync(cpuLimitPathV1, 'utf8').trim(), 10);
          const period = parseInt(fs.readFileSync(cpuPeriodPathV1, 'utf8').trim(), 10);
          if (quota > 0 && period > 0) {
            cpuLimit = quota / period;
          }
        } else if (fs.existsSync(cpuLimitPathV2)) {
          const cpuMax = fs.readFileSync(cpuLimitPathV2, 'utf8').trim();
          const [quotaString, periodString] = cpuMax.split(' ');
          const quota = quotaString === 'max' ? -1 : parseInt(quotaString, 10);
          const period = parseInt(periodString, 10);
          if (quota > 0 && period > 0) {
            cpuLimit = quota / period;
          }
        }
        
        // Calculate percentage of CPU limit used
        let cpuPercentOfLimit = percent;
        if (cpuLimit > 0) {
          cpuPercentOfLimit = ((parseFloat(percent) / 100) * 100 / cpuLimit).toFixed(2);
        }

        resolve(cpuPercentOfLimit); // returns percentage as string
      } catch (error) {
        reject('Error reading cgroup cpu usage: ' + error.message);
      }
    }, interval);
  });
}

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
app.get("/stats", async (request, response) => {
  const cpuPercentage = await readCgroupCPUPercentPromise(1000);
  const stats = {
    total: blockchain.getTotal(),
    rate: blockchain.getRate(),
    unassignedTransactions: transactionPool.transactions.unassigned.length,
    cpu: `${cpuPercentage}%`,
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
