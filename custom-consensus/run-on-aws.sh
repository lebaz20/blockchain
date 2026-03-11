#!/bin/bash
# =============================================================================
# run-on-aws.sh
# Provision an EC2 instance, run the blockchain comparison test, download results.
#
# Usage:
#   ./run-on-aws.sh [options]
#
# Options:
#   --aws-access-key     AWS_ACCESS_KEY_ID          (or set env var)
#   --aws-secret-key     AWS_SECRET_ACCESS_KEY      (or set env var)
#   --aws-region         AWS region  [default: us-east-1]
#   --instance-type      EC2 type    [default: c6i.32xlarge  — 128 vCPU, 256 GiB]
#   --nodes              NUMBER_OF_NODES            [default: 512]
#   --faulty             NUMBER_OF_FAULTY_NODES     [default: 85]
#   --key-name           Existing EC2 key pair name (optional; one is created
#                        automatically if omitted and deleted on cleanup)
#   --on-demand          Use On-Demand pricing instead of Spot (Spot is default; ~70% cheaper)
#   --keep-instance      Don't terminate EC2 after test (for debugging)
#   --skip-upload        Assume code is already on the instance (needs --instance-id)
#   --instance-id        Reuse an existing running instance
#
# Dependencies (on this machine):
#   aws CLI v2, ssh, scp, rsync
# =============================================================================

set -euo pipefail

# ─── colour helpers ──────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'
log()  { echo -e "[$(date '+%H:%M:%S')] $*"; }
info() { log "${BLUE}$*${NC}"; }
ok()   { log "${GREEN}✓ $*${NC}"; }
warn() { log "${YELLOW}⚠ $*${NC}"; }
err()  { log "${RED}✗ $*${NC}"; }

# ─── defaults ────────────────────────────────────────────────────────────────
AWS_REGION="${AWS_REGION:-us-east-1}"
INSTANCE_TYPE="${INSTANCE_TYPE:-c6i.32xlarge}"
NUMBER_OF_NODES="${NUMBER_OF_NODES:-512}"
NUMBER_OF_FAULTY_NODES="${NUMBER_OF_FAULTY_NODES:-85}"
USE_SPOT=true
KEEP_INSTANCE=false
SKIP_UPLOAD=false
INSTANCE_ID=""
KEY_NAME=""
CREATED_KEY=false
CREATED_SG=false
SG_ID=""
KEY_FILE=""

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
RESULTS_DIR="${SCRIPT_DIR}/performance-results"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# ─── argument parsing ─────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --aws-access-key)  export AWS_ACCESS_KEY_ID="$2";        shift 2 ;;
        --aws-secret-key)  export AWS_SECRET_ACCESS_KEY="$2";    shift 2 ;;
        --aws-region)      AWS_REGION="$2";                       shift 2 ;;
        --instance-type)   INSTANCE_TYPE="$2";                    shift 2 ;;
        --nodes)           NUMBER_OF_NODES="$2";                  shift 2 ;;
        --faulty)          NUMBER_OF_FAULTY_NODES="$2";           shift 2 ;;
        --key-name)        KEY_NAME="$2";                         shift 2 ;;
        --on-demand)       USE_SPOT=false;                        shift   ;;
        --keep-instance)   KEEP_INSTANCE=true;                    shift   ;;
        --skip-upload)     SKIP_UPLOAD=true;                      shift   ;;
        --instance-id)     INSTANCE_ID="$2";                      shift 2 ;;
        *) err "Unknown option: $1"; exit 1 ;;
    esac
done

export AWS_DEFAULT_REGION="$AWS_REGION"

# ─── prerequisite checks ─────────────────────────────────────────────────────
info "Checking local prerequisites..."
for cmd in aws ssh scp rsync; do
    if ! command -v "$cmd" &>/dev/null; then
        err "'$cmd' not found — install it and retry."
        exit 1
    fi
