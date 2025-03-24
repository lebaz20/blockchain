const { spawn } = require("child_process");
const axios = require("axios");

// ulimit -n 1228800
// sudo sysctl -w kern.maxfiles=1228800
// sudo sysctl -w kern.maxfilesperproc=614400
const NUMBER_OF_NODES = 8;
const TRANSACTION_THRESHOLD = 10;
const ACTIVE_SUBSET_OF_NODES = 0.5;

// phase 1 -> [DONE]: Use subset of validators all the time
// phase 2 -> Track faulty nodes and do not use them later
// phase 3 -> Randomly switch between subset and all validators
// phase 4 -> Weigh towards subset more

function getRandomIndices(array) {
  const indices = Array.from({ length: array.length }, (_, i) => i);
  return indices.sort(() => 0.5 - Math.random()).slice(0, Math.floor(ACTIVE_SUBSET_OF_NODES * array.length));
}

function waitForWebServer(url, retryInterval = 1000) {
  return new Promise((resolve) => {
    function checkWebServer() {
      axios.get(url + '/health')
        .then(() => {
          console.log(`WebServer is open: ${url}`);
          resolve(true);
        })
        .catch(() => {
          // console.log(`WebServer ${url} not available, retrying...`);
          setTimeout(checkWebServer, retryInterval + 1000);
        })
    }

    checkWebServer();
  });
}

function initServer(env) {
  const serverProcess = spawn("node", ["app.js"], {
    stdio: "inherit",
    env
  });
  
  serverProcess.on("close", (code) => {
    console.log(`Server exited with code ${code}`);
  });
}

const nodesSubset = getRandomIndices(Array.from({ length: NUMBER_OF_NODES }, (_, i) => i));
console.log('Subset PBFT nodes:', nodesSubset.map(i => "500" + (parseInt(i, 10) + 1)));
for (let index = 0; index < NUMBER_OF_NODES; index++) {
  const envVars = {
    ...process.env, // Keep existing environment variables
    SECRET: `NODE${index}`,
    P2P_PORT: 5001 + index,
    HTTP_PORT: 3001 + index,
    TRANSACTION_THRESHOLD,
    NUMBER_OF_NODES: Math.floor(ACTIVE_SUBSET_OF_NODES * NUMBER_OF_NODES),
    NODES_SUBSET: JSON.stringify(nodesSubset)
  };

  let promise;
  if (index > 0) {
    const peers = Array.from({ length: index }, (_, i) => `ws://localhost:500${i+1}`);
    let peersSubset = [];
    nodesSubset.forEach(index => {
      if (index in peers) {
        peersSubset.push(peers[index]);
      }
    });
    if (peersSubset.length > 0 && nodesSubset.includes(index)) {
      console.log(`Peers for ${5001 + index}: `, peersSubset);
      promise = Promise.all(peersSubset.map(peer => waitForWebServer(peer.replace('ws', 'http').replace('5', '3'))));
      envVars.PEERS = peersSubset.join(",");
    }
  }

  if (!nodesSubset.includes(index)) {
    envVars.REDIRECT_TO_PORT = 3001 + nodesSubset[Math.floor(Math.random() * nodesSubset.length)];
  }
  

  if (promise) {
    promise.then(() => {
      initServer(envVars)
      if (index == NUMBER_OF_NODES - 1) {
        console.log("########################...All set! Ready for testing...########################");
      }
    });
  } else {
    initServer(envVars);
    if (index == NUMBER_OF_NODES - 1) {
      console.log("########################...All set! Ready for testing...########################");
    }
  }
}