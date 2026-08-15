#!/bin/bash
# =============================================================================
# run-on-aws-cluster.sh
#
# Provision a k3s cluster on multiple EC2 instances (one blockchain pod per
# instance). This is the multi-EC2 alternative to `run-on-aws.sh`, which packs
# every pod onto a single big instance.
#
# Architecture (see INVESTIGATION_JOURNAL.md §3.5 for the "why"):
#   * 1× k3s server instance (default t3.medium) — control plane + core-server
#     + JMeter run here.
#   * N× k3s agent instances (default t3.small) — one blockchain p2p pod each,
#     pinned via podAntiAffinity.
#
# What THIS script does (MVP scope):
#   1. Provisions the cluster (master + N agents via EC2 Fleet API).
#   2. Waits until all N+1 nodes appear Ready in `kubectl get nodes`.
#   3. Copies the kubeconfig to your local machine so you can talk to the
#      cluster from your laptop (kubectl points at the master's public IP).
#   4. Keeps the cluster alive until you press Ctrl+C OR until --auto-teardown
#      seconds have elapsed. On exit, tears everything down.
#
# What this script does NOT yet do (deliberately):
#   * Deploy the blockchain workload. That's a separate step you can run once
#     the cluster is up (kubectl apply -f kubeConfig.yml on your laptop, or
#     ssh to the master and run start.sh there).
#   * Wire into journal-aws-driver.sh. The driver currently invokes run-on-aws.sh;
#     hooking this cluster script in is the follow-up.
#
# Usage:
#   ./run-on-aws-cluster.sh --nodes 8                    # small POC, 8 agents
#   ./run-on-aws-cluster.sh --nodes 100 --spot           # 100 nodes on spot
#   ./run-on-aws-cluster.sh --nodes 100 --auto-teardown 3600
#
# Common options (see full list at the top of the argument-parsing section):
#   --nodes N               number of k3s agents (blockchain pods)  [default: 8]
#   --agent-type TYPE       EC2 type for agents                     [t3.small]
#   --master-type TYPE      EC2 type for master                     [t3.medium]
#   --spot                  request Spot capacity for agents        [default: On-Demand]
#   --auto-teardown SEC     tear down after SEC seconds of uptime   [default: 0 = wait for Ctrl+C]
#   --aws-region REGION                                             [us-east-1]
#   --aws-access-key KEY / --aws-secret-key SECRET / or env vars / or `aws configure`
#
# Dependencies (on your local machine): aws CLI v2, ssh, scp
# =============================================================================

set -euo pipefail

# ─── colour helpers (identical to run-on-aws.sh so log output blends) ────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'
log()  { echo -e "[$(date '+%H:%M:%S')] $*"; }
info() { log "${BLUE}$*${NC}"; }
ok()   { log "${GREEN}✓ $*${NC}"; }
warn() { log "${YELLOW}⚠ $*${NC}"; }
err()  { log "${RED}✗ $*${NC}"; }

# ─── defaults ────────────────────────────────────────────────────────────────
AWS_REGION="${AWS_REGION:-us-east-1}"
NUMBER_OF_NODES="${NUMBER_OF_NODES:-8}"
# c6i.large (2 vCPU sustained, 4 GiB RAM) instead of t3.small (2 vCPU burstable,
# 2 GiB). t3.small's burstable credits deplete under sustained PBFT load,
# throttling each pod to ~20% CPU — observed 2026-08-01 where step-3 runs
# saturated at 14 tx/s because pods hit the CPU limit under 500-thread JMeter.
# c6i.large is ~$0.085/hr vs t3.small's $0.023/hr but delivers real CPU.
AGENT_INSTANCE_TYPE="${AGENT_INSTANCE_TYPE:-c6i.large}"
# Master carries k3s control-plane + JMeter (up to 500 threads) + N socat
# forwarders + resource monitor + Docker builds. c6i.large (2 vCPU / 4 GiB) is
# fine for join-storm handling but dies mid-JMeter on ≥128-node clusters:
# 500-thread JMeter alone consumes >2 vCPU + ~1 GiB RSS, plus per-agent socat
# adds up. Observed 2026-08-01 where c6i.large master OOM/thrashed at N=128
# with JMeter errors climbing 0→82 % in 90 s. Auto-scale below is picked at
# runtime once NUMBER_OF_NODES is known (see MASTER_INSTANCE_TYPE resolution).
DEFAULT_MASTER_INSTANCE_TYPE_SMALL="c6i.large"    # up to N=32
DEFAULT_MASTER_INSTANCE_TYPE_MEDIUM="c6i.xlarge"  # N in [33, 256]  (4 vCPU / 8 GiB)
DEFAULT_MASTER_INSTANCE_TYPE_LARGE="c6i.2xlarge"  # N > 256         (8 vCPU / 16 GiB)
MASTER_INSTANCE_TYPE="${MASTER_INSTANCE_TYPE:-auto}"
USE_SPOT=false
AUTO_TEARDOWN_SEC=0             # 0 = keep running until Ctrl+C
KEEP_ON_EXIT=false               # set true to skip cleanup (debug only)

# ─── blockchain deploy defaults ──────────────────────────────────────────────
# When DEPLOY_SYSTEM is non-empty, we install + deploy + run the specified
# consensus system after the cluster is up. Auto-teardown then triggers off
# the test completing rather than a fixed wait timer.
DEPLOY_SYSTEM=""                       # "rapidchain" or "enhanced"
DEPLOY_COMMITTEE_SHARD="1"             # rapidchain only; ignored for enhanced
DEPLOY_FAULTY_NODES=""                 # blank → default (floor((n-1)/3) is set inside run-performance-test.sh)
DEPLOY_NPS=""                          # NUMBER_OF_NODES_PER_SHARD; defaults to N (single shard)
# TRANSACTION_THRESHOLD = tx per block. Match journal-comparison.sh so we
# target high steady-state throughput (4000-tx blocks). Requires a large-enough
# JMeter thread pool to actually fill blocks — see DEPLOY_JMETER_THREADS below.
DEPLOY_TRANSACTION_THRESHOLD="4000"
DEPLOY_JMETER_DURATION="300"
# STRICT_BLOCK_THRESHOLD=0 (opt-in) keeps enhanced's sub-threshold fast-paths
# active — those are enhanced's architectural advantage (drain-fast + pipeline-
# fast propose paths that flush residual TXs without waiting for a full pool).
# Set to 1 only when you deliberately want to suppress enhanced's advantage for
# a policy-matched baseline.
DEPLOY_STRICT_THRESHOLD="0"
# Enhanced-only: shard-merge is one of enhanced's key architectural features (dead
# shards' TXs merge into healthy shards). Off means enhanced degrades to raw sharded
# PBFT, which is not what we want to benchmark. Rapidchain ignores this env var.
DEPLOY_ENABLE_SHARD_MERGE="1"
# Rapidchain-only: BLOCK_THRESHOLD = number of shard blocks the committee accumulates
# before opening a PBFT validation round. Default 1 = per-block validation, the most
# literal reading of Zamani et al. (CCS 2018) where the reference committee validates
# each shard block individually as it arrives (no batching). Enhanced ignores this env
# var. Override via --deploy-block-threshold to explore batching / latency trade-offs.
DEPLOY_BLOCK_THRESHOLD="1"
# JMeter load: sized so 4 000-tx blocks fill in seconds, not minutes.
# THROUGHPUT is req/min for ConstantThroughputTimer; 60 000 = 1 000 req/s target.
# THREADS = 500 gives ~2 req/s per thread at 500 ms latency — enough headroom
# so response-time growth doesn't cap the fire rate below the target.
# Conservative for a c6i.large master's JMeter JVM (each thread ≈ 1 MiB stack).
# Override with --deploy-jmeter-threads / --deploy-jmeter-throughput; use a
# larger --master-type before pushing threads past ~1500.
DEPLOY_JMETER_THREADS="500"
DEPLOY_JMETER_THROUGHPUT="60000"
DEPLOY_CPU_LIMIT=""                     # blank → sqrt-scaled from DEPLOY_NPS
DEPLOY_POD_MEMORY_MIB=""                # blank → sqrt-scaled from DEPLOY_NPS
DEPLOY_NODE_OPTIONS=""                  # passed as NODE_OPTIONS env var to each pod; e.g. "--max-old-space-size=1100" to cap V8 heap below pod memory limit and avoid OOMKill at NPS>=100

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
CLUSTER_TAG="blockchain-cluster-${TIMESTAMP}"

