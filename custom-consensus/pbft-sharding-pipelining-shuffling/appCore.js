const Coreserver = require('./services/coreserver')
const Blockchain = require('./services/blockchain')

function initCoreServer() {
  const blockchain = new Blockchain(undefined, undefined, true)
  const coreServerPort = 4999
  const coreserver = new Coreserver(coreServerPort, blockchain)
  // starts the p2p server
  coreserver.listen();
}

initCoreServer()