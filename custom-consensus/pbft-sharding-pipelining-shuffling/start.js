const fs = require('fs')
const Coreserver = require('./services/coreserver')
const Blockchain = require('./services/blockchain')
// Create a write stream to your desired log file
const logStream = fs.createWriteStream('server.log', { flags: 'a' }) // 'a' = append

// Redirect console.log and console.error
console.log = function (...arguments_) {
  logStream.write(`[LOG ${new Date().toISOString()}] ${arguments_.join(' ')}\n`)
  process.stdout.write(`[LOG] ${arguments_.join(' ')}\n`) // Optional: also log to terminal
}

console.error = function (...arguments_) {
  logStream.write(
    `[ERROR ${new Date().toISOString()}] ${arguments_.join(' ')}\n`
  )
  process.stderr.write(`[ERROR] ${arguments_.join(' ')}\n`)
}

// ulimit -n 1228800
// sudo sysctl -w kern.maxfiles=1228800
// sudo sysctl -w kern.maxfilesperproc=614400
// for port in {3001..3032}; do lsof -ti tcp:$port; done | xargs -r kill -9
const NUMBER_OF_NODES = 8
const TRANSACTION_THRESHOLD = 20
const ACTIVE_SUBSET_OF_NODES = 4

let coreServerPort
let coreserver
function initCoreServer() {
  const blockchain = new Blockchain(undefined, undefined, true)
  coreServerPort = 4999
  coreserver = new Coreserver(coreServerPort, blockchain)
  // starts the p2p server
  coreserver.listen()
}

initCoreServer()

const nodesSubsets = coreserver.getRandomIndicesArrays(
  Array.from({ length: NUMBER_OF_NODES }, (_, index) => index)
)
console.log(nodesSubsets)
nodesSubsets.forEach((nodesSubset, subsetIndex) => {
  console.log(
    'Subset PBFT nodes:',
    nodesSubset.map((index) => '500' + (parseInt(index, 10) + 1))
  )
  for (let index = 0; index < NUMBER_OF_NODES; index++) {
    const environmentVariables = {
      ...process.env, // Keep existing environment variables
      SECRET: `NODE${index}`,
      P2P_PORT: 5001 + index,
      HTTP_PORT: 3001 + index,
      TRANSACTION_THRESHOLD,
      NUMBER_OF_NODES: ACTIVE_SUBSET_OF_NODES,
      NODES_SUBSET: JSON.stringify(nodesSubset),
      SUBSET_INDEX: `SUBSET${subsetIndex + 1}`,
      CORE: `ws://localhost:${coreServerPort}`
    }

    let promise
    if (index > 0) {
      const peers = Array.from(
        { length: index },
        (_, index_) => `ws://localhost:500${index_ + 1}`
      )
      let peersSubset = []
      nodesSubset.forEach((index) => {
        if (index in peers) {
          peersSubset.push(peers[index])
        }
      })
      if (peersSubset.length > 0 && nodesSubset.includes(index)) {
        console.log(`Peers for ${5001 + index}: `, peersSubset)
        promise = Promise.all(
          peersSubset.map((peer) =>
            coreserver.waitForWebServer(peer.replace('ws', 'http').replace('500', '300'))
          )
        )
        environmentVariables.PEERS = peersSubset.join(',')
      }
    }

    if (nodesSubset.includes(index)) {
      if (promise) {
        promise
          .then(() => {
            coreserver.initP2pServer(environmentVariables)
            if (index == NUMBER_OF_NODES - 1) {
              console.log(
                '########################...All set! Ready for testing...########################'
              )
            }
            return true
          })
          .catch((error) => {
            console.error('P2P server init failure', error)
          })
      } else {
        coreserver.initP2pServer(environmentVariables)
        if (index == NUMBER_OF_NODES - 1) {
          console.log(
            '########################...All set! Ready for testing...########################'
          )
        }
      }
    }
  }
})