# runtime state — populated as we go, read by cleanup()
KEY_NAME=""
KEY_FILE=""
CREATED_KEY=false
SG_ID=""
CREATED_SG=false
MASTER_INSTANCE_ID=""
MASTER_PUBLIC_IP=""
MASTER_PRIVATE_IP=""
K3S_TOKEN=""
LAUNCH_TEMPLATE_ID=""
FLEET_IDS=()               # array — one Fleet per batch
AGENT_INSTANCE_IDS=""
# Batch tuning: 25 agents per fleet, 60s between batches. Keeps the k3s
# server's join-time CPU peak bounded regardless of --nodes.
FLEET_BATCH_SIZE="${FLEET_BATCH_SIZE:-25}"
FLEET_BATCH_WAIT_SEC="${FLEET_BATCH_WAIT_SEC:-60}"
LOCAL_KUBECONFIG=""
USERDATA_MASTER_FILE=""
USERDATA_AGENT_FILE=""

# ─── argument parsing ────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --aws-access-key)    export AWS_ACCESS_KEY_ID="$2";      shift 2 ;;
        --aws-secret-key)    export AWS_SECRET_ACCESS_KEY="$2";  shift 2 ;;
        --aws-region)        AWS_REGION="$2";                    shift 2 ;;
        --nodes)             NUMBER_OF_NODES="$2";               shift 2 ;;
        --agent-type)        AGENT_INSTANCE_TYPE="$2";           shift 2 ;;
        --master-type)       MASTER_INSTANCE_TYPE="$2";          shift 2 ;;
        --spot)              USE_SPOT=true;                      shift   ;;
        --auto-teardown)     AUTO_TEARDOWN_SEC="$2";             shift 2 ;;
        --keep-on-exit)      KEEP_ON_EXIT=true;                  shift   ;;
        --deploy-blockchain) DEPLOY_SYSTEM="$2";                 shift 2 ;;
        --committee-shard)   DEPLOY_COMMITTEE_SHARD="$2";        shift 2 ;;
        --deploy-nps)        DEPLOY_NPS="$2";                    shift 2 ;;
        --deploy-faulty)     DEPLOY_FAULTY_NODES="$2";           shift 2 ;;
        --deploy-tx-threshold) DEPLOY_TRANSACTION_THRESHOLD="$2"; shift 2 ;;
        --deploy-jmeter-duration) DEPLOY_JMETER_DURATION="$2";   shift 2 ;;
        --deploy-enable-shard-merge) DEPLOY_ENABLE_SHARD_MERGE="$2"; shift 2 ;;
        --deploy-block-threshold) DEPLOY_BLOCK_THRESHOLD="$2";   shift 2 ;;
        --deploy-strict-threshold) DEPLOY_STRICT_THRESHOLD="$2"; shift 2 ;;
        --deploy-jmeter-threads)  DEPLOY_JMETER_THREADS="$2";    shift 2 ;;
        --deploy-jmeter-throughput) DEPLOY_JMETER_THROUGHPUT="$2"; shift 2 ;;
        --deploy-cpu-limit)       DEPLOY_CPU_LIMIT="$2";         shift 2 ;;
        --deploy-pod-memory-mib)  DEPLOY_POD_MEMORY_MIB="$2";    shift 2 ;;
        --deploy-node-options)    DEPLOY_NODE_OPTIONS="$2";      shift 2 ;;
        -h|--help)
            sed -n '3,50p' "$0"; exit 0 ;;
        *) err "Unknown option: $1"; exit 1 ;;
    esac
done
export AWS_DEFAULT_REGION="$AWS_REGION"

# ─── prerequisite checks ─────────────────────────────────────────────────────
info "Checking local prerequisites..."
for cmd in aws ssh scp curl jq; do
    if ! command -v "$cmd" &>/dev/null; then
        err "'$cmd' not found — install it and retry."; exit 1
    fi
done
if [[ -z "${AWS_ACCESS_KEY_ID:-}" || -z "${AWS_SECRET_ACCESS_KEY:-}" ]]; then
    if ! aws sts get-caller-identity &>/dev/null; then
        err "AWS credentials not found."
        err "Pass --aws-access-key/--aws-secret-key, set env vars, or run 'aws configure'."
        exit 1
    fi
fi
ok "Prerequisites met"

# ─── Resolve MASTER_INSTANCE_TYPE if left auto ───────────────────────────────
if [[ "$MASTER_INSTANCE_TYPE" == "auto" ]]; then
    if   (( NUMBER_OF_NODES <= 32 ));  then MASTER_INSTANCE_TYPE="$DEFAULT_MASTER_INSTANCE_TYPE_SMALL"
    elif (( NUMBER_OF_NODES <= 256 )); then MASTER_INSTANCE_TYPE="$DEFAULT_MASTER_INSTANCE_TYPE_MEDIUM"
    else                                    MASTER_INSTANCE_TYPE="$DEFAULT_MASTER_INSTANCE_TYPE_LARGE"
    fi
    info "auto-selected master type: $MASTER_INSTANCE_TYPE (for N=$NUMBER_OF_NODES)"
fi

# Master vCPU count depends on the picked type. Rough map — enough for the
# quota-math step below; if you introduce a new master type, add it here.
case "$MASTER_INSTANCE_TYPE" in
    c6i.large)    MASTER_VCPU=2  ;;
    c6i.xlarge)   MASTER_VCPU=4  ;;
    c6i.2xlarge)  MASTER_VCPU=8  ;;
    c6i.4xlarge)  MASTER_VCPU=16 ;;
    t3.medium)    MASTER_VCPU=2  ;;
    *)            MASTER_VCPU=2  ;;
esac

# ─── vCPU-budget pre-flight (avoid launching if we can't fit) ────────────────
# Agents = c6i.large (2 vCPU each). Master vCPU resolved above.
REQUIRED_VCPU=$(( NUMBER_OF_NODES * 2 + MASTER_VCPU ))
QUOTA_ONDEMAND=$(aws service-quotas get-service-quota \
    --service-code ec2 --quota-code L-1216C47A \
    --query 'Quota.Value' --output text 2>/dev/null || echo 0)
QUOTA_ONDEMAND_INT=${QUOTA_ONDEMAND%.*}
info "vCPU budget: ${NUMBER_OF_NODES}×2 agent + ${MASTER_VCPU} master = $REQUIRED_VCPU vCPU required"
info "  On-Demand Standard vCPU quota in $AWS_REGION: $QUOTA_ONDEMAND_INT"

# Count vCPU already in flight (running / pending / shutting-down all count
# against the quota). Previous back-to-back runs sometimes hit vCPU exhaustion
# because a prior cluster's agents were still in "shutting-down" state — the
# subsequent create-fleet failed silently and the driver aborted before any
# `tee`-redirected log was written, leaving an empty results directory.
IN_FLIGHT_VCPU=$(aws ec2 describe-instances \
    --filters "Name=instance-state-name,Values=pending,running,stopping,shutting-down" \
    --query 'Reservations[].Instances[].CpuOptions.CoreCount' --output text 2>/dev/null \
    | awk '{s+=$1*2} END {print s+0}')
info "  vCPU already in flight in $AWS_REGION: $IN_FLIGHT_VCPU"
AVAILABLE_VCPU=$(( QUOTA_ONDEMAND_INT - IN_FLIGHT_VCPU ))

if [[ "$USE_SPOT" == "false" && "$REQUIRED_VCPU" -gt "$QUOTA_ONDEMAND_INT" ]]; then
    err "Required $REQUIRED_VCPU vCPU exceeds On-Demand quota ($QUOTA_ONDEMAND_INT)"
    err "Either reduce --nodes, use --spot, or request a quota increase"
    err "(see AWS_QUOTA_REQUEST.md)"
    exit 1
fi
if [[ "$USE_SPOT" == "false" && "$REQUIRED_VCPU" -gt "$AVAILABLE_VCPU" ]]; then
    err "Required $REQUIRED_VCPU vCPU exceeds AVAILABLE On-Demand vCPU ($AVAILABLE_VCPU)"
    err "  quota=$QUOTA_ONDEMAND_INT, in-flight=$IN_FLIGHT_VCPU"
    err "A previous cluster is likely still terminating. Wait 2-3 min and retry,"
    err "or run: aws ec2 describe-instances --filters Name=instance-state-name,Values=shutting-down"
    exit 1
fi

