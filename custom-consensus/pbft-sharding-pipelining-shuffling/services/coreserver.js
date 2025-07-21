// import the ws module
const WebSocket = require("ws");
const MESSAGE_TYPE = require("../constants/message");

class Coreserver {
  constructor(port, blockchain) {
    this.port = port;
    this.sockets = {};
    this.socketsMap = {};
    this.blockchain = blockchain;
    this.rates = {};
  }

  // Creates a server on a given port
  listen() {
    const server = new WebSocket.Server({ port: this.port });
    console.log(`Listening on port ${this.port}`);
    server.on("connection", (socket, request) => {
      const parsedUrl = new URL(request.url, `http://${request.headers.host}`);
      const subsetIndex = parsedUrl.searchParams.get("subsetIndex");
      const port = parsedUrl.searchParams.get("port");
      this.connectSocket(socket, port, subsetIndex);
      this.messageHandler(socket);
      console.log("core sockets", JSON.stringify(this.socketsMap));
    });
  }

  // connects to a given socket and registers the message handler on it
  connectSocket(socket, port, subsetIndex) {
    if (!this.sockets[subsetIndex]) {
      this.sockets[subsetIndex] = {};
      this.socketsMap[subsetIndex] = [];
    }
    this.sockets[subsetIndex][port] = socket;
    this.socketsMap[subsetIndex].push(port);
  }

  getOtherSubsets(subsetIndex) {
    const sockets = [];
    Object.keys(this.sockets)
      .filter((socketSubsetIndex) => socketSubsetIndex != subsetIndex)
      .forEach((socketSubsetIndex) => {
        Object.keys(this.sockets[socketSubsetIndex]).forEach((socketPort) => {
          const socket = this.sockets[socketSubsetIndex][socketPort];
          sockets.push(socket);
        });
      });
    return sockets;
  }

  // broadcast block
  broadcastBlock(block, subsetIndex) {
    const sockets = this.getOtherSubsets(subsetIndex);
    sockets.forEach((socket) => {
      this.sendBlock(socket, block, subsetIndex);
    });
  }

  // sends block to a particular socket
  sendBlock(socket, block, subsetIndex) {
    socket.send(
      JSON.stringify({
        type: MESSAGE_TYPE.block_from_core,
        block,
        subsetIndex,
      }),
    );
  }

  // handles any message sent to the current node
  messageHandler(socket) {
    // registers message handler
    socket.on("message", async (message) => {
      if (Buffer.isBuffer(message)) {
        message = message.toString(); // Convert Buffer to string
      }
      const data = JSON.parse(message);

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
              transactions: data.rate.transactions[data.rate.shardIndex],
              blocks: data.rate.blocks[data.rate.shardIndex],
              shardStatus: data.rate.shardStatus 
            };
          }
          console.log(`CORE STATS:`, JSON.stringify(this.rates));
          break;
      }
    });
  }
}

module.exports = Coreserver;