done
if [[ -z "${AWS_ACCESS_KEY_ID:-}" || -z "${AWS_SECRET_ACCESS_KEY:-}" ]]; then
    # Check if default profile works
    if ! aws sts get-caller-identity &>/dev/null; then
        err "AWS credentials not found. Pass --aws-access-key / --aws-secret-key or configure 'aws configure'."
        exit 1
    fi
fi
ok "Prerequisites met"

# ─── cleanup trap ─────────────────────────────────────────────────────────────
cleanup() {
    local exit_code=$?
    echo ""
    info "Running cleanup..."

    # ── always download whatever logs exist on the remote ────────────────────
    # This runs on every exit path (success, error, Ctrl+C) so you can always
    # investigate what happened, even if the test failed mid-way.
    if [[ -n "${PUBLIC_IP:-}" && -n "${KEY_FILE:-}" && -f "${KEY_FILE:-/dev/null}" ]]; then
        local LOG_DIR="${RESULTS_DIR}/logs-${TIMESTAMP}"
        mkdir -p "$LOG_DIR"
        info "Downloading logs to $LOG_DIR ..."

        local _SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes -i $KEY_FILE"

        # Main comparison run log
        scp $_SSH_OPTS \
            "ec2-user@${PUBLIC_IP}:/tmp/comparison-run.log" \
            "${LOG_DIR}/comparison-run.log" 2>/dev/null || true

        # server.log from each protocol (contains node/k8s output)
        for _proto in pbft-enhanced pbft-rapidchain; do
            scp $_SSH_OPTS \
                "ec2-user@${PUBLIC_IP}:~/blockchain/custom-consensus/${_proto}/server.log" \
                "${LOG_DIR}/${_proto}-server.log" 2>/dev/null || true
        done

        # Any partial performance-results (stats CSVs, summary txts, JTL files)
        for _proto in pbft-enhanced pbft-rapidchain; do
            mkdir -p "${LOG_DIR}/${_proto}-results"
            rsync -az --no-perms \
                -e "ssh $_SSH_OPTS" \
                "ec2-user@${PUBLIC_IP}:~/blockchain/custom-consensus/${_proto}/performance-results/" \
                "${LOG_DIR}/${_proto}-results/" 2>/dev/null || true
        done

        # Comparison markdown (may not exist if the test never reached that stage)
        local _MD
        _MD=$(ssh $_SSH_OPTS "ec2-user@${PUBLIC_IP}" \
            "ls ~/blockchain/custom-consensus/performance-comparison-*.md 2>/dev/null | tail -1" 2>/dev/null || true)
        if [[ -n "$_MD" ]]; then
            scp $_SSH_OPTS \
                "ec2-user@${PUBLIC_IP}:${_MD}" \
                "${LOG_DIR}/$(basename "$_MD")" 2>/dev/null || true
        fi

        # k3s / kubelet system journal (useful when pods fail to schedule)
        ssh $_SSH_OPTS "ec2-user@${PUBLIC_IP}" \
            "sudo journalctl -u k3s --no-pager -n 500 2>/dev/null" \
            > "${LOG_DIR}/k3s-journal.log" 2>/dev/null || true

        # List of non-Running pods at exit time
        ssh $_SSH_OPTS "ec2-user@${PUBLIC_IP}" \
            "KUBECONFIG=/home/ec2-user/.kube/config kubectl get pods -A --no-headers 2>/dev/null \
             | grep -v Running || true" \
            > "${LOG_DIR}/pods-not-running.txt" 2>/dev/null || true

        if [[ $exit_code -ne 0 ]]; then
            warn "Test failed — logs saved to: $LOG_DIR"
        else
            ok "Logs saved to: $LOG_DIR"
        fi
    fi

    # Remove temp key file from disk
    if [[ -n "${KEY_FILE:-}" && -f "${KEY_FILE:-/dev/null}" ]]; then
        rm -f "$KEY_FILE"
        info "Removed local key file: $KEY_FILE"
    fi

    if [[ "$KEEP_INSTANCE" == "true" ]]; then
        warn "Instance kept (--keep-instance set)."
        [[ -n "${INSTANCE_ID:-}" ]] && warn "  Instance ID : $INSTANCE_ID"
    else
        # Terminate EC2 instance
        if [[ -n "${INSTANCE_ID:-}" ]]; then
            info "Terminating EC2 instance $INSTANCE_ID ..."
            aws ec2 terminate-instances --instance-ids "$INSTANCE_ID" \
                --region "$AWS_REGION" &>/dev/null || true
            aws ec2 wait instance-terminated --instance-ids "$INSTANCE_ID" \
                --region "$AWS_REGION" &>/dev/null || true
            ok "Instance terminated"
        fi

        # Delete the auto-created security group.
        # The SG can only be deleted once the instance's ENI is fully released,
        # which happens a few seconds after instance-terminated state.  Retry
        # for up to 60 s to avoid a silent no-op when the instance terminates fast.
        if [[ "$CREATED_SG" == "true" && -n "${SG_ID:-}" ]]; then
            info "Deleting security group $SG_ID ..."
            for _sg_attempt in $(seq 1 12); do
                if aws ec2 delete-security-group --group-id "$SG_ID" \
                       --region "$AWS_REGION" &>/dev/null 2>&1; then
                    ok "Security group deleted"
                    break
                fi
                sleep 5
            done
        fi

        # Delete auto-created key pair from AWS
        if [[ "$CREATED_KEY" == "true" && -n "${KEY_NAME:-}" ]]; then
            info "Deleting EC2 key pair $KEY_NAME ..."
            aws ec2 delete-key-pair --key-name "$KEY_NAME" \
                --region "$AWS_REGION" &>/dev/null || true
            ok "Key pair deleted"
        fi
    fi

    if [[ $exit_code -ne 0 ]]; then
        err "Script exited with code $exit_code"
    fi
}
trap cleanup EXIT

# ─── resolve AMI: latest Amazon Linux 2023 x86_64 ────────────────────────────
info "Resolving latest Amazon Linux 2023 AMI in $AWS_REGION ..."
AMI_ID=$(aws ec2 describe-images \
    --owners amazon \
    --filters \
        "Name=name,Values=al2023-ami-2023.*-x86_64" \
        "Name=state,Values=available" \
        "Name=architecture,Values=x86_64" \
    --query 'sort_by(Images, &CreationDate)[-1].ImageId' \
    --output text \
    --region "$AWS_REGION")

if [[ -z "$AMI_ID" || "$AMI_ID" == "None" ]]; then
    err "Could not find Amazon Linux 2023 AMI in $AWS_REGION"
    exit 1
fi
ok "AMI: $AMI_ID"

# ─── create or reuse SSH key pair ────────────────────────────────────────────
if [[ -z "$KEY_NAME" ]]; then
    KEY_NAME="blockchain-test-key-${TIMESTAMP}"
    KEY_FILE="/tmp/${KEY_NAME}.pem"
    info "Creating EC2 key pair '$KEY_NAME' ..."
    aws ec2 create-key-pair \
        --key-name "$KEY_NAME" \
        --query 'KeyMaterial' \
        --output text \
        --region "$AWS_REGION" > "$KEY_FILE"
    chmod 600 "$KEY_FILE"
    CREATED_KEY=true
    ok "Key pair created → $KEY_FILE"
else
    # User supplied a key name — find the corresponding .pem on disk
    KEY_FILE="${HOME}/.ssh/${KEY_NAME}.pem"
    if [[ ! -f "$KEY_FILE" ]]; then
        KEY_FILE="${HOME}/.ssh/${KEY_NAME}"
    fi
    if [[ ! -f "$KEY_FILE" ]]; then
        err "Key pair '$KEY_NAME' specified but private key file not found at ~/.ssh/${KEY_NAME}.pem or ~/.ssh/${KEY_NAME}"
        exit 1
    fi
    ok "Using existing key pair '$KEY_NAME' → $KEY_FILE"
fi

# ─── security group: SSH only ─────────────────────────────────────────────────
info "Creating security group for SSH access ..."
SG_NAME="blockchain-test-sg-${TIMESTAMP}"
SG_ID=$(aws ec2 create-security-group \
    --group-name "$SG_NAME" \
    --description "Temporary SG for blockchain comparison test" \
    --region "$AWS_REGION" \
    --query 'GroupId' --output text)
CREATED_SG=true

MY_IP=$(curl -sf https://checkip.amazonaws.com || echo "0.0.0.0")
aws ec2 authorize-security-group-ingress \
    --group-id "$SG_ID" \
    --protocol tcp --port 22 \
    --cidr "${MY_IP}/32" \
    --region "$AWS_REGION" &>/dev/null
ok "Security group '$SG_NAME' ($SG_ID) — SSH allowed from $MY_IP"

# ─── launch EC2 instance ─────────────────────────────────────────────────────
if [[ -z "$INSTANCE_ID" ]]; then
    # Spot saves ~70% vs On-Demand (c6i.32xlarge: ~$1.63/hr Spot vs ~$5.44/hr On-Demand).
    # Pass --on-demand to override if Spot capacity is unavailable in this AZ.
    # SPOT_OPT is a bash array to avoid word-splitting on the JSON value.
    # Expanding a plain string variable containing JSON with unquoted $VAR breaks the AWS CLI arg parser.
    if [[ "$USE_SPOT" == "true" ]]; then
        info "Launching EC2 $INSTANCE_TYPE Spot instance (~\$1.63/hr; use --on-demand to override ~\$5.44/hr) ..."
        info "  Spot is fulfilled within seconds when capacity is available."
        info "  If interrupted mid-test, cleanup trap downloads partial logs automatically."
        SPOT_OPT=(--instance-market-options '{"MarketType":"spot","SpotOptions":{"SpotInstanceType":"one-time","InstanceInterruptionBehavior":"terminate"}}')
    else
        info "Launching EC2 $INSTANCE_TYPE On-Demand instance (~\$5.44/hr) ..."
        SPOT_OPT=()
    fi

    # 60 GiB gp3: OS ~3 GiB + 4 Docker images ~8 GiB + k3s ~1 GiB + node_modules ~2 GiB + buffer ≈ 25 GiB used.
    # DeleteOnTermination=true ensures no orphan EBS volumes remain after termination.
    _run_instances() {
        aws ec2 run-instances \
            --image-id "$AMI_ID" \
            --instance-type "$INSTANCE_TYPE" \
            --key-name "$KEY_NAME" \
            --security-group-ids "$SG_ID" \
            "$@" \
            --block-device-mappings '[{"DeviceName":"/dev/xvda","Ebs":{"VolumeSize":60,"VolumeType":"gp3","DeleteOnTermination":true}}]' \
            --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=blockchain-test-${TIMESTAMP}}]" \
            --region "$AWS_REGION" \
            --query 'Instances[0].InstanceId' \
            --output text
    }

    INSTANCE_ID=""
    if [[ ${#SPOT_OPT[@]} -gt 0 ]]; then
        INSTANCE_ID=$(_run_instances "${SPOT_OPT[@]}" 2>&1) || {
            if echo "$INSTANCE_ID" | grep -q "MaxSpotInstanceCountExceeded\|SpotMaxPriceTooLow\|InsufficientCapacity"; then
                warn "Spot quota exceeded or unavailable — falling back to On-Demand ..."
                SPOT_OPT=()
                INSTANCE_ID=""
            else
                echo "$INSTANCE_ID" >&2
                exit 1
            fi
        }
    fi
    if [[ -z "$INSTANCE_ID" ]]; then
        INSTANCE_ID=$(_run_instances)
    fi

    ok "Instance launched: $INSTANCE_ID"
    info "Waiting for instance to reach 'running' state (this takes ~60s) ..."
    aws ec2 wait instance-running \
        --instance-ids "$INSTANCE_ID" \
        --region "$AWS_REGION"
    ok "Instance is running"
fi

# ─── get public IP ───────────────────────────────────────────────────────────
PUBLIC_IP=$(aws ec2 describe-instances \
    --instance-ids "$INSTANCE_ID" \
    --region "$AWS_REGION" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' \
    --output text)
ok "Public IP: $PUBLIC_IP"

SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=15 -o ServerAliveInterval=30 -o ServerAliveCountMax=10 -i $KEY_FILE"
SSH="ssh $SSH_OPTS ec2-user@$PUBLIC_IP"

# ─── wait for SSH to be ready ────────────────────────────────────────────────
info "Waiting for SSH to become available ..."
for attempt in $(seq 1 30); do
    if $SSH "echo ok" &>/dev/null 2>&1; then
        break
    fi
    if [[ $attempt -eq 30 ]]; then
        err "SSH not available after 5 minutes"
        exit 1
    fi
    sleep 10
    echo -ne "  Attempt $attempt/30...\r"
done
ok "SSH is ready"

# ─── install system packages on the remote machine ───────────────────────────
info "Installing system packages on EC2 (Docker, Node 20, Python3, git, bc) ..."
$SSH 'bash -s' << 'REMOTE_INSTALL'
set -euo pipefail

# Raise open-file limits system-wide (needed for 512 kubectl port-forwards)
sudo tee -a /etc/security/limits.conf > /dev/null << 'LIMITS'
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
LIMITS
sudo sysctl -w fs.file-max=2097152 > /dev/null
echo "fs.file-max=2097152" | sudo tee -a /etc/sysctl.conf > /dev/null

# DNF packages (skip full upgrade — fresh AL2023 AMI is already current; saves ~5-10 min of billable time)
# Note: curl is already present as curl-minimal on AL2023; installing full curl conflicts with it
sudo dnf install -y -q git docker python3 bc jq rsync tar unzip

# Node.js 20 via NodeSource
curl -fsSL https://rpm.nodesource.com/setup_20.x | sudo bash -
sudo dnf install -y -q nodejs

# Yarn
sudo npm install -g yarn --quiet

# Enable & start Docker
sudo systemctl enable --now docker
sudo usermod -aG docker ec2-user

echo "==> System packages installed"
REMOTE_INSTALL
ok "System packages installed"

# ─── install kubectl ─────────────────────────────────────────────────────────
info "Installing kubectl ..."
$SSH 'bash -s' << 'REMOTE_KUBECTL'
set -euo pipefail
KUBECTL_VERSION=$(curl -fsSL https://dl.k8s.io/release/stable.txt)
curl -fsSLo /tmp/kubectl "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl"
chmod +x /tmp/kubectl
sudo mv /tmp/kubectl /usr/local/bin/kubectl
kubectl version --client --short 2>/dev/null || kubectl version --client
echo "==> kubectl installed"
REMOTE_KUBECTL
ok "kubectl installed"

# ─── install k3s (single-node Kubernetes) ────────────────────────────────────
info "Installing k3s (single-node Kubernetes cluster) ..."
$SSH 'bash -s' << 'REMOTE_K3S'
set -euo pipefail
# max-pods must exceed NUMBER_OF_NODES (512) + system pods (~10).
# The k3s default is 110 — raise it to 600 so all 512 p2p pods can be scheduled.
curl -sfL https://get.k3s.io | sh -s - \
    --disable traefik \
    --disable servicelb \
    --write-kubeconfig-mode 644 \
    --kubelet-arg=max-pods=600

# Wait for k3s to be ready
for i in $(seq 1 30); do
    if kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml get nodes &>/dev/null 2>&1; then
        break
    fi
    sleep 5
done

# Set up kubeconfig for ec2-user
mkdir -p /home/ec2-user/.kube
sudo cp /etc/rancher/k3s/k3s.yaml /home/ec2-user/.kube/config
sudo chown ec2-user:ec2-user /home/ec2-user/.kube/config
echo "==> k3s installed and running"
kubectl --kubeconfig /home/ec2-user/.kube/config get nodes
REMOTE_K3S
ok "k3s installed"

# ─── install Apache JMeter ───────────────────────────────────────────────────
info "Installing Apache JMeter 5.6.3 ..."
$SSH 'bash -s' << 'REMOTE_JMETER'
set -euo pipefail
# Install Java (JMeter dependency)
sudo dnf install -y -q java-21-amazon-corretto-headless

JMETER_VERSION="5.6.3"
JMETER_URL="https://downloads.apache.org/jmeter/binaries/apache-jmeter-${JMETER_VERSION}.tgz"
curl -fsSLo /tmp/jmeter.tgz "$JMETER_URL"
sudo tar xf /tmp/jmeter.tgz -C /opt
sudo ln -sf /opt/apache-jmeter-${JMETER_VERSION}/bin/jmeter /usr/local/bin/jmeter
rm /tmp/jmeter.tgz
echo "==> JMeter installed"
jmeter --version 2>&1 | head -3
REMOTE_JMETER
ok "JMeter installed"

# ─── upload project code ─────────────────────────────────────────────────────
if [[ "$SKIP_UPLOAD" != "true" ]]; then
    info "Uploading blockchain project to EC2 (~this may take a minute) ..."

    # Create remote directory structure
    $SSH "mkdir -p ~/blockchain/custom-consensus/pbft-enhanced ~/blockchain/custom-consensus/pbft-rapidchain"

    # rsync each protocol directory, excluding things we don't need on the server
    RSYNC_OPTS="-az --progress \
        --exclude=node_modules \
        --exclude=coverage \
        --exclude=performance-results \
        --exclude=diagrams \
        --exclude=temp \
        --exclude=server.log \
        --exclude=jmeter.log \
        --exclude='*.jtl' \
        --exclude=.DS_Store"

    rsync $RSYNC_OPTS \
        -e "ssh $SSH_OPTS" \
        "${SCRIPT_DIR}/pbft-enhanced/" \
        "ec2-user@${PUBLIC_IP}:~/blockchain/custom-consensus/pbft-enhanced/"

    rsync $RSYNC_OPTS \
        -e "ssh $SSH_OPTS" \
        "${SCRIPT_DIR}/pbft-rapidchain/" \
        "ec2-user@${PUBLIC_IP}:~/blockchain/custom-consensus/pbft-rapidchain/"

    # Upload compare-performance.sh
    scp $SSH_OPTS \
        "${SCRIPT_DIR}/compare-performance.sh" \
        "ec2-user@${PUBLIC_IP}:~/blockchain/custom-consensus/compare-performance.sh"

    ok "Code uploaded"

    # Install npm/yarn dependencies on the remote
    info "Installing Node.js dependencies on EC2 ..."
    $SSH 'bash -s' << 'REMOTE_DEPS'
set -euo pipefail
cd ~/blockchain/custom-consensus/pbft-enhanced
HUSKY=0 yarn install --frozen-lockfile --non-interactive 2>&1 | tail -5
cd ~/blockchain/custom-consensus/pbft-rapidchain
HUSKY=0 yarn install --frozen-lockfile --non-interactive 2>&1 | tail -5
echo "==> Node.js dependencies installed"
REMOTE_DEPS
    ok "Dependencies installed"
fi

# ─── build Docker images on the remote ───────────────────────────────────────
info "Building Docker images on EC2 in parallel (saves ~3-5 min of billable time) ..."
# Single-quoted heredoc delimiter suppresses local variable expansion so $! and pids
# are evaluated by the remote shell, not the local one.
$SSH 'bash -s' << 'REMOTE_BUILD'
set -euo pipefail
# Build all 4 images concurrently — Docker daemon safely handles parallel builds
pids=()
(cd ~/blockchain/custom-consensus/pbft-enhanced   && sudo docker build -f Dockerfile.p2p  -t lebaz20/blockchain-p2p-server:latest . -q) & pids+=($!)
(cd ~/blockchain/custom-consensus/pbft-enhanced   && sudo docker build -f Dockerfile.core -t lebaz20/blockchain-core-server:latest . -q) & pids+=($!)
(cd ~/blockchain/custom-consensus/pbft-rapidchain && sudo docker build -f Dockerfile.p2p  -t lebaz20/blockchain-rapidchain-p2p-server:latest . -q) & pids+=($!)
(cd ~/blockchain/custom-consensus/pbft-rapidchain && sudo docker build -f Dockerfile.core -t lebaz20/blockchain-rapidchain-core-server:latest . -q) & pids+=($!)
wait "${pids[@]}"

# Import into k3s containerd (sequential — each pipe needs its own stdin)
sudo docker save lebaz20/blockchain-p2p-server:latest            | sudo k3s ctr images import -
sudo docker save lebaz20/blockchain-core-server:latest           | sudo k3s ctr images import -
sudo docker save lebaz20/blockchain-rapidchain-p2p-server:latest | sudo k3s ctr images import -
sudo docker save lebaz20/blockchain-rapidchain-core-server:latest | sudo k3s ctr images import -
echo "==> Docker images built and imported into k3s"
REMOTE_BUILD
ok "Docker images built"

# ─── patch start.sh scripts to skip the docker build step ────────────────────
# Images are already in k3s containerd; re-building inside start.sh wastes time
# and the docker daemon is owned by root on the remote, causing permission issues.
info "Patching start.sh files to skip redundant docker build step ..."
$SSH 'bash -s' << 'REMOTE_PATCH'
set -euo pipefail
for DIR in pbft-enhanced pbft-rapidchain; do
    TARGET=~/blockchain/custom-consensus/${DIR}/start.sh
    # Comment out the docker build lines by pre-pending a '#' if not already done
    sed -i 's|^docker build|# docker build (skipped — images pre-loaded into k3s)|' "$TARGET" || true
done
echo "==> start.sh patched"
REMOTE_PATCH
ok "start.sh patched"

# ─── run the comparison test (live-streamed output) ─────────────────────────
info "=========================================="
info "Starting blockchain performance comparison"
info "  Nodes           : $NUMBER_OF_NODES"
info "  Faulty nodes    : $NUMBER_OF_FAULTY_NODES"
info "  Instance type   : $INSTANCE_TYPE"
info "  Region          : $AWS_REGION"
info "=========================================="

# Write the run script to a remote file first, then execute it with -t so
# the SSH pty streams output live to your terminal instead of buffering until
# the command finishes (here-doc + bash -s does not produce live output).
cat << RUNSCRIPT | $SSH "cat > /tmp/run-test.sh"
#!/bin/bash
set -euo pipefail
ulimit -n 1048576 2>/dev/null || ulimit -n 65536 2>/dev/null || true
export KUBECONFIG=/home/ec2-user/.kube/config
export NUMBER_OF_NODES=${NUMBER_OF_NODES}
export NUMBER_OF_FAULTY_NODES=${NUMBER_OF_FAULTY_NODES}
export PATH=\$PATH:/usr/local/bin
cd ~/blockchain/custom-consensus
chmod +x compare-performance.sh \\
         pbft-enhanced/run-performance-test.sh pbft-enhanced/start.sh \\
         pbft-rapidchain/run-performance-test.sh pbft-rapidchain/start.sh
./compare-performance.sh 2>&1 | tee /tmp/comparison-run.log
RUNSCRIPT

$SSH "chmod +x /tmp/run-test.sh"
# -t allocates a pty so output is line-buffered and streams live to your terminal
$SSH -t "/tmp/run-test.sh"
ok "Comparison test completed"

# ─── print summary ────────────────────────────────────────────────────────────
# Results and logs are downloaded by the cleanup trap on exit.
echo ""
echo -e "${CYAN}============================================${NC}"
echo -e "${CYAN}  Test complete! Downloading results...${NC}"
echo -e "${CYAN}============================================${NC}"
echo ""
if [[ "$KEEP_INSTANCE" == "true" ]]; then
    warn "Instance $INSTANCE_ID at $PUBLIC_IP was kept (--keep-instance)"
else
    info "Instance will be terminated by cleanup trap"
fi