# ═════════════════════════════════════════════════════════════════════════════
# CLEANUP TRAP — must be installed BEFORE we create any resources
# ═════════════════════════════════════════════════════════════════════════════
cleanup() {
    local exit_code=$?
    trap - EXIT INT TERM  # prevent re-entry

    if [[ "$KEEP_ON_EXIT" == "true" ]]; then
        warn "Cluster kept alive (--keep-on-exit set)."
        [[ -n "$MASTER_PUBLIC_IP" ]] && warn "  Master IP: $MASTER_PUBLIC_IP"
        [[ -n "$KEY_FILE" ]] && warn "  Key file : $KEY_FILE"
        [[ ${#FLEET_IDS[@]} -gt 0 ]] && warn "  Fleet IDs: ${FLEET_IDS[*]}"
        exit "$exit_code"
    fi

    echo ""
    info "Running cluster teardown..."

    # 0. Defense-in-depth: if the master is still reachable, best-effort delete
    #    of blockchain pods BEFORE we start terminating agents. run-performance-
    #    test.sh's own cleanup already does this on the happy path, but if the
    #    user Ctrl+C'd mid-test the pods are still Running, and terminating
    #    agents without a graceful pod-drain lets 100+ p2pservers keep flooding
    #    gossip until SIGKILL — which pins the c6i.large master's kube-apiserver
    #    and blocks SSH for the whole teardown window. Bounded to 30s.
    if [[ -n "$MASTER_PUBLIC_IP" && -n "$KEY_FILE" && -f "$KEY_FILE" ]]; then
        info "Draining blockchain pods (best-effort, 30s cap)..."
        timeout 30 ssh -i "$KEY_FILE" -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
            "ec2-user@$MASTER_PUBLIC_IP" \
            "kubectl delete pods -l domain=blockchain --grace-period=0 --force --wait=false 2>/dev/null" \
            &>/dev/null || true
    fi

    # 1. Delete every Fleet we launched (with --terminate-instances so agent
    #    instances go with their fleet). We launch in batches, so there may
    #    be multiple fleet IDs to delete.
    if [[ ${#FLEET_IDS[@]} -gt 0 ]]; then
        info "Deleting ${#FLEET_IDS[@]} EC2 Fleet(s) (terminates all agents)..."
        aws ec2 delete-fleets --fleet-ids "${FLEET_IDS[@]}" \
            --terminate-instances --region "$AWS_REGION" &>/dev/null || true
    fi

    # 2. Terminate the master (not part of the fleet)
    if [[ -n "$MASTER_INSTANCE_ID" ]]; then
        info "Terminating master $MASTER_INSTANCE_ID..."
        aws ec2 terminate-instances --instance-ids "$MASTER_INSTANCE_ID" \
            --region "$AWS_REGION" &>/dev/null || true
    fi

    # 3. Wait for all instances to actually terminate (needed before SG delete
    #    can succeed — the SG stays "in use" until each ENI is released)
    local all_ids=""
    [[ -n "$MASTER_INSTANCE_ID" ]] && all_ids="$MASTER_INSTANCE_ID"
    [[ -n "$AGENT_INSTANCE_IDS" ]] && all_ids="$all_ids $AGENT_INSTANCE_IDS"
    if [[ -n "$all_ids" ]]; then
        info "Waiting for instances to reach terminated state..."
        aws ec2 wait instance-terminated --instance-ids $all_ids \
            --region "$AWS_REGION" &>/dev/null || true
    fi

    # 4. Delete the Launch Template (small but noisy leftover otherwise)
    if [[ -n "$LAUNCH_TEMPLATE_ID" ]]; then
        info "Deleting Launch Template $LAUNCH_TEMPLATE_ID..."
        aws ec2 delete-launch-template --launch-template-id "$LAUNCH_TEMPLATE_ID" \
            --region "$AWS_REGION" &>/dev/null || true
    fi

    # 5. Delete the SG (retry for up to 60 s: ENIs sometimes lag behind
    #    instance-terminated state)
    if [[ "$CREATED_SG" == "true" && -n "$SG_ID" ]]; then
        info "Deleting security group $SG_ID..."
        for _sg_attempt in $(seq 1 12); do
            if aws ec2 delete-security-group --group-id "$SG_ID" \
                    --region "$AWS_REGION" &>/dev/null; then
                ok "  Security group deleted"; break
            fi
            sleep 5
        done
    fi

    # 6. Delete the auto-created key pair from AWS + local disk
    if [[ "$CREATED_KEY" == "true" && -n "$KEY_NAME" ]]; then
        aws ec2 delete-key-pair --key-name "$KEY_NAME" \
            --region "$AWS_REGION" &>/dev/null || true
    fi
    [[ -n "$KEY_FILE" && -f "$KEY_FILE" ]] && rm -f "$KEY_FILE"

    # 7. Remove local temp files (user-data + kubeconfig)
    [[ -n "$USERDATA_MASTER_FILE" && -f "$USERDATA_MASTER_FILE" ]] && rm -f "$USERDATA_MASTER_FILE"
    [[ -n "$USERDATA_AGENT_FILE"  && -f "$USERDATA_AGENT_FILE"  ]] && rm -f "$USERDATA_AGENT_FILE"
    if [[ -n "$LOCAL_KUBECONFIG" && -f "$LOCAL_KUBECONFIG" ]]; then
        warn "Local kubeconfig at $LOCAL_KUBECONFIG is now stale — removing"
        rm -f "$LOCAL_KUBECONFIG" "${LOCAL_KUBECONFIG}.bak"
    fi

    if [[ $exit_code -ne 0 ]]; then
        err "Cluster script exited with code $exit_code"
    else
        ok "Cluster torn down"
    fi
    exit "$exit_code"
}
trap cleanup EXIT INT TERM

# ═════════════════════════════════════════════════════════════════════════════
# STEP 1: Resolve AMI + create SG + key pair
# ═════════════════════════════════════════════════════════════════════════════
info "Resolving latest Amazon Linux 2023 AMI in $AWS_REGION..."
AMI_ID=$(aws ec2 describe-images --owners amazon \
    --filters "Name=name,Values=al2023-ami-2023.*-x86_64" \
              "Name=state,Values=available" \
              "Name=architecture,Values=x86_64" \
    --query 'sort_by(Images, &CreationDate)[-1].ImageId' \
    --output text --region "$AWS_REGION")
[[ -z "$AMI_ID" || "$AMI_ID" == "None" ]] && { err "AMI lookup failed"; exit 1; }
ok "AMI: $AMI_ID"

info "Creating EC2 key pair 'blockchain-test-key-${TIMESTAMP}'..."
KEY_NAME="blockchain-test-key-${TIMESTAMP}"
KEY_FILE="/tmp/${KEY_NAME}.pem"
aws ec2 create-key-pair --key-name "$KEY_NAME" \
    --query 'KeyMaterial' --output text \
    --region "$AWS_REGION" > "$KEY_FILE"
chmod 600 "$KEY_FILE"
CREATED_KEY=true
ok "Key pair created → $KEY_FILE"

info "Creating security group..."
SG_NAME="blockchain-cluster-sg-${TIMESTAMP}"
SG_ID=$(aws ec2 create-security-group \
    --group-name "$SG_NAME" \
    --description "Temporary SG for blockchain k3s cluster ${TIMESTAMP}" \
    --region "$AWS_REGION" --query 'GroupId' --output text)
CREATED_SG=true

# What we allow:
#   :22   ← SSH from your public IP
#   :6443 ← k3s API from your public IP (so kubectl works from your laptop)
#   all   ← intra-SG (so nodes can talk to each other on any port)
MY_IP=$(curl -sf --max-time 5 https://checkip.amazonaws.com || echo "0.0.0.0")
SSH_CIDR="0.0.0.0/0"
if [[ "$MY_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ && "$MY_IP" != "0.0.0.0" ]]; then
    SSH_CIDR="${MY_IP}/32"
fi
aws ec2 authorize-security-group-ingress --group-id "$SG_ID" \
    --protocol tcp --port 22   --cidr "$SSH_CIDR" --region "$AWS_REGION" &>/dev/null
aws ec2 authorize-security-group-ingress --group-id "$SG_ID" \
    --protocol tcp --port 6443 --cidr "$SSH_CIDR" --region "$AWS_REGION" &>/dev/null
# Intra-SG: reference the SG itself as the source. Lets all cluster members
# talk to each other on any port (k3s uses 6443, 8472 UDP flannel, 10250, ...).
aws ec2 authorize-security-group-ingress --group-id "$SG_ID" \
    --protocol -1 --source-group "$SG_ID" --region "$AWS_REGION" &>/dev/null
ok "Security group $SG_NAME created — SSH+kubectl from $SSH_CIDR, all traffic intra-SG"

# ═════════════════════════════════════════════════════════════════════════════
# STEP 2: Launch master + install k3s server via user-data
# ═════════════════════════════════════════════════════════════════════════════
info "Launching master ($MASTER_INSTANCE_TYPE)..."
USERDATA_MASTER_FILE="/tmp/cluster-userdata-master-${TIMESTAMP}.sh"
cat > "$USERDATA_MASTER_FILE" << 'MASTER_UD'
#!/bin/bash
set -euo pipefail
exec > /var/log/userdata.log 2>&1

# Amazon Linux 2023 ships curl-minimal by default (satisfies the k3s installer's
# curl need). Install jq only; --allowerasing lets us upgrade curl-minimal to
# full curl if we ever need it, without dnf refusing due to conflicts.
dnf install -y -q --allowerasing jq

# Install k3s server. Flags used:
#   --cluster-init: use embedded etcd instead of the default sqlite datastore.
#     Sqlite serializes writes, which caps sensible cluster size at ~50-100
#     nodes; etcd handles thousands. Required for the ≥100-agent target.
#   --write-kubeconfig-mode 644: makes kubeconfig readable by ec2-user w/o sudo.
#   --disable traefik / servicelb: we don't need k3s' built-in ingress or LB.
#   --tls-san 0.0.0.0: placeholder in the API cert SAN list; client uses
#     insecure-skip-tls-verify so this is only a shape requirement.
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="server \
    --cluster-init \
    --write-kubeconfig-mode 644 \
    --disable traefik \
    --disable servicelb \
    --tls-san 0.0.0.0" sh -

# Wait for k3s to be actually ready (API server up + first token file written)
for i in $(seq 1 60); do
    if [ -f /var/lib/rancher/k3s/server/node-token ] \
        && /usr/local/bin/kubectl get nodes &>/dev/null; then
        break
    fi
    sleep 5
done

# Patch bundled metrics-server for k3s' self-signed kubelet certs. Without
# --kubelet-insecure-tls, `kubectl top pods` returns empty (metrics-server
# refuses to trust the kubelet's cert) — which makes monitor-resources.sh
# write all-zero rows for the whole run. Idempotent, safe if already patched.
for i in $(seq 1 30); do
    /usr/local/bin/kubectl -n kube-system get deployment metrics-server &>/dev/null && break
    sleep 5
done
/usr/local/bin/kubectl -n kube-system patch deployment metrics-server --type=json \
    -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]' \
    2>/dev/null || true
/usr/local/bin/kubectl -n kube-system rollout status deployment/metrics-server --timeout=120s 2>/dev/null || true

# One warmup query so `kubectl top` returns real data on the first sample.
for i in $(seq 1 30); do
    /usr/local/bin/kubectl top nodes &>/dev/null && break
    sleep 5
done

# Copy the join token to a known location the outer script can scp
cp /var/lib/rancher/k3s/server/node-token /home/ec2-user/k3s-token
chown ec2-user:ec2-user /home/ec2-user/k3s-token

# Also stage the kubeconfig so the outer script can scp it
cp /etc/rancher/k3s/k3s.yaml /home/ec2-user/kubeconfig
chown ec2-user:ec2-user /home/ec2-user/kubeconfig

touch /tmp/.k3s-master-ready
echo "==> k3s master ready at $(date)"
MASTER_UD

MASTER_INSTANCE_ID=$(aws ec2 run-instances \
    --image-id "$AMI_ID" \
    --instance-type "$MASTER_INSTANCE_TYPE" \
    --key-name "$KEY_NAME" \
    --security-group-ids "$SG_ID" \
    --user-data "file://${USERDATA_MASTER_FILE}" \
    --block-device-mappings '[{"DeviceName":"/dev/xvda","Ebs":{"VolumeSize":20,"VolumeType":"gp3","DeleteOnTermination":true}}]' \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${CLUSTER_TAG}-master},{Key=Role,Value=master}]" \
    --region "$AWS_REGION" \
    --query 'Instances[0].InstanceId' --output text)
ok "Master instance launched: $MASTER_INSTANCE_ID"

info "Waiting for master to reach 'running' state..."
aws ec2 wait instance-running --instance-ids "$MASTER_INSTANCE_ID" --region "$AWS_REGION"

# Get both IPs. Public for our SSH; private for the agent's --server URL
# (agents inside the VPC talk to the master over the private network).
MASTER_PUBLIC_IP=$(aws ec2 describe-instances --instance-ids "$MASTER_INSTANCE_ID" \
    --region "$AWS_REGION" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
MASTER_PRIVATE_IP=$(aws ec2 describe-instances --instance-ids "$MASTER_INSTANCE_ID" \
    --region "$AWS_REGION" \
    --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text)
ok "Master IPs: public=$MASTER_PUBLIC_IP private=$MASTER_PRIVATE_IP"

# ─── wait for SSH ────────────────────────────────────────────────────────────
# ServerAliveInterval + ServerAliveCountMax means: send a keepalive every 15s,
# tear the connection down after 4 missed replies (60s). Without these, a dead
# SSH connection (NAT drop, master OOM) leaves rsync/scp hung indefinitely —
# observed 2026-08-01 where step-3b's results-download rsync hung for 1h28m
# with 65 EC2 instances still running because the wrapper's cleanup trap was
# blocked on the rsync child.
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes -o ServerAliveInterval=15 -o ServerAliveCountMax=4 -i $KEY_FILE"
SSH="ssh $SSH_OPTS ec2-user@$MASTER_PUBLIC_IP"
info "Waiting for SSH..."
for attempt in $(seq 1 30); do
    if $SSH "echo ok" &>/dev/null; then break; fi
    [[ $attempt -eq 30 ]] && { err "SSH timeout"; exit 1; }
    sleep 10
done
ok "SSH ready"

# ─── wait for k3s master to finish installing ───────────────────────────────
info "Waiting for k3s server to finish installing (~2-3 min)..."
for attempt in $(seq 1 60); do
    if $SSH "test -f /tmp/.k3s-master-ready" &>/dev/null; then break; fi
    [[ $attempt -eq 60 ]] && { err "k3s install timeout"; $SSH "cat /var/log/userdata.log" || true; exit 1; }
    sleep 5
    echo -ne "  Waiting for k3s install... $((attempt*5))s\r"
done
ok "k3s server installed"

# ─── extract the join token ─────────────────────────────────────────────────
info "Extracting k3s join token..."
scp $SSH_OPTS "ec2-user@$MASTER_PUBLIC_IP:~/k3s-token" "/tmp/k3s-token-${TIMESTAMP}" &>/dev/null
K3S_TOKEN=$(cat "/tmp/k3s-token-${TIMESTAMP}" | tr -d '\n')
rm -f "/tmp/k3s-token-${TIMESTAMP}"
[[ -z "$K3S_TOKEN" ]] && { err "Failed to extract k3s token"; exit 1; }
ok "Token extracted (length: ${#K3S_TOKEN} chars)"

# ═════════════════════════════════════════════════════════════════════════════
# STEP 3: Launch Template + Fleet for N agents
# ═════════════════════════════════════════════════════════════════════════════
info "Building agent user-data (embeds master IP + join token)..."
USERDATA_AGENT_FILE="/tmp/cluster-userdata-agent-${TIMESTAMP}.sh"
cat > "$USERDATA_AGENT_FILE" << AGENT_UD
#!/bin/bash
set -euo pipefail
exec > /var/log/userdata.log 2>&1

# curl-minimal is pre-installed on AL2023 and satisfies the k3s installer.
# No extra packages needed for the agent role.

# Registration-storm jitter: EC2 Fleet launches all N agents at essentially
# the same instant, so N k3s agents all fire their install + register-with-
# master calls simultaneously. At N=100, this saturated the master's control
# plane and blocked SSH (observed 2026-07-11 with both t3.medium and c6i.large
# masters — SSH banner-exchange timed out for the entire join window). Random
# 0-60s delay per instance spreads the registration rate to ~1.7 agents/second,
# which any modest 2-vCPU master can handle comfortably.
sleep \$(( RANDOM % 60 ))

# Join the k3s cluster as an agent. --server points at the master's PRIVATE IP
# (VPC-internal networking; no public-net traffic between cluster nodes).
curl -sfL https://get.k3s.io | K3S_URL=https://${MASTER_PRIVATE_IP}:6443 \
                              K3S_TOKEN=${K3S_TOKEN} \
                              sh -

echo "==> k3s agent joined at \$(date)"
AGENT_UD

# base64-encode the user-data for the Launch Template
AGENT_UD_B64=$(base64 -i "$USERDATA_AGENT_FILE" | tr -d '\n')

info "Creating Launch Template for agents..."
LT_DATA=$(cat << LT_JSON
{
    "ImageId": "$AMI_ID",
    "InstanceType": "$AGENT_INSTANCE_TYPE",
    "KeyName": "$KEY_NAME",
    "SecurityGroupIds": ["$SG_ID"],
    "UserData": "$AGENT_UD_B64",
    "BlockDeviceMappings": [
        {"DeviceName": "/dev/xvda", "Ebs": {"VolumeSize": 10, "VolumeType": "gp3", "DeleteOnTermination": true}}
    ],
    "TagSpecifications": [
        {"ResourceType": "instance", "Tags": [
            {"Key": "Name", "Value": "${CLUSTER_TAG}-agent"},
            {"Key": "Role", "Value": "agent"}
        ]}
    ]
}
LT_JSON
)
LAUNCH_TEMPLATE_ID=$(aws ec2 create-launch-template \
    --launch-template-name "${CLUSTER_TAG}-agents" \
    --launch-template-data "$LT_DATA" \
    --region "$AWS_REGION" \
    --query 'LaunchTemplate.LaunchTemplateId' --output text)
ok "Launch Template created: $LAUNCH_TEMPLATE_ID"

# Batched Fleet launch. Each fleet is Type=instant (no auto-relaunch, no
# maintenance) and requests FLEET_BATCH_SIZE agents. We wait
# FLEET_BATCH_WAIT_SEC between batches so the k3s master only ever handles
# ~FLEET_BATCH_SIZE simultaneous join requests instead of all
# $NUMBER_OF_NODES at once. Combined with the etcd datastore this scales
# comfortably to hundreds of agents on a c6i.large master.
FLEET_TYPE=$([[ "$USE_SPOT" == "true" ]] && echo "spot" || echo "on-demand")
_NUM_BATCHES=$(( (NUMBER_OF_NODES + FLEET_BATCH_SIZE - 1) / FLEET_BATCH_SIZE ))
info "Batched fleet launch: $NUMBER_OF_NODES agents in $_NUM_BATCHES batches of ${FLEET_BATCH_SIZE} ($AGENT_INSTANCE_TYPE $([[ "$USE_SPOT" == "true" ]] && echo Spot || echo On-Demand))"

_BATCH_IDX=0
_LAUNCHED=0
while (( _LAUNCHED < NUMBER_OF_NODES )); do
    _BATCH_IDX=$((_BATCH_IDX + 1))
    _THIS_BATCH=$(( NUMBER_OF_NODES - _LAUNCHED ))
    (( _THIS_BATCH > FLEET_BATCH_SIZE )) && _THIS_BATCH=$FLEET_BATCH_SIZE

    info "  batch $_BATCH_IDX/$_NUM_BATCHES: requesting $_THIS_BATCH agents..."
    FLEET_CONFIG=$(cat << FLEET_JSON
{
    "LaunchTemplateConfigs": [{
        "LaunchTemplateSpecification": {
            "LaunchTemplateId": "$LAUNCH_TEMPLATE_ID",
            "Version": "1"
        }
    }],
    "TargetCapacitySpecification": {
        "TotalTargetCapacity": $_THIS_BATCH,
        "OnDemandTargetCapacity": $([[ "$USE_SPOT" == "true" ]] && echo 0 || echo $_THIS_BATCH),
        "SpotTargetCapacity":      $([[ "$USE_SPOT" == "true" ]] && echo $_THIS_BATCH || echo 0),
        "DefaultTargetCapacityType": "$FLEET_TYPE"
    },
    "Type": "instant"
}
FLEET_JSON
)
    FLEET_RESULT=$(aws ec2 create-fleet \
        --cli-input-json "$FLEET_CONFIG" \
        --region "$AWS_REGION" \
        --output json)
    _BATCH_FLEET_ID=$(echo "$FLEET_RESULT" | jq -r '.FleetId')
    _BATCH_INSTANCE_IDS=$(echo "$FLEET_RESULT" | jq -r '.Instances[].InstanceIds[]?' | tr '\n' ' ')

    if [[ -z "$_BATCH_INSTANCE_IDS" ]]; then
        err "  batch $_BATCH_IDX launched no instances. Errors:"
        echo "$FLEET_RESULT" | jq '.Errors' >&2
        exit 1
    fi
    _BATCH_COUNT=$(echo "$_BATCH_INSTANCE_IDS" | wc -w | tr -d ' ')
    FLEET_IDS+=("$_BATCH_FLEET_ID")
    AGENT_INSTANCE_IDS="$AGENT_INSTANCE_IDS $_BATCH_INSTANCE_IDS"
    _LAUNCHED=$((_LAUNCHED + _BATCH_COUNT))
    ok "  batch $_BATCH_IDX launched: $_BATCH_FLEET_ID ($_BATCH_COUNT agents, ${_LAUNCHED}/${NUMBER_OF_NODES} total)"

    # Wait between batches (except after the last one — no point idling)
    if (( _LAUNCHED < NUMBER_OF_NODES )); then
        info "  waiting ${FLEET_BATCH_WAIT_SEC}s before next batch..."
        sleep "$FLEET_BATCH_WAIT_SEC"
    fi
done
ok "All $NUMBER_OF_NODES agents launched across $_BATCH_IDX batches"

# ═════════════════════════════════════════════════════════════════════════════
# STEP 4: Wait for the cluster to actually form
# ═════════════════════════════════════════════════════════════════════════════
info "Waiting for $NUMBER_OF_NODES agents to join the cluster..."
# Timeout: baseline 5 min + 3 s per node + full time we already spent on
# batch launches (each batch waited FLEET_BATCH_WAIT_SEC between). This
# stops the poll from timing out during the batching itself for large fleets.
_TOTAL_BATCH_WAIT=$(( _NUM_BATCHES * FLEET_BATCH_WAIT_SEC ))
CLUSTER_READY_TIMEOUT=$(( 300 + NUMBER_OF_NODES * 3 + _TOTAL_BATCH_WAIT ))
START_TS=$(date +%s)
LAST_LOG_TS=$START_TS
# SSH options with a short timeout — if the master is saturated by the join
# storm, we want to know quickly rather than blocking each iteration for 30s.
POLL_SSH_OPTS="$SSH_OPTS -o ServerAliveInterval=5 -o ServerAliveCountMax=2"
POLL_SSH="ssh $POLL_SSH_OPTS ec2-user@$MASTER_PUBLIC_IP"
CONSECUTIVE_SSH_FAILS=0
while true; do
    ELAPSED=$(( $(date +%s) - START_TS ))
    EXPECTED=$(( NUMBER_OF_NODES + 1 ))

    # Wrap kubectl in a single SSH invocation with a hard timeout — if it
    # hangs (master overloaded, SSH banner stall), we won't lose more than
    # 15s per iteration. Missing samples are counted separately so we can
    # tell "cluster hasn't grown" from "we can't see the cluster".
    NODES_RAW=$($POLL_SSH -o ConnectTimeout=15 \
        "timeout 10 kubectl get nodes --no-headers 2>/dev/null" 2>/dev/null || echo "")
    if [[ -z "$NODES_RAW" ]]; then
        CONSECUTIVE_SSH_FAILS=$(( CONSECUTIVE_SSH_FAILS + 1 ))
        READY_COUNT="?"; TOTAL_COUNT="?"
    else
        CONSECUTIVE_SSH_FAILS=0
        READY_COUNT=$(echo "$NODES_RAW" | grep -c ' Ready ')
        TOTAL_COUNT=$(echo "$NODES_RAW" | wc -l | tr -d ' ')
    fi

    if [[ "$READY_COUNT" != "?" && "$READY_COUNT" -ge "$EXPECTED" ]]; then
        ok "All $READY_COUNT/$EXPECTED nodes Ready after ${ELAPSED}s"
        break
    fi

    if (( ELAPSED >= CLUSTER_READY_TIMEOUT )); then
        err "Cluster-ready timeout after ${ELAPSED}s: $READY_COUNT/$EXPECTED Ready"
        info "Recent kubectl output (may be slow if master is overloaded):"
        $POLL_SSH "kubectl get nodes 2>&1 | tail -20" || true
        exit 1
    fi

    # Log every ~30s, tracking wall-clock since last log (the old `% 30 == 0`
    # test almost never matched because SSH latency varied per iteration).
    NOW=$(date +%s)
    if (( NOW - LAST_LOG_TS >= 30 )); then
        if (( CONSECUTIVE_SSH_FAILS > 0 )); then
            warn "  cluster forming: ${READY_COUNT}/${EXPECTED} Ready (${ELAPSED}s, ${CONSECUTIVE_SSH_FAILS} consec SSH timeouts — master may be overloaded)"
        else
            info "  cluster forming: ${READY_COUNT}/${EXPECTED} Ready (${ELAPSED}s elapsed)"
        fi
        LAST_LOG_TS=$NOW
    fi
    sleep 5
done

# ═════════════════════════════════════════════════════════════════════════════
# STEP 5: Retrieve kubeconfig + expose to local kubectl
# ═════════════════════════════════════════════════════════════════════════════
LOCAL_KUBECONFIG="${SCRIPT_DIR}/cluster-kubeconfig-${TIMESTAMP}.yaml"
info "Copying kubeconfig to $LOCAL_KUBECONFIG..."
scp $SSH_OPTS "ec2-user@$MASTER_PUBLIC_IP:~/kubeconfig" "$LOCAL_KUBECONFIG" &>/dev/null
# Rewrite: internal 127.0.0.1 → the master's public IP; drop the CA-data line
# and set insecure-skip-tls-verify=true because the cert's SAN list won't
# include the public IP unless we re-issue.
#
# Python (stdlib re) is used instead of sed because BSD/macOS sed handles
# the `a\` command differently from GNU sed. Python + regex is portable
# across all target platforms.
python3 - "$LOCAL_KUBECONFIG" "$MASTER_PUBLIC_IP" << 'PYEOF'
import re, sys
path = sys.argv[1]
public_ip = sys.argv[2]
with open(path) as f:
    content = f.read()
# Point kubectl at the public IP
content = re.sub(r'server: https://[\d.]+:6443',
                 f'server: https://{public_ip}:6443', content)
# Drop the CA-data line (we'll skip TLS verify instead)
content = re.sub(r'^\s*certificate-authority-data:.*\n', '', content, flags=re.M)
# Add insecure-skip-tls-verify: true right after the server: line
content = re.sub(r'(server: https://[\d.]+:6443\n)',
                 r'\1    insecure-skip-tls-verify: true\n', content)
with open(path, 'w') as f:
    f.write(content)
PYEOF
ok "kubeconfig ready"

# ═════════════════════════════════════════════════════════════════════════════
# STEP 6: Summary + wait loop
# ═════════════════════════════════════════════════════════════════════════════
echo ""
echo -e "${CYAN}════════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}  Cluster is up and ready.${NC}"
echo -e "${CYAN}════════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "  Master public IP  : ${GREEN}$MASTER_PUBLIC_IP${NC}"
echo -e "  Agent count       : ${GREEN}$NUMBER_OF_NODES${NC} × ${AGENT_INSTANCE_TYPE}"
echo -e "  Fleet IDs         : ${GREEN}${FLEET_IDS[*]}${NC}"
echo -e "  SSH key           : ${GREEN}$KEY_FILE${NC}"
echo -e "  Local kubeconfig  : ${GREEN}$LOCAL_KUBECONFIG${NC}"
echo ""
echo -e "  From your laptop, run:"
echo -e "    ${YELLOW}export KUBECONFIG=$LOCAL_KUBECONFIG${NC}"
echo -e "    ${YELLOW}kubectl get nodes${NC}"
echo ""
echo -e "  SSH into master:"
echo -e "    ${YELLOW}ssh -i $KEY_FILE ec2-user@$MASTER_PUBLIC_IP${NC}"
echo ""

# ═════════════════════════════════════════════════════════════════════════════
# STEP 7 (optional): --deploy-blockchain — install/build/run the specified
# consensus system on the cluster, then tear down.
#
# What this does:
#   1. Copies the SSH private key to the master so it can talk to the agent
#      nodes over the VPC private network for image distribution.
#   2. rsyncs the blockchain source (pbft-enhanced or pbft-rapidchain) to
#      the master.
#   3. Installs Node.js, pnpm, Java, JMeter, Docker on the master (if not
#      already there — Docker + k3s were installed by user-data).
#   4. Builds the two Docker images on the master.
#   5. Distributes those images to every agent via
#      `docker save … | ssh agent … k3s ctr images import -` in parallel.
#      This is the multi-EC2 replacement for the single-instance
#      `k3s ctr images import` that the existing start.sh does.
#   6. Runs the system's start.sh on the master with
#      SPREAD_PODS_ACROSS_NODES=true so kube-scheduler places 1 pod per
#      agent node.
#   7. Runs run-performance-test.sh on the master, then downloads the
#      results directory back to the local machine.
# ═════════════════════════════════════════════════════════════════════════════
if [[ -n "$DEPLOY_SYSTEM" ]]; then
    if [[ "$DEPLOY_SYSTEM" != "rapidchain" && "$DEPLOY_SYSTEM" != "enhanced" ]]; then
        err "--deploy-blockchain must be 'rapidchain' or 'enhanced' (got: $DEPLOY_SYSTEM)"
        exit 1
    fi

    _SYS_DIR="pbft-${DEPLOY_SYSTEM}"
    _NPS="${DEPLOY_NPS:-$NUMBER_OF_NODES}"   # default: single shard = all nodes
    _FAULTY="${DEPLOY_FAULTY_NODES:-0}"


    # Auto-scale CPU + memory per pod. Formula sized for c6i.large agents
    # (2 vCPU sustained, 4 GiB RAM per node, 1 pod per node via podAntiAffinity):
    #   CPU_PER_POD = 0.60 × √(NPS/4),      clamped to [0.60, 1.80] vCPU
    #   POD_MEMORY_MIB = 512 × √(NPS/4),    clamped to [512, 3584] MiB
    # 1.80 vCPU ceiling leaves 0.20 vCPU headroom for the k3s agent + kubelet;
    # 3584 MiB ceiling leaves ~512 MiB for OS + agent. Raised from prior
    # 0.30/256 baseline (t3.small burstable) because sustained CPU/RAM on
    # c6i.large is now real — the previous formula wasted headroom.
    if [[ -z "$DEPLOY_CPU_LIMIT" ]]; then
        DEPLOY_CPU_LIMIT=$(python3 -c "
import math
nps = float($_NPS)
val = max(0.60, min(1.80, 0.60 * math.sqrt(nps / 4.0)))
print(f'{val:.2f}')
")
    fi
    if [[ -z "$DEPLOY_POD_MEMORY_MIB" ]]; then
        DEPLOY_POD_MEMORY_MIB=$(python3 -c "
import math
nps = float($_NPS)
val = max(512, min(3584, int(512 * math.sqrt(nps / 4.0))))
print(val)
")
    fi

    banner_msg() {
        echo -e "${CYAN}════════════════════════════════════════════════════════════${NC}"
        echo -e "${CYAN}  $*${NC}"
        echo -e "${CYAN}════════════════════════════════════════════════════════════${NC}"
    }
    banner_msg "Deploying pbft-$DEPLOY_SYSTEM to the cluster"
    info "  NUMBER_OF_NODES          = $NUMBER_OF_NODES"
    info "  NUMBER_OF_NODES_PER_SHARD = $_NPS (single-shard by default)"
    info "  NUMBER_OF_FAULTY_NODES    = $_FAULTY"
    info "  CPU_LIMIT                 = ${DEPLOY_CPU_LIMIT} vCPU/pod (auto-sqrt-scaled)"
    info "  POD_MEMORY_MIB            = ${DEPLOY_POD_MEMORY_MIB} MiB/pod (auto-sqrt-scaled)"
    info "  TRANSACTION_THRESHOLD     = $DEPLOY_TRANSACTION_THRESHOLD"
    info "  JMETER_DURATION           = ${DEPLOY_JMETER_DURATION}s"
    if [[ "$DEPLOY_SYSTEM" == "rapidchain" ]]; then
        info "  HAS_COMMITTEE_SHARD       = $DEPLOY_COMMITTEE_SHARD"
        info "  BLOCK_THRESHOLD           = $DEPLOY_BLOCK_THRESHOLD (Zamani et al. per-block default; override with --deploy-block-threshold)"
    else
        info "  ENABLE_SHARD_MERGE        = $DEPLOY_ENABLE_SHARD_MERGE"
        info "  STRICT_BLOCK_THRESHOLD    = $DEPLOY_STRICT_THRESHOLD (1=fire only on full pool, matches RapidChain)"
    fi

    # ── 7.1 — propagate SSH key to master ─────────────────────────────────
    info "Copying SSH key to master (master→agent auth needed for image distribution)..."
    scp $SSH_OPTS "$KEY_FILE" "ec2-user@$MASTER_PUBLIC_IP:~/.ssh/cluster-key.pem" &>/dev/null
    $SSH "chmod 600 ~/.ssh/cluster-key.pem"
    ok "  key installed on master"

    # ── 7.1b — upload resource monitor ────────────────────────────────────
    # monitor-resources.sh samples per-pod CPU/mem via `kubectl top` and network
    # I/O via `kubectl exec cat /proc/net/dev`, writing one CSV row per sample.
    # Runs in the background during the JMeter phase and is killed after stats
    # collection. Output CSV downloaded alongside the test results in step 7.8.
    if [[ -f "${SCRIPT_DIR}/monitor-resources.sh" ]]; then
        scp $SSH_OPTS "${SCRIPT_DIR}/monitor-resources.sh" \
            "ec2-user@${MASTER_PUBLIC_IP}:~/monitor-resources.sh" &>/dev/null
        $SSH "chmod +x ~/monitor-resources.sh"
        ok "  monitor-resources.sh installed on master"
    else
        warn "  monitor-resources.sh not found locally — resource metrics will be skipped"
    fi

    # ── 7.2 — rsync the blockchain source ────────────────────────────────
    info "Rsyncing $_SYS_DIR to master (exclude node_modules, results, logs)..."
    $SSH "mkdir -p ~/blockchain/custom-consensus/$_SYS_DIR"
    rsync -az --delete \
        --exclude=node_modules --exclude=coverage --exclude=performance-results \
        --exclude=diagrams --exclude=temp --exclude=server.log --exclude=jmeter.log \
        --exclude='*.jtl' --exclude=.DS_Store \
        -e "ssh $SSH_OPTS" \
        "${SCRIPT_DIR}/${_SYS_DIR}/" \
        "ec2-user@${MASTER_PUBLIC_IP}:~/blockchain/custom-consensus/${_SYS_DIR}/"
    ok "  source uploaded"

    # ── 7.3 — install prerequisites on the master ────────────────────────
    info "Installing Node.js/pnpm/Java/JMeter/Docker on master..."
    $SSH 'bash -s' << 'MASTER_PREREQS'
set -euo pipefail
# Docker (needed for image builds; k3s uses containerd but we build w/ docker)
# socat: kernel-level TCP relay used to forward master localhost:PORT → agent-IP:PORT
# in multi-EC2 mode (see run-performance-test.sh for the setup block).
sudo dnf install -y -q --allowerasing docker jq rsync tar socat
sudo systemctl enable --now docker
sudo usermod -aG docker ec2-user || true
# Java + JMeter for the load generator
sudo dnf install -y -q --allowerasing java-21-amazon-corretto-headless
if ! command -v jmeter &>/dev/null; then
    curl -fsSLo /tmp/jmeter.tgz "https://downloads.apache.org/jmeter/binaries/apache-jmeter-5.6.3.tgz"
    sudo tar xf /tmp/jmeter.tgz -C /opt
    sudo ln -sf /opt/apache-jmeter-5.6.3/bin/jmeter /usr/local/bin/jmeter
    rm /tmp/jmeter.tgz
fi
# Node.js 20 + pnpm 10
if ! command -v node &>/dev/null || [[ "$(node -v 2>/dev/null | cut -c2-3)" != "20" ]]; then
    curl -fsSL https://rpm.nodesource.com/setup_20.x | sudo bash -
    sudo dnf install -y -q --allowerasing nodejs
fi
sudo corepack enable 2>/dev/null || true
sudo corepack prepare pnpm@10 --activate 2>/dev/null || true
corepack prepare pnpm@10 --activate 2>/dev/null || true
echo "==> Prereqs installed."
MASTER_PREREQS
    ok "  prereqs installed"

    # ── 7.4 — install Node deps + build Docker images on the master ──────
    info "Installing Node deps + building Docker images..."
    $SSH "bash -s" << REMOTE_BUILD
set -euo pipefail
cd ~/blockchain/custom-consensus/${_SYS_DIR}
HUSKY=0 pnpm install --frozen-lockfile
export DOCKER_BUILDKIT=1
if [[ "$DEPLOY_SYSTEM" == "rapidchain" ]]; then
    sudo DOCKER_BUILDKIT=1 docker build --no-cache -f Dockerfile.p2p  -t lebaz20/blockchain-rapidchain-p2p-server:latest .
    sudo DOCKER_BUILDKIT=1 docker build --no-cache -f Dockerfile.core -t lebaz20/blockchain-rapidchain-core-server:latest .
else
    sudo DOCKER_BUILDKIT=1 docker build --no-cache -f Dockerfile.p2p  -t lebaz20/blockchain-p2p-server:latest .
    sudo DOCKER_BUILDKIT=1 docker build --no-cache -f Dockerfile.core -t lebaz20/blockchain-core-server:latest .
fi
# Import into the master's own k3s containerd (agents get the images via scp below)
if [[ "$DEPLOY_SYSTEM" == "rapidchain" ]]; then
    sudo docker save lebaz20/blockchain-rapidchain-p2p-server:latest  | sudo k3s ctr images import -
    sudo docker save lebaz20/blockchain-rapidchain-core-server:latest | sudo k3s ctr images import -
else
    sudo docker save lebaz20/blockchain-p2p-server:latest  | sudo k3s ctr images import -
    sudo docker save lebaz20/blockchain-core-server:latest | sudo k3s ctr images import -
fi
echo "==> Images built and imported on master."
REMOTE_BUILD
    ok "  images built on master"

    # ── 7.5 — distribute images to every agent (parallel) ────────────────
    # k3s pulls from containerd, not from Docker Hub. So each agent's
    # containerd needs the image loaded via `k3s ctr images import`.
    info "Distributing images to all $NUMBER_OF_NODES agent(s) in parallel..."
    if [[ "$DEPLOY_SYSTEM" == "rapidchain" ]]; then
        _IMG_P2P="lebaz20/blockchain-rapidchain-p2p-server:latest"
        _IMG_CORE="lebaz20/blockchain-rapidchain-core-server:latest"
    else
        _IMG_P2P="lebaz20/blockchain-p2p-server:latest"
        _IMG_CORE="lebaz20/blockchain-core-server:latest"
    fi
    $SSH "bash -s" << REMOTE_DISTRIBUTE
# Deliberate: no 'set -e'. grep -c on empty returns 1 which would abort; and
# a single agent failing shouldn't kill the whole distribution.
set -uo pipefail

# List worker (non-master) node IPs. Using a label selector is more robust
# than jsonpath with escaped dots inside a heredoc — k3s adds the control-
# plane label only to the master, so '!<label>' selects every worker.
AGENT_IPS=\$(kubectl get nodes --no-headers -l '!node-role.kubernetes.io/control-plane' -o wide 2>/dev/null | awk '{print \$6}')
_AGENT_COUNT=\$(echo "\$AGENT_IPS" | grep -c . || echo 0)
echo "==> Found agents to distribute to:"
echo "\$AGENT_IPS" | sed 's/^/    /'
echo "==> Total: \$_AGENT_COUNT"

if [[ "\$_AGENT_COUNT" -lt 1 ]]; then
    echo "ERROR: no agent IPs found — dumping full kubectl get nodes for debugging:"
    kubectl get nodes -o wide
    exit 1
fi

# Save both images once to tar; then scp+import in parallel.
echo "==> Saving images to /tmp/p2p.tar and /tmp/core.tar..."
sudo docker save $_IMG_P2P  | sudo tee /tmp/p2p.tar  > /dev/null
sudo docker save $_IMG_CORE | sudo tee /tmp/core.tar > /dev/null
sudo chmod 644 /tmp/p2p.tar /tmp/core.tar
_P2P_SIZE=\$(du -h /tmp/p2p.tar | awk '{print \$1}')
_CORE_SIZE=\$(du -h /tmp/core.tar | awk '{print \$1}')
echo "==> Image tars ready: p2p=\$_P2P_SIZE core=\$_CORE_SIZE"

echo "==> Distributing to agents in parallel..."
pids=()
for AGENT in \$AGENT_IPS; do
  (
    if scp -o StrictHostKeyChecking=no -o ConnectTimeout=20 -i ~/.ssh/cluster-key.pem -q \
        /tmp/p2p.tar /tmp/core.tar ec2-user@\$AGENT:/tmp/ 2>&1; then
      ssh -o StrictHostKeyChecking=no -o ConnectTimeout=20 -i ~/.ssh/cluster-key.pem \
          ec2-user@\$AGENT 'sudo k3s ctr images import /tmp/p2p.tar && sudo k3s ctr images import /tmp/core.tar && rm /tmp/p2p.tar /tmp/core.tar' \
          2>&1 && echo "  ✓ agent \$AGENT loaded images" || echo "  ✗ agent \$AGENT: ctr import failed"
    else
      echo "  ✗ agent \$AGENT: scp failed"
    fi
  ) & pids+=(\$!)
done
_FAIL=0
for pid in "\${pids[@]}"; do wait "\$pid" || _FAIL=\$((_FAIL + 1)); done
rm -f /tmp/p2p.tar /tmp/core.tar
if [[ "\$_FAIL" -gt 0 ]]; then
    echo "==> WARNING: \$_FAIL of \$_AGENT_COUNT agent distributions failed"
fi
echo "==> Distribution complete."
REMOTE_DISTRIBUTE
    ok "  images distributed"

    # ── 7.6 — patch start.sh so it does not try to re-build docker images ─
    info "Patching start.sh to skip redundant docker build step..."
    $SSH "sed -i 's|^docker build|# docker build (pre-loaded into containerd)|' ~/blockchain/custom-consensus/$_SYS_DIR/start.sh || true"

    # ── 7.7 — run the actual performance test on the master ──────────────
    info "Launching run-performance-test.sh on master (live output below)..."
    _RUN_SCRIPT="/tmp/deploy-run-${DEPLOY_SYSTEM}.sh"
    cat << REMOTE_RUN | $SSH "cat > $_RUN_SCRIPT"
#!/bin/bash
set -euo pipefail
ulimit -n 1048576 2>/dev/null || ulimit -n 65536 2>/dev/null || true
export KUBECONFIG=/home/ec2-user/.kube/config
[[ ! -f \$KUBECONFIG ]] && sudo cp /etc/rancher/k3s/k3s.yaml \$KUBECONFIG && sudo chown ec2-user:ec2-user \$KUBECONFIG

# Blockchain workload env
export NUMBER_OF_NODES=${NUMBER_OF_NODES}
export NUMBER_OF_FAULTY_NODES=${_FAULTY}
export NUMBER_OF_NODES_PER_SHARD=${_NPS}
export HAS_COMMITTEE_SHARD=${DEPLOY_COMMITTEE_SHARD}
export TRANSACTION_THRESHOLD=${DEPLOY_TRANSACTION_THRESHOLD}
# Rapidchain-only: BLOCK_THRESHOLD (default 1 = per-block validation per original
# RapidChain paper). Enhanced ignores this env var; setting it unconditionally is
# harmless.
export BLOCK_THRESHOLD=${DEPLOY_BLOCK_THRESHOLD}
# Enhanced-only: shard-merge on by default so we benchmark enhanced's full
# architecture (dead-shard TXs merge into healthy shards) instead of a degraded
# raw-sharded-PBFT variant. Rapidchain ignores this env var.
export ENABLE_SHARD_MERGE=${DEPLOY_ENABLE_SHARD_MERGE}
# Enhanced-only: strict-threshold gate so enhanced fires only when pool is full
# (default 1 = matched with RapidChain for tx-per-block parity). Rapidchain
# ignores this env var.
export STRICT_BLOCK_THRESHOLD=${DEPLOY_STRICT_THRESHOLD}
export CPU_LIMIT=${DEPLOY_CPU_LIMIT}
export POD_MEMORY_MIB=${DEPLOY_POD_MEMORY_MIB}
# NODE_OPTIONS is picked up by prepare-config.js and injected into every pod's
# env. Left empty by default; set explicitly at NPS>=100 to cap V8 heap below
# the container memory limit (default V8 ceiling can exceed a 1280 MiB pod cap
# and trigger OOMKill mid-consensus). See prepare-config.js:NODE_OPTIONS.
export NODE_OPTIONS="${DEPLOY_NODE_OPTIONS}"
# Multi-EC2 uses hostNetwork so pods bind directly to their agent's ports
# (avoids the flannel VXLAN overhead). run-performance-test.sh then spawns
# `socat` forwarders on the master mapping localhost:PORT → agent-IP:PORT,
# so JMeter and stats collection can still address pods via localhost.
#
# We deliberately do NOT use USE_HOST_NETWORK=false + kubectl port-forward:
# 100 concurrent port-forwards saturate the master's kube-apiserver (SPDY
# streams) and freeze SSH. socat is a plain kernel TCP relay — negligible
# CPU/RAM per forwarder — so it scales to 100+ pods on a modest c6i.large.
export USE_HOST_NETWORK=true
export SPREAD_PODS_ACROSS_NODES=true   # ← key: forces 1-pod-per-node scheduling
export AUTOMATED_TEST=true
export JMETER_DURATION=${DEPLOY_JMETER_DURATION}
${DEPLOY_JMETER_THREADS:+export JMETER_THREADS=${DEPLOY_JMETER_THREADS}}
${DEPLOY_JMETER_THROUGHPUT:+export JMETER_THROUGHPUT=${DEPLOY_JMETER_THROUGHPUT}}
export PATH=\$PATH:/usr/local/bin

cd ~/blockchain/custom-consensus/${_SYS_DIR}
chmod +x start.sh run-performance-test.sh

# Start resource sampler in background (writes CSV every SAMPLE_INTERVAL seconds).
# Runs for the full test lifetime so CPU/mem/net traces cover startup → JMeter →
# drain → stats collection. Killed via SIGTERM after run-performance-test.sh exits.
_RES_CSV=/tmp/${DEPLOY_SYSTEM}-resources.csv
if [[ -x ~/monitor-resources.sh ]]; then
    SAMPLE_INTERVAL=5 ~/monitor-resources.sh "\$_RES_CSV" "${DEPLOY_SYSTEM}" > /tmp/monitor.log 2>&1 &
    _MON_PID=\$!
    echo "==> resource monitor PID \$_MON_PID → \$_RES_CSV"
fi

# Ensure the sampler dies even if the test errors out mid-run.
trap '[[ -n "\${_MON_PID:-}" ]] && kill -TERM "\$_MON_PID" 2>/dev/null || true' EXIT

./run-performance-test.sh 2>&1 | tee /tmp/deploy-run.log
_TEST_RC=\${PIPESTATUS[0]}

# Give the sampler one more sample after test end, then stop.
sleep 5
if [[ -n "\${_MON_PID:-}" ]] && kill -0 "\$_MON_PID" 2>/dev/null; then
    kill -TERM "\$_MON_PID" 2>/dev/null || true
    wait "\$_MON_PID" 2>/dev/null || true
fi
echo "==> resource monitor stopped (test exit=\$_TEST_RC)"
exit \$_TEST_RC
REMOTE_RUN
    $SSH "chmod +x $_RUN_SCRIPT"

    _run_exit=0
    $SSH -t "$_RUN_SCRIPT" || _run_exit=$?
    if [[ $_run_exit -ne 0 ]]; then
        warn "run-performance-test.sh exited with code $_run_exit — will still download partial results"
    else
        ok "  test completed"
    fi

    # ── 7.8 — download results back to local ─────────────────────────────
    _LOCAL_RESULTS="${SCRIPT_DIR}/multi-ec2-results-${DEPLOY_SYSTEM}-${TIMESTAMP}"
    mkdir -p "$_LOCAL_RESULTS"
    info "Downloading results to $_LOCAL_RESULTS..."
    rsync -az --no-perms -e "ssh $SSH_OPTS" \
        "ec2-user@${MASTER_PUBLIC_IP}:~/blockchain/custom-consensus/${_SYS_DIR}/performance-results/" \
        "$_LOCAL_RESULTS/" 2>/dev/null || true
    scp $SSH_OPTS "ec2-user@${MASTER_PUBLIC_IP}:/tmp/deploy-run.log" "$_LOCAL_RESULTS/deploy-run.log" 2>/dev/null || true
    scp $SSH_OPTS "ec2-user@${MASTER_PUBLIC_IP}:~/blockchain/custom-consensus/${_SYS_DIR}/server.log" "$_LOCAL_RESULTS/server.log" 2>/dev/null || true
    # Resource-usage CSV from monitor-resources.sh (may be absent if the monitor
    # never started, e.g. metrics-server unavailable or script upload failed).
    scp $SSH_OPTS "ec2-user@${MASTER_PUBLIC_IP}:/tmp/${DEPLOY_SYSTEM}-resources.csv" \
        "$_LOCAL_RESULTS/pbft-${DEPLOY_SYSTEM}-resources.csv" 2>/dev/null || true
    scp $SSH_OPTS "ec2-user@${MASTER_PUBLIC_IP}:/tmp/monitor.log" \
        "$_LOCAL_RESULTS/monitor.log" 2>/dev/null || true
    # Per-pod post-hoc log dumps (from run-performance-test.sh cleanup step).
    # Directory may be empty if the test bailed before cleanup ran.
    rsync -az --no-perms -e "ssh $SSH_OPTS" \
        "ec2-user@${MASTER_PUBLIC_IP}:~/blockchain/custom-consensus/${_SYS_DIR}/pod-logs/" \
        "$_LOCAL_RESULTS/pod-logs/" 2>/dev/null || true
    ok "  results at: $_LOCAL_RESULTS"

    banner_msg "Deploy finished — tearing down"
    # Deploy path is done; skip the wait loop below, go straight to cleanup
    exit $_run_exit
fi

if [[ "$AUTO_TEARDOWN_SEC" -gt 0 ]]; then
    info "Cluster will auto-teardown in ${AUTO_TEARDOWN_SEC}s (or on Ctrl+C)..."
    sleep "$AUTO_TEARDOWN_SEC"
    info "Auto-teardown timer fired"
else
    info "Cluster stays up until you press Ctrl+C (teardown fires on exit)"
    # Foreground wait — Ctrl+C hits our INT trap → cleanup runs
    while true; do sleep 60; done
fi
