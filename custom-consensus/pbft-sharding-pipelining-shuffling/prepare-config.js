const fs = require('fs')
const yaml = require('js-yaml')
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
const NUMBER_OF_NODES = Number(process.env.NUMBER_OF_NODES)
const TRANSACTION_THRESHOLD = 100
const ACTIVE_SUBSET_OF_NODES = 4
const CPU_LIMIT = 0.001

const coreServerPort = 4999

const shuffleArray = (array) => {
  const copy = array.slice(); // don't modify original
  for (let index = copy.length - 1; index > 0; index--) {
    const index_ = Math.floor(Math.random() * (index + 1));
    [copy[index], copy[index_]] = [copy[index_], copy[index]]; // swap
  }
  return copy;
}

const splitIntoFoursWithRemaining = (array) => {
  const result = [];
  let index = 0;

  while (array.length - index >= 4) {
    result.push(array.slice(index, index + 4));
    index += 4;
  }

  // Last group with remaining 4 or more
  result[result.length - 1] = [...result[result.length - 1], ...array.slice(index)];

  return result;
}

const getRandomIndicesArrays = (array) => {
  const indices = Array.from({ length: array.length }, (_, index) => index);
  return splitIntoFoursWithRemaining(shuffleArray(indices));
}

const nodesSubsets = getRandomIndicesArrays(
  Array.from({ length: NUMBER_OF_NODES }, (_, index) => index)
)
console.log(nodesSubsets)
let environmentArray = [];
// Save environmentVariables to a yml file
const environmentFile = 'nodesEnv.yml';
const kubeFile = 'kubeConfig.yml';
nodesSubsets.forEach((nodesSubset, subsetIndex) => {
  console.log(
    'Subset PBFT nodes:',
    nodesSubset.map((index) => parseInt(index, 10) + 5001)
  )
  for (let index = 0; index < NUMBER_OF_NODES; index++) {
    const environmentVariables = {
      // ...process.env, // Keep existing environment variables
      SECRET: `NODE${index}`,
      P2P_PORT: 5001 + index,
      HTTP_PORT: 3001 + index,
      TRANSACTION_THRESHOLD,
      NUMBER_OF_NODES: ACTIVE_SUBSET_OF_NODES,
      NODES_SUBSET: JSON.stringify(nodesSubset),
      SUBSET_INDEX: `SUBSET${subsetIndex + 1}`,
      CORE: `ws://core-server:${coreServerPort}`,
      CPU_LIMIT,
    }

    if (index > 0) {
      const peers = Array.from(
        { length: index },
        (_, index_) => `ws://p2p-server-${index_}.p2p-server:${index_ + 5001}`
      )
      let peersSubset = []
      nodesSubset.forEach((index) => {
        if (index in peers) {
          peersSubset.push(peers[index])
        }
      })
      if (peersSubset.length > 0 && nodesSubset.includes(index)) {
        console.log(`Peers for ${5001 + index}: `, peersSubset)
        environmentVariables.PEERS = peersSubset.join(',')
      }
    }

    if (nodesSubset.includes(index)) {
      environmentArray.push(environmentVariables)
    }
  }
})

environmentArray.sort((a, b) => a.HTTP_PORT - b.HTTP_PORT)

fs.writeFileSync(environmentFile, yaml.dump(environmentArray))

const memory = '64Mi';
const cpu = `${Number(CPU_LIMIT) * 1000}m`;
const k8sConfig = {
  apiVersion: 'v1',
  kind: 'List',
  items: [
    ...environmentArray.flatMap((environmentVariables, index) => ([{
      apiVersion: 'v1',
      kind: 'Pod',
      metadata: {
        name: `p2p-server-${index}`,
        labels: { app: 'p2p-server', domain: 'blockchain' }
      },
      spec: {
        containers: [
          {
            name: 'p2p-server',
            image: 'lebaz20/blockchain-p2p-server:latest',
            resources: {
              limits: {
                memory,
                cpu
              }
            },
            env: Object.entries(environmentVariables).map(([key, value]) => ({
              name: key,
              value: String(value)
            })),
            ports: [
              { containerPort: environmentVariables.HTTP_PORT ? Number(environmentVariables.HTTP_PORT) : 3001 },
              { containerPort: environmentVariables.P2P_PORT ? Number(environmentVariables.P2P_PORT) : 5001 }
            ]
          }
        ],
        restartPolicy: 'Never'
      }
    },
  {
      apiVersion: 'v1',
      kind: 'Service',
      metadata: {
        name: `p2p-server-${index}`,
        labels: { app: 'p2p-server', domain: 'blockchain' }
      },
      spec: {
        clusterIP: 'None',
        selector: {
          app: 'p2p-server'
        },
        ports: [
          {
            name: environmentVariables.P2P_PORT.toString(),
            protocol: 'TCP',
            port: environmentVariables.P2P_PORT ? Number(environmentVariables.P2P_PORT) : 5001,
            targetPort: environmentVariables.P2P_PORT ? Number(environmentVariables.P2P_PORT) : 5001
          },
          {
            name: environmentVariables.HTTP_PORT.toString(),
            protocol: 'TCP',
            port: environmentVariables.HTTP_PORT ? Number(environmentVariables.HTTP_PORT) : 3001,
            targetPort: environmentVariables.HTTP_PORT ? Number(environmentVariables.HTTP_PORT) : 3001,
          }
        ]
      }
    }])),
    {
      apiVersion: 'v1',
      kind: 'Pod',
      metadata: {
        name: `core-server`,
        labels: { app: 'core-server', domain: 'blockchain' }
      },
      spec: {
        containers: [
          {
            name: 'core-server',
            image: 'lebaz20/blockchain-core-server:latest',
            resources: {
              limits: {
                memory,
                cpu
              }
            },
            ports: [
              { containerPort: coreServerPort },
            ]
          }
        ],
        restartPolicy: 'Never'
      }
    },
    {
      apiVersion: 'v1',
      kind: 'Service',
      metadata: {
        name: 'core-server',
        labels: { app: 'core-server', domain: 'blockchain' }
      },
      spec: {
        clusterIP: 'None',
        selector: {
          app: 'core-server'
        },
        ports: [
          {
            name: coreServerPort.toString(),
            protocol: 'TCP',
            port: coreServerPort,
            targetPort: coreServerPort
          }
        ]
      }
    },
  ]
};
fs.writeFileSync(kubeFile, yaml.dump(k8sConfig));

const ports = environmentArray.map(environment => environment.HTTP_PORT);
const weights = ports.map(() => Math.floor(Math.random() * 10) + 1); // random weight 1-10

let weightedPorts = [];
ports.forEach((endpoint, index) => {
  for (let w = 0; w < weights[index]; w++) {
    weightedPorts.push(endpoint);
  }
});

// Write weighted ports to CSV for JMeter
fs.writeFileSync('jmeter_ports.csv', weightedPorts.join('\n'));