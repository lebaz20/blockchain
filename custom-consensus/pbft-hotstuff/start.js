const { spawn } = require("child_process");
const axios = require("axios");

// ulimit -n 1228800
// sudo sysctl -w kern.maxfiles=1228800
// sudo sysctl -w kern.maxfilesperproc=614400
const NUMBER_OF_NODES = 8;
const TRANSACTION_THRESHOLD = 400;

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

for (let index = 0; index < NUMBER_OF_NODES; index++) {
  const envVars = {
    ...process.env, // Keep existing environment variables
    SECRET: `NODE${index}`,
    P2P_PORT: 5001 + index,
    HTTP_PORT: 3001 + index,
    TRANSACTION_THRESHOLD,
    NUMBER_OF_NODES,
    NODES_SUBSET: JSON.stringify(Array.from({ length: NUMBER_OF_NODES }, (_, i) => i ))
  };

  let promise;
  if (index > 0) {
    // const peers = Array.from({ length: index }, (_, i) => `ws://localhost:500${i+1}`);
    const peers = [`ws://localhost:5001`]; // leader is always first node
    promise = Promise.all(peers.map(peer => waitForWebServer(peer.replace('ws', 'http').replace('500', '300'))));
    envVars.PEERS = peers.join(",");
    envVars.IS_LEADER = 'false';
    envVars.REDIRECT_TO_PORT = 3001;
  }  else {
    envVars.IS_LEADER = 'true';
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
  }
}