const crypto = require('crypto-js');
const config = require("../config");
const axios = require('axios')
const { v1: uuidv1 } = require("uuid");

const { NUMBER_OF_NODES, DEFAULT_TTL, NUMBER_OF_NODES_PER_SHARD } = config.get();

class IDAGossip {
  constructor() {
    this.fileChunks = new Map(); // Store received chunks
    this.socketGossipPeers; // Connected peers
    this.socketGossipCore; // Connected Core
  }

  setPeerSockets(sockets) {
    this.socketGossipPeers = sockets;
  }

  setCoreSocket(socket) {
    this.socketGossipCore = socket;
  }

  getSocketGossipPeers(senderPort) {
    return Object.keys(this.socketGossipPeers).filter((port) => port !== senderPort).map((port) => this.socketGossipPeers[port].socket);
  }

  getHTTPGossipPeers(sendersSubset) {
    return Array.from({ length: NUMBER_OF_NODES }, (_, index) => index)
      .filter(number_ => !sendersSubset.includes(number_)).map(number_ => `http://p2p-server-${number_}:${3001 + number_}/message`);
  }

  // Split data into IDA chunks
  splitData(data, customTotalChunks, customRequiredChunks) {
    const jsonString = JSON.stringify(data);
    const fileBuffer = Buffer.from(jsonString, 'utf8');

    const fileSizeKB = fileBuffer.length / 1024;
    let totalChunks, requiredChunks;
    
    if (customTotalChunks && customRequiredChunks) {
        totalChunks = customTotalChunks;
        requiredChunks = customRequiredChunks;
    } else {
        // Mathematical approach: linear scaling with file size
        // General Guidelines
        //     HTTP requests: 1-8KB for optimal performance
        //     WebSocket messages: 1-16KB per message
        //     UDP packets: < 1500 bytes (MTU limit)
        //     TCP segments: 1-64KB (but smaller is faster)
        // Performance Considerations
        //     < 1KB: Excellent performance, minimal latency
        //     1-8KB: Good performance for most networks
        //     8-64KB: Acceptable but may cause delays
        //     > 64KB: Risk of fragmentation and timeouts
        requiredChunks = Math.max(2, Math.ceil(fileSizeKB / 5));
        
        // Total chunks = required chunks + redundancy (50% more)
        totalChunks = Math.ceil(requiredChunks * 1.5);
    }

    const fileHash = crypto.SHA256(fileBuffer).toString();
    const chunkSize = Math.ceil(fileBuffer.length / requiredChunks);
    const chunks = [];
    
    // Simple chunking (real IDA would use Reed-Solomon encoding)
    for (let index = 0; index < requiredChunks; index++) {
        const start = index * chunkSize;
        const end = Math.min(start + chunkSize, fileBuffer.length);

        chunks.push({
            id: uuidv1(),
            index: index,
            data: fileBuffer.subarray(start, end),
            totalChunks: requiredChunks,
            fileHash
        });
    }
    
    // Add redundant chunks for fault tolerance
    for (let index = requiredChunks; index < totalChunks; index++) {
        const randomIndex = Math.floor(Math.random() * requiredChunks);
        chunks.push({
            id: uuidv1(),
            index: randomIndex,
            data: chunks[randomIndex].data, // Simple redundancy
            totalChunks: requiredChunks,
            fileHash
        });
    }
    
    return chunks;
  }

  sendSocketMessage(socket, data) {
    return new Promise((resolve, reject) => {
        socket.send(data, (error) => {
        if (error) reject(error);
        else resolve();
        });
    });
    }

  // Gossip chunk to random peers
  gossipChunk(message, ttl = DEFAULT_TTL) {
    if (ttl <= 0) return;

    const { communicationType, sendersSubset, targetsSubset, shouldGossip, senderPort } = message;
    let peers;
    if (communicationType === 'http') {
        peers = targetsSubset ?? this.getHTTPGossipPeers(sendersSubset);
    } else if (targetsSubset === 'core') {
        peers = this.socketGossipCore;
    } else {
        peers = this.getSocketGossipPeers(senderPort);
    }
    const randomPeers = shouldGossip ? peers.sort(() => 0.5 - Math.random()).slice(0, 4) : peers;
    
    const requests = randomPeers.map(peer => {
        const messageToSend = {
              ...message,
              ttl: ttl - 1,
            }
        if (communicationType === 'http') {
            return axios({
                method: 'post',
                url: peer,
                data: messageToSend
            })
        } else  {
            return this.sendSocketMessage(peer, JSON.stringify(messageToSend));
        }
    });
    return Promise.all(requests)
  }

