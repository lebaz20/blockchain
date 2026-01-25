// import the ws module
const WebSocket = require("ws");
const MESSAGE_TYPE = require("../constants/message");
const { SHARD_STATUS } = require("../constants/status");
const config = require('../config')

class Coreserver {
  constructor(port, blockchain, idaGossip) {
    this.port = port;
    this.sockets = {};
    this.socketsMap = {};
    this.blockchain = blockchain;
    this.rates = {};
    this.idaGossip = idaGossip;
    this.config = config.get()
  }

  // Creates a server on a given port
  listen() {
    const server = new WebSocket.Server({ port: this.port });
    console.log(`Listening on port ${this.port}`);
    server.on("connection", (socket, request) => {
      const parsedUrl = new URL(request.url, `http://${request.headers.host}`);
      const subsetIndex = parsedUrl.searchParams.get("subsetIndex");
      const port = parsedUrl.searchParams.get("port");
      const httpPort = parsedUrl.searchParams.get("httpPort");
      this.connectSocket(socket, port, subsetIndex, httpPort);
      this.messageHandler(socket, false);
      console.log("core sockets", JSON.stringify(this.socketsMap));
    });
  }

  // connects to a given socket and registers the message handler on it
  connectSocket(socket, port, subsetIndex, httpPort) {
    if (!this.sockets[subsetIndex]) {
      this.sockets[subsetIndex] = {};
      this.socketsMap[subsetIndex] = [];
    }
    this.sockets[subsetIndex][port] = {
      socket,
      url: `http://p2p-server-${Number(port) - 5001}:${httpPort}`,
    };
    this.socketsMap[subsetIndex].push(port);
    this.idaGossip.setNodeSockets(this.sockets);
  }

  // broadcast block
  broadcastBlock(block, subsetIndex) {
    this.idaGossip.broadcastFromCore({
      message: {
        type: MESSAGE_TYPE.block_from_core,
        block,
        subsetIndex,
      },
      chunkKey: 'block',
      sendersSubsetIndex: subsetIndex
    });
  };

  // update config
  updateConfig(config, subsetIndex) {
    this.idaGossip.sendFromCoreToSpecificShard({
      message: {
        type: MESSAGE_TYPE.config_from_core,
        config,
      },
      targetsSubsetIndex: subsetIndex
    });
  }

  // handles any message sent to the current node
  messageHandler(socket) {
    // registers message handler
    socket.on("message", async (message) => {
      if (Buffer.isBuffer(message)) {
        message = message.toString(); // Convert Buffer to string
      }
      const receivedData = JSON.parse(message);
      const data = this.idaGossip.handleChunk(receivedData);
      console.log(this.port, "RECEIVED", data.type);

      // select a particular message handler
      switch (data.type) {
        case MESSAGE_TYPE.block_to_core:
          // add updated block to chain
          if (
            !this.blockchain.existingBlock(data.block.hash, data.subsetIndex)
          ) {
            this.blockchain.addBlock(
              data.block,
              data.subsetIndex,
            );
            const stats = { total: this.blockchain.getTotal(), rate: this.rates };
            console.log(`CORE TOTAL:`, JSON.stringify(stats));
            this.broadcastBlock(data.block, data.subsetIndex);
          }
          break;
        case MESSAGE_TYPE.rate_to_core:
          // collect shards rates
          if (
            !this.rates[data.rate.shardIndex] || this.rates[data.rate.shardIndex].transactions < data.rate.transactions[data.rate.shardIndex]
          ) {
            this.rates[data.rate.shardIndex] = {
              transactions: data.rate.transactions?.[data.rate.shardIndex],
              blocks: data.rate.blocks?.[data.rate.shardIndex],
              shardStatus: data.rate.shardStatus
            };
            const { SHOULD_REDIRECT_FROM_FAULTY_NODES } = this.config.get();
            if (SHOULD_REDIRECT_FROM_FAULTY_NODES) {
            const shardStatusMap = {};
            Object.values(SHARD_STATUS).forEach((status) => {
              shardStatusMap[status] = Object.entries(this.rates)
              .filter(([, rate]) => rate.shardStatus === status)
              .map(([shardIndex]) => shardIndex);
            });
            // Build mapping for faulty shards
            const faultyShards = shardStatusMap[SHARD_STATUS.faulty] || [];
            const underUtilizedShards = shardStatusMap[SHARD_STATUS.under_utilized] || [];
            const normalShards = shardStatusMap[SHARD_STATUS.normal] || [];
            const overUtilizedShards = shardStatusMap[SHARD_STATUS.over_utilized] || [];

            const assignedIndices = new Set();
            const faultyShardRedirectAssignment = {};

            faultyShards.forEach((faultyShardIndex) => {
              let candidates = underUtilizedShards.filter(index => !assignedIndices.has(index));
              let status = SHARD_STATUS.under_utilized;
              if (candidates.length === 0) {
              candidates = normalShards.filter(index => !assignedIndices.has(index));
              status = SHARD_STATUS.normal;
              }
              if (candidates.length === 0) {
              candidates = overUtilizedShards.filter(index => !assignedIndices.has(index));
              status = SHARD_STATUS.over_utilized;
              }
              if (candidates.length > 0) {
              const randomIndex = Math.floor(Math.random() * candidates.length);
              const selected = candidates[randomIndex];
              assignedIndices.add(selected);
              faultyShardRedirectAssignment[faultyShardIndex] = { redirectSubset: selected, status };
              }
            });

            // faultyShardRedirectAssignment now contains mapping: { faultyShardIndex: { redirectSubset: mappedIndex, status: mappedStatus } }
            Object.entries(faultyShardRedirectAssignment).forEach(([faultyShardIndex, { redirectSubset }]) => {
              // Collect all URLs in the redirectSubset
              let redirectUrls = [];
              if (this.sockets[redirectSubset]) {
                redirectUrls = Object.values(this.sockets[redirectSubset]).map(object => object.url);
                const config = [{
                  key: 'REDIRECT_TO_URL',
                  value: redirectUrls,
                }];
                this.updateConfig(config, faultyShardIndex);
              }
            });
            [ ...underUtilizedShards, ...normalShards, ...overUtilizedShards].forEach((shardIndex) => {
              const config = [{
                key: 'REDIRECT_TO_URL',
                value: [],
              }];
              this.updateConfig(config, shardIndex);
            });
          }
        }
          console.log(`CORE RATE:`, JSON.stringify(this.rates));
          console.log(`CORE TOTAL:`, JSON.stringify(data.total));
          break;
      }
    });
  }
}

module.exports = Coreserver;
