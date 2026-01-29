#!/bin/bash

set -e

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Starting PBFT-RapidChain Blockchain${NC}"
echo -e "${BLUE}========================================${NC}\n"

# Step 1: Build the Docker images
echo -e "${BLUE}Step 1: Building Docker images...${NC}"
docker build -f Dockerfile.p2p -t lebaz20/blockchain-rapidchain-p2p-server:latest .
docker build -f Dockerfile.core -t lebaz20/blockchain-rapidchain-core-server:latest .
echo -e "${GREEN}✓ Docker images built${NC}\n"

# Push the Docker image to the local registry (optional)
# docker push lebaz20/blockchain-rapidchain-p2p-server:latest
# docker push lebaz20/blockchain-rapidchain-core-server:latest

# Step 2: Generate configuration
echo -e "${BLUE}Step 2: Generating configuration...${NC}"
# Use environment variables if set, otherwise use defaults
NUMBER_OF_NODES=${NUMBER_OF_NODES:-4}
NUMBER_OF_FAULTY_NODES=${NUMBER_OF_FAULTY_NODES:-0}
NUMBER_OF_NODES_PER_SHARD=${NUMBER_OF_NODES_PER_SHARD:-4}
HAS_COMMITTEE_SHARD=${HAS_COMMITTEE_SHARD:-1}
SHOULD_REDIRECT_FROM_FAULTY_NODES=${SHOULD_REDIRECT_FROM_FAULTY_NODES:-0}
TRANSACTION_THRESHOLD=${TRANSACTION_THRESHOLD:-100}
BLOCK_THRESHOLD=${BLOCK_THRESHOLD:-10}
CPU_LIMIT=${CPU_LIMIT:-0.1}
DEFAULT_TTL=${DEFAULT_TTL:-6}

echo -e "  Nodes: ${NUMBER_OF_NODES}"
echo -e "  Transaction Threshold: ${TRANSACTION_THRESHOLD}"
echo -e "  Block Threshold: ${BLOCK_THRESHOLD}"
echo -e "  Committee Shard: ${HAS_COMMITTEE_SHARD}"
echo -e "  Faulty Nodes: ${NUMBER_OF_FAULTY_NODES}"
echo -e "  CPU Limit: ${CPU_LIMIT}"
echo -e "  Default TTL: ${DEFAULT_TTL}"

NUMBER_OF_NODES=$NUMBER_OF_NODES \
  BLOCK_THRESHOLD=$BLOCK_THRESHOLD \
  TRANSACTION_THRESHOLD=$TRANSACTION_THRESHOLD \
  NUMBER_OF_FAULTY_NODES=$NUMBER_OF_FAULTY_NODES \
  NUMBER_OF_NODES_PER_SHARD=$NUMBER_OF_NODES_PER_SHARD \
  HAS_COMMITTEE_SHARD=$HAS_COMMITTEE_SHARD \
  SHOULD_REDIRECT_FROM_FAULTY_NODES=$SHOULD_REDIRECT_FROM_FAULTY_NODES \
  CPU_LIMIT=$CPU_LIMIT \
  DEFAULT_TTL=$DEFAULT_TTL \
  node prepare-config.js

echo -e "${GREEN}✓ Configuration generated${NC}\n"

sleep 2

# Step 3: Deploy to Kubernetes
echo -e "${BLUE}Step 3: Deploying to Kubernetes...${NC}"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Deleting existing Kubernetes resources..." | tee -a server.log
kubectl delete -f kubeConfig.yml --ignore-not-found 2>&1 | tee -a server.log
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Applying Kubernetes configuration..." | tee -a server.log
kubectl apply -f kubeConfig.yml 2>&1 | tee -a server.log
echo -e "${GREEN}✓ Deployed to Kubernetes${NC}\n"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Kubernetes deployment complete" | tee -a server.log

# Step 4: Wait for the pods to be ready
echo -e "${BLUE}Step 4: Waiting for pods to be ready...${NC}"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Waiting for all pods to be in Running state..." | tee -a server.log
TIMEOUT=120
ELAPSED=0
while true; do
    not_running=$(kubectl get pods -l domain=blockchain --no-headers 2>/dev/null | grep -v 'Running' | wc -l | tr -d ' ')
    if [ "$not_running" -eq 0 ]; then
        break
    fi
    if [ $ELAPSED -ge $TIMEOUT ]; then
        echo -e "${RED}✗ Timeout waiting for pods to start${NC}"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: Timeout waiting for pods" | tee -a server.log
        exit 1
    fi
    sleep 2
    ELAPSED=$((ELAPSED + 2))
    echo -ne "  Waiting... ${ELAPSED}s\r"
done
kubectl get pods -l domain=blockchain 2>&1 | tee -a server.log
echo -e "${GREEN}✓ All pods are running${NC}\n"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] All pods ready" | tee -a server.log

# Step 5: Set up port forwarding
echo -e "${BLUE}Step 5: Setting up port forwarding...${NC}"
# Kill any existing port forwarding processes to avoid conflicts
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Cleaning up any existing port forwarding..." | tee -a server.log
pkill -f "kubectl port-forward" 2>/dev/null || true
sleep 2
for ((i=0; i<NUMBER_OF_NODES; i++)); do
  kubectl port-forward pod/p2p-server-$i $((3001+i)):$((3001+i)) > /dev/null 2>&1 &
done
echo -e "${GREEN}✓ Port forwarding established (ports $((3001))-$((3000+NUMBER_OF_NODES)))${NC}\n"

echo -e "${BLUE}========================================${NC}"
echo -e "${GREEN}Blockchain is running!${NC}"
echo -e "${BLUE}========================================${NC}"
echo -e "Streaming logs... (Press Ctrl+C to stop)\n"
echo -e "Logs are also being written to: server.log\n"

kubectl logs -l domain=blockchain -f --max-log-requests=10000 2>&1 | tee -a server.log