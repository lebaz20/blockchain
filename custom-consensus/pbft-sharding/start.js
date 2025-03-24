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

function shuffleArray(arr) {
  const copy = arr.slice(); // don't modify original
  for (let i = copy.length - 1; i > 0; i--) {
    const j = Math.floor(Math.random() * (i + 1));
    [copy[i], copy[j]] = [copy[j], copy[i]]; // swap
  }
  return copy;
}

function splitIntoFoursWithRemaining(arr) {
  const result = [];
  let i = 0;

  while ((arr.length - i) >= 4) {
    result.push(arr.slice(i, i + 4));
    i += 4;
  }

  // Last group with remaining 4 or more
  result[result.length-1] = [...result[result.length-1], ...arr.slice(i)];

  return result;
}

function getRandomIndicesArrays(array) {
  const indices = Array.from({ length: array.length }, (_, i) => i);
  return splitIntoFoursWithRemaining(shuffleArray(indices));
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

console.log(getRandomIndicesArrays(Array.from({ length: NUMBER_OF_NODES }, (_, i) => i)))
const nodesSubsets = getRandomIndicesArrays(Array.from({ length: NUMBER_OF_NODES }, (_, i) => i));
nodesSubsets.forEach((nodesSubset, subsetIndex) => {
  console.log('Subset PBFT nodes:', nodesSubset.map(i => "500" + (parseInt(i, 10) + 1)));
  for (let index = 0; index < NUMBER_OF_NODES; index++) {
    const envVars = {
      ...process.env, // Keep existing environment variables
      SECRET: `NODE${index}`,
      P2P_PORT: 5001 + index,
      HTTP_PORT: 3001 + index,
      TRANSACTION_THRESHOLD,
      NUMBER_OF_NODES,
      SUBSET_INDEX: `SUBSET${subsetIndex + 1}`
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

    if (nodesSubset.includes(index)) {
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
  }
});