  calculateTTL(numberNodes) {
    return Math.ceil(1.85 * Math.log10(numberNodes) - 0.67);
  }

  sendToShardPeers({
    message,
    chunkKey,
    senderPort
  }) {
    return this.sendData({
        message,
        chunkKey,
        senderPort,
        communicationType: 'ws',
        sendersSubset: [],
        targetsSubset: [],
        shouldGossip: NUMBER_OF_NODES_PER_SHARD > 4,
        ttl: this.calculateTTL(NUMBER_OF_NODES_PER_SHARD)
    });
  }

  sendToAnotherShard({
    message,
    chunkKey,
    targetsSubset,
  }) {
    return this.sendData({
        message,
        chunkKey,
        communicationType: 'http',
        sendersSubset: [],
        targetsSubset,
        shouldGossip: NUMBER_OF_NODES_PER_SHARD > 4,
        ttl: this.calculateTTL(NUMBER_OF_NODES_PER_SHARD)
    });
  }

  sendFromCore({
    message,
    chunkKey,
    sendersSubset
  }) {
    return this.sendData({
        message,
        chunkKey,
        communicationType: 'http',
        sendersSubset,
        targetsSubset: [],
        shouldGossip: true,
        ttl: this.calculateTTL(NUMBER_OF_NODES)
    });
  }

  sendToCore({
    message,
    chunkKey
  }) {
    return this.sendData({
        message,
        chunkKey,
        communicationType: 'ws',
        sendersSubset: [],
        targetsSubset: 'core',
        shouldGossip: false
    });
  } 

  // Send large data using IDA gossip
  sendData({
    message,
    communicationType,
    sendersSubset,
    targetsSubset,
    chunkKey,
    shouldGossip,
    senderPort,
    ttl = DEFAULT_TTL
  }) {
    const chunks = chunkKey ? this.splitData(message[chunkKey]) : [message];

    // Wait for all gossipChunk promises to resolve
    const promises =  chunks.map((chunk, index) => {
        const message = {
            ...message,
            sendersSubset,
            communicationType,
            targetsSubset,
            shouldGossip,
            senderPort
        }
        if (chunkKey) {
            message[chunkKey] = chunk;
        }
        // Stagger chunk sending to avoid overwhelming network
        return new Promise(resolve => {
            setTimeout(() => {
                resolve(this.gossipChunk(message, ttl));
            }, index * 100);
        });
    });
    return Promise.all(promises);
  }

  // Handle incoming chunk
  handleChunk(message) {
    const { ttl, shouldGossip, chunkKey: originalChunkKey } = message;

    if (originalChunkKey) {
        const chunk = message[originalChunkKey];
        // Store chunk if not already received
        const chunkKey = `${chunk.fileHash}-${chunk.index}`;
        if (!this.fileChunks.has(chunkKey)) {
            this.fileChunks.set(chunkKey, chunk);
            
            if (shouldGossip) {
                // Continue gossiping to other peers
                this.gossipChunk(message, ttl);
            }
            
            // Check if we can reconstruct data
            const data = this.tryReconstructData(chunk.fileHash, chunk.totalChunks);
            return data ?  { ...message, [originalChunkKey]: data } : undefined;
        }
    } else {
        if (shouldGossip) {
            // Continue gossiping to other peers
            this.gossipChunk(message, ttl);
        }
        return message;
    }
    return undefined;
  }

  // Try to reconstruct data from chunks
  tryReconstructData(fileHash, totalChunks) {
    const chunks = Array.from(this.fileChunks.values())
      .filter(chunk => chunk.fileHash === fileHash)
      .sort((a, b) => a.index - b.index);
    
    if (chunks.length >= totalChunks) {
      // Take only the required chunks for reconstruction
      const requiredChunks = chunks.slice(0, totalChunks);
      const reconstructedBuffer = Buffer.concat(
        requiredChunks.map(chunk => chunk.data)
      );
      
      // Verify file integrity
      const reconstructedHash = crypto.SHA256(reconstructedBuffer).toString();
      
      if (reconstructedHash === fileHash) {
        const jsonString = reconstructedBuffer.toString('utf8');
        const data = JSON.parse(jsonString);

        // Clean up: remove all chunks for this file after successful reconstruction
        const keysToDelete = [];
        for (const [key, chunk] of this.fileChunks) {
            if (chunk.fileHash === fileHash) {
                keysToDelete.push(key);
            }
        }
        keysToDelete.forEach(key => this.fileChunks.delete(key));

        return data;
      }
    }
    
    return undefined;
  }

}

module.exports = IDAGossip;