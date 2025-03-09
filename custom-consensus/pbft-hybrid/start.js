const { spawn } = require("child_process");
const WebSocket = require("ws");

// ulimit -n 1228800
// sudo sysctl -w kern.maxfiles=1228800
// sudo sysctl -w kern.maxfilesperproc=614400
const NUMBER_OF_NODES = 8;
const ACTIVE_SUBSET_OF_NODES = 0.5;
const TRANSACTION_THRESHOLD = 10;

function getRandomIndices(array) {
  const indices = Array.from({ length: array.length }, (_, i) => i);
  return indices.sort(() => 0.5 - Math.random()).slice(0, Math.floor(ACTIVE_SUBSET_OF_NODES * array.length));
}

function waitForWebSocket(url, retryInterval = 1000) {
  return new Promise((resolve) => {
    function checkWebSocket() {
      const ws = new WebSocket(url);

      ws.on("open", () => {
        ws.close();
        console.log(`WebSocket is open: ${url}`);
        resolve(true);
      });

      ws.on("error", () => {
        console.log(`WebSocket ${url} not available, retrying...`);
        setTimeout(checkWebSocket, retryInterval + 1000);
      });
    }

    checkWebSocket();
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

for (let index = 0; index < NUMBER_OF_NODES; index++) {
  const envVars = {
    ...process.env, // Keep existing environment variables
    SECRET: `NODE${index}`,
    P2P_PORT: 5001 + index,
    HTTP_PORT: 3001 + index,
    TRANSACTION_THRESHOLD,
    NUMBER_OF_NODES,
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
    if (peersSubset.length > 0) {
      promise = Promise.all(peersSubset.map(peer => waitForWebSocket(peer)));
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
        console.log("########################All set! Ready for testing...########################");
      }
    });
  } else {
    initServer(envVars);
  }
}