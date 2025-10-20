#!/bin/bash

set -e

# # Build the Docker image
# docker build -f Dockerfile.p2p -t lebaz20/blockchain-p2p-server:latest .
# docker build -f Dockerfile.core -t lebaz20/blockchain-core-server:latest .

# # Push the Docker image to the local registry
# docker push lebaz20/blockchain-p2p-server:latest
# docker push lebaz20/blockchain-core-server:latest

# Run prepare-config.js locally (not inside Docker)
NUMBER_OF_NODES=16
NUMBER_OF_FAULTY_NODES=5
NUMBER_OF_NODES_PER_SHARD=4
TRANSACTION_THRESHOLD=100
CPU_LIMIT=0.5
NUMBER_OF_NODES=$NUMBER_OF_NODES TRANSACTION_THRESHOLD=$TRANSACTION_THRESHOLD NUMBER_OF_FAULTY_NODES=$NUMBER_OF_FAULTY_NODES NUMBER_OF_NODES_PER_SHARD=$NUMBER_OF_NODES_PER_SHARD CPU_LIMIT=$CPU_LIMIT node prepare-config.js

sleep 2

# Apply the generated Kubernetes config
kubectl delete -f kubeConfig.yml --ignore-not-found
kubectl apply -f kubeConfig.yml

# Wait for the pods to be ready
echo "Waiting for all pods to be running..."
while true; do
    not_running=$(kubectl get pods -l domain=blockchain --no-headers | grep -v 'Running' | wc -l)
    if [ "$not_running" -eq 0 ]; then
        break
    fi
    sleep 2
done
echo "All pods are running."

for ((i=0; i<NUMBER_OF_NODES; i++)); do
  kubectl port-forward pod/p2p-server-$i $((3001+i)):$((3001+i)) &
done

kubectl logs -l domain=blockchain -f --max-log-requests=10000