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
#   --instance-type      EC2 type    [default: auto-selected by --nodes]
#                        Auto-defaults:  ≤8  → c6i.xlarge (4 vCPU)
#                                       ≤16 → c6i.2xlarge (8 vCPU)
#                                       ≤32 → c6i.4xlarge (16 vCPU)
#                                       ≤64 → c6i.8xlarge (32 vCPU)
#                                      ≤128 → c6i.16xlarge (64 vCPU)
#                                       >128 → c6i.32xlarge (128 vCPU)
#   --nodes              NUMBER_OF_NODES            [default: 24]
#   --faulty             NUMBER_OF_FAULTY_NODES     [default: floor((nodes-1)/3)]
#   --key-name           Existing EC2 key pair name (optional; one is created
#                        automatically if omitted and deleted on cleanup)
#   --on-demand          Use On-Demand pricing instead of Spot (Spot is default; ~70% cheaper)
#   --merge              Enable shard merging for enhanced protocol (default)
#   --no-merge           Disable shard merging for enhanced protocol
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
INSTANCE_TYPE="${INSTANCE_TYPE:-}"   # empty = auto-select by node count
NUMBER_OF_NODES="${NUMBER_OF_NODES:-24}"
NUMBER_OF_FAULTY_NODES="${NUMBER_OF_FAULTY_NODES:-}"
USE_SPOT=true
ENHANCED_MERGE=1
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
        --merge)           ENHANCED_MERGE=1;                      shift   ;;
        --no-merge)        ENHANCED_MERGE=0;                      shift   ;;
        --keep-instance)   KEEP_INSTANCE=true;                    shift   ;;
        --skip-upload)     SKIP_UPLOAD=true;                      shift   ;;
        --instance-id)     INSTANCE_ID="$2";                      shift 2 ;;
        *) err "Unknown option: $1"; exit 1 ;;
    esac
done

export AWS_DEFAULT_REGION="$AWS_REGION"

# ─── auto-derive faulty nodes: floor((n-1)/3) ─ standard PBFT safety bound ───
if [[ -z "$NUMBER_OF_FAULTY_NODES" ]]; then
    NUMBER_OF_FAULTY_NODES=$(( (NUMBER_OF_NODES - 1) / 3 ))
fi

# ─── auto-select instance type by node count ─────────────────────────────────
# Each node runs as a K8s pod. Rough sizing: ~0.2 vCPU (CPU_LIMIT) + ~256 MiB per node,
# plus headroom for k3s, core server, JMeter, Docker, and OS (~4 vCPU overhead).
# The mapping below keeps at least 2× headroom so CPU throttling and pod scheduling
# pressure don't distort benchmark results.
#   Formula: need (nodes × 0.2) + 4 vCPU overhead, then 2× for headroom.
#   64 nodes: (64×0.2)+4 = 16.8 → need ≥34 vCPU → c6i.8xlarge (32 vCPU, close enough)
if [[ -z "$INSTANCE_TYPE" ]]; then
    if   (( NUMBER_OF_NODES <= 8   )); then INSTANCE_TYPE="c6i.xlarge"    # 4 vCPU, 8 GiB
    elif (( NUMBER_OF_NODES <= 16  )); then INSTANCE_TYPE="c6i.2xlarge"   # 8 vCPU, 16 GiB
    elif (( NUMBER_OF_NODES <= 32  )); then INSTANCE_TYPE="c6i.4xlarge"   # 16 vCPU, 32 GiB
    elif (( NUMBER_OF_NODES <= 64  )); then INSTANCE_TYPE="c6i.8xlarge"   # 32 vCPU, 64 GiB
    elif (( NUMBER_OF_NODES <= 128 )); then INSTANCE_TYPE="c6i.16xlarge"  # 64 vCPU, 128 GiB
    else                                    INSTANCE_TYPE="c6i.32xlarge"  # 128 vCPU, 256 GiB
    fi
fi

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

        # Reuse the ControlMaster socket if it is still open (faster, avoids reconnect
        # delays). Fall back to a direct connection if the socket is gone.
        local _SSH_CTL_OPT=""
        if [[ -n "${SSH_CTL:-}" && -S "${SSH_CTL:-/dev/null}" ]]; then
            _SSH_CTL_OPT="-o ControlMaster=no -o ControlPath=${SSH_CTL}"
        fi
        local _SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=30 -o BatchMode=yes -i $KEY_FILE ${_SSH_CTL_OPT}"

        # Main comparison run log
        scp $_SSH_OPTS \
            "ec2-user@${PUBLIC_IP}:/tmp/comparison-run.log" \
            "${LOG_DIR}/comparison-run.log" 2>/dev/null || true

        # server.log from each protocol — gzip on the remote first so transfer is fast.
        # Without gzip a verbose rapidchain run can produce 200 MB+ (log spam).
        # The .gz is decompressed locally so the saved file stays a plain .log.
        for _proto in pbft-enhanced pbft-rapidchain; do
            ssh $_SSH_OPTS "ec2-user@${PUBLIC_IP}" \
                "gzip -c ~/blockchain/custom-consensus/${_proto}/server.log 2>/dev/null" \
                | gunzip -c \
                > "${LOG_DIR}/${_proto}-server.log" 2>/dev/null || true
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
            "sudo journalctl -u k3s --no-pager --since '1 hour ago' 2>/dev/null | tail -10000" \
            > "${LOG_DIR}/k3s-journal.log" 2>/dev/null || true

        # List of non-Running pods at exit time
        ssh $_SSH_OPTS "ec2-user@${PUBLIC_IP}" \
            "KUBECONFIG=/home/ec2-user/.kube/config kubectl get pods -A --no-headers 2>/dev/null \
             | grep -v Running || true" \
            > "${LOG_DIR}/pods-not-running.txt" 2>/dev/null || true

        # Generated config files (nodesEnv.yml, jmeter_ports.csv, kubeConfig.yml, config.js)
        for _proto in pbft-enhanced pbft-rapidchain; do
            local _CFG_DIR="${LOG_DIR}/${_proto}-config"
            mkdir -p "$_CFG_DIR"
            for _cfg in nodesEnv.yml jmeter_ports.csv kubeConfig.yml config.js; do
                scp $_SSH_OPTS \
                    "ec2-user@${PUBLIC_IP}:~/blockchain/custom-consensus/${_proto}/${_cfg}" \
                    "${_CFG_DIR}/${_cfg}" 2>/dev/null || true
            done
        done

        if [[ $exit_code -ne 0 ]]; then
            warn "Test failed — logs saved to: $LOG_DIR"
        else
            ok "Logs saved to: $LOG_DIR"
        fi
    fi

    # Close ControlMaster socket (if it exists) so the background master exits cleanly
    if [[ -n "${SSH_CTL:-}" && -S "${SSH_CTL:-/dev/null}" ]]; then
        ssh -o ControlPath="$SSH_CTL" -O exit "ec2-user@${PUBLIC_IP:-localhost}" &>/dev/null || true
    fi

    # Remove temp key file from disk
    if [[ -n "${KEY_FILE:-}" && -f "${KEY_FILE:-/dev/null}" ]]; then
        rm -f "$KEY_FILE"
        info "Removed local key file: $KEY_FILE"
    fi

    # Remove temp user-data file
    if [[ -n "${USERDATA_FILE:-}" && -f "${USERDATA_FILE:-/dev/null}" ]]; then
        rm -f "$USERDATA_FILE"
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

# Try multiple IP detection endpoints; fall back to 0.0.0.0/0 (SSH still needs key auth).
# HTTPS and TCP-22 outbound can transit different NAT paths on some ISPs, causing the
# checkip IP to mismatch what EC2 sees for the SSH connection. 0.0.0.0/0 avoids this.
MY_IP=$(curl -sf --max-time 5 https://checkip.amazonaws.com \
        || curl -sf --max-time 5 https://api.ipify.org \
        || echo "0.0.0.0")
# Use the detected IP if it looks valid; fall back to open (0.0.0.0/0) otherwise.
# Key-pair authentication is the real security barrier for these temp SGs.
if [[ "$MY_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ && "$MY_IP" != "0.0.0.0" ]]; then
    SSH_CIDR="${MY_IP}/32"
else
    warn "Could not detect public IP — opening SSH to 0.0.0.0/0 (protected by key auth)"
    SSH_CIDR="0.0.0.0/0"
fi
# Also allow IPv6 wildcard so dual-stack hosts work without additional detective work
aws ec2 authorize-security-group-ingress \
    --group-id "$SG_ID" \
    --protocol tcp --port 22 \
    --cidr "$SSH_CIDR" \
    --region "$AWS_REGION" &>/dev/null
# Unconditionally add IPv6 all-traffic rule so IPv6 hosts aren't blocked
aws ec2 authorize-security-group-ingress \
    --group-id "$SG_ID" \
    --protocol tcp --port 22 \
    --ipv6-cidr "::/0" \
    --region "$AWS_REGION" &>/dev/null 2>&1 || true
ok "Security group '$SG_NAME' ($SG_ID) — SSH allowed from $SSH_CIDR (IPv4) + ::/0 (IPv6)"

# ─── generate user-data script (runs during boot, before SSH) ─────────────────
# This overlaps system package installation with the instance boot + SSH wait,
# saving ~60-90s of billable time that was previously spent after SSH connected.
USERDATA_FILE="/tmp/blockchain-userdata-${TIMESTAMP}.sh"
cat > "$USERDATA_FILE" << 'USERDATA'
#!/bin/bash
set -euo pipefail
exec > /var/log/userdata.log 2>&1

# ── system limits ──
tee -a /etc/security/limits.conf > /dev/null << 'LIMITS'
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
LIMITS
sysctl -w fs.file-max=2097152 > /dev/null
sysctl -w fs.inotify.max_user_instances=8192 > /dev/null
sysctl -w fs.inotify.max_user_watches=524288 > /dev/null
sysctl -w net.netfilter.nf_conntrack_max=1048576 > /dev/null 2>&1 || true
sysctl -w net.core.somaxconn=65535 > /dev/null
sysctl -w net.ipv4.ip_local_port_range="6000 65535" > /dev/null
sysctl -w kernel.pid_max=4194304 > /dev/null
sysctl -w vm.max_map_count=262144 > /dev/null
cat << 'SYSCTL' | tee -a /etc/sysctl.conf > /dev/null
fs.file-max=2097152
fs.inotify.max_user_instances=8192
fs.inotify.max_user_watches=524288
net.netfilter.nf_conntrack_max=1048576
net.core.somaxconn=65535
net.ipv4.ip_local_port_range=6000 65535
kernel.pid_max=4194304
vm.max_map_count=262144
SYSCTL

# ── IPVS kernel modules ──
for mod in ip_vs ip_vs_rr ip_vs_wrr ip_vs_sh nf_conntrack; do
    modprobe $mod 2>/dev/null || true
done
cat << 'MODULES' | tee /etc/modules-load.d/ipvs.conf > /dev/null
ip_vs
ip_vs_rr
ip_vs_wrr
ip_vs_sh
nf_conntrack
MODULES

# ── DNF packages (skip full upgrade — fresh AL2023 AMI is current) ──
dnf install -y -q git docker python3 bc jq rsync tar unzip ipvsadm

# ── Node.js 20 via NodeSource ──
curl -fsSL https://rpm.nodesource.com/setup_20.x | bash -
dnf install -y -q nodejs

# ── pnpm via corepack ──
corepack enable
corepack prepare pnpm@latest --activate

# ── Docker ──
systemctl enable --now docker
usermod -aG docker ec2-user

# ── signal completion ──
touch /tmp/.userdata-complete
echo "==> User-data setup complete at $(date)"
USERDATA

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
            --user-data "file://${USERDATA_FILE}" \
            --block-device-mappings '[{"DeviceName":"/dev/xvda","Ebs":{"VolumeSize":60,"VolumeType":"gp3","DeleteOnTermination":true}}]' \
            --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=blockchain-test-${TIMESTAMP}}]" \
            --region "$AWS_REGION" \
            --query 'Instances[0].InstanceId' \
            --output text
    }

    # Helper: get all AZs in the region, shuffle them so retries hit different AZs.
    _get_azs() {
        aws ec2 describe-availability-zones \
            --region "$AWS_REGION" \
            --query 'AvailabilityZones[?State==`available`].ZoneName' \
            --output text | tr '\t' '\n' | sort -R
    }

    INSTANCE_ID=""
    if [[ ${#SPOT_OPT[@]} -gt 0 ]]; then
        # Try Spot across all available AZs before giving up
        SPOT_FAILED=false
        while IFS= read -r _AZ; do
            info "Trying Spot launch in AZ: $_AZ ..."
            _SPOT_OUT=$(_run_instances "${SPOT_OPT[@]}" --placement "AvailabilityZone=${_AZ}" 2>&1) && {
                # run-instances succeeded — verify the output looks like an instance ID
                if [[ "$_SPOT_OUT" =~ ^i- ]]; then
                    INSTANCE_ID="$_SPOT_OUT"
                    ok "Spot instance launched in $_AZ: $INSTANCE_ID"
                    break
                fi
            } || {
                _ERR="$_SPOT_OUT"
                if echo "$_ERR" | grep -qE "InsufficientInstanceCapacity|InsufficientCapacity|MaxSpotInstanceCountExceeded|SpotMaxPriceTooLow|SpotCapacityNotAvailable|CapacityNotAvailable|Unsupported|no supported"; then
                    warn "Spot capacity unavailable in $_AZ — trying next AZ ..."
                else
                    # Unexpected error — surface it and abort
                    echo "$_ERR" >&2
                    exit 1
                fi
            }
        done < <(_get_azs)

        if [[ -z "$INSTANCE_ID" ]]; then
            warn "No Spot capacity available in any AZ for $INSTANCE_TYPE — falling back to On-Demand ..."
            SPOT_OPT=()
            SPOT_FAILED=true
        fi
    fi

    if [[ -z "$INSTANCE_ID" ]]; then
        # On-Demand: also retry across AZs in case one AZ is out of on-demand capacity
        for _AZ in $(_get_azs); do
            info "Trying On-Demand launch in AZ: $_AZ ..."
            _OD_OUT=$(_run_instances --placement "AvailabilityZone=${_AZ}" 2>&1) && {
                if [[ "$_OD_OUT" =~ ^i- ]]; then
                    INSTANCE_ID="$_OD_OUT"
                    ok "On-Demand instance launched in $_AZ: $INSTANCE_ID"
                    break
                fi
            } || {
                _ERR="$_OD_OUT"
                if echo "$_ERR" | grep -qE "InsufficientInstanceCapacity|InsufficientCapacity|CapacityNotAvailable|Unsupported|no supported"; then
                    warn "On-Demand capacity unavailable in $_AZ — trying next AZ ..."
                else
                    echo "$_ERR" >&2
                    exit 1
                fi
            }
        done
    fi

    if [[ -z "$INSTANCE_ID" ]]; then
        err "Could not launch $INSTANCE_TYPE in any AZ (Spot and On-Demand both exhausted)."
        err "Try a different --instance-type or --aws-region, or wait for capacity to free up."
        exit 1
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

# ControlMaster=auto: the first SSH connection becomes the master; all subsequent
# connections (parallel installs, rsync, scp) reuse the same TCP socket.
# This avoids opening multiple simultaneous TCP connections (which triggers SYN
# rate-limiting on some ISP/NAT devices and causes "Operation timed out" for the
# parallel kubectl/k3s/JMeter install sessions).
SSH_CTL="/tmp/ssh-ctl-${TIMESTAMP}"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=15 -o ServerAliveInterval=30 -o ServerAliveCountMax=10 -o ControlMaster=auto -o ControlPath=${SSH_CTL} -o ControlPersist=600 -i $KEY_FILE"
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

# ─── wait for user-data to finish (system packages install during boot) ──────
# System packages (Docker, Node 20, pnpm, IPVS, sysctl) are installed via
# EC2 user-data which started running during instance boot — overlapping with
# the SSH wait above. Typically finishes before or shortly after SSH is ready.
info "Waiting for system packages (installed via user-data during boot) ..."
for attempt in $(seq 1 60); do
    if $SSH "test -f /tmp/.userdata-complete" &>/dev/null 2>&1; then
        break
    fi
    if [[ $attempt -eq 60 ]]; then
        err "User-data did not complete after 5 minutes. Check /var/log/userdata.log on instance."
        # Dump the remote log for diagnostics
        $SSH "cat /var/log/userdata.log 2>/dev/null" || true
        exit 1
    fi
    sleep 5
    echo -ne "  Waiting for user-data... ($((attempt * 5))s)\r"
done
ok "System packages ready (installed during boot)"

# ─── install kubectl ─────────────────────────────────────────────────────────
info "Installing kubectl, k3s, and JMeter in parallel ..."
$SSH 'bash -s' << 'REMOTE_KUBECTL' &
set -euo pipefail
KUBECTL_VERSION=$(curl -fsSL https://dl.k8s.io/release/stable.txt)
curl -fsSLo /tmp/kubectl "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl"
chmod +x /tmp/kubectl
sudo mv /tmp/kubectl /usr/local/bin/kubectl
kubectl version --client --short 2>/dev/null || kubectl version --client
echo "==> kubectl installed"
REMOTE_KUBECTL
_pid_kubectl=$!

# ─── install k3s (single-node Kubernetes) ────────────────────────────────────
$SSH 'bash -s' << 'REMOTE_K3S' &
set -euo pipefail

# Custom flannel config: default /24 per node only gives 254 pod IPs — not enough for 513 pods.
# SubnetLen=20 gives each node a /20 = 4096 IPs, plenty for 512+ pods.
cat << 'FLANNEL_CONF' | sudo tee /etc/k3s-flannel.json > /dev/null
{
    "Network": "10.42.0.0/16",
    "EnableIPv4": true,
    "EnableIPv6": false,
    "SubnetLen": 20,
    "Backend": {"Type": "host-gw"}
}
FLANNEL_CONF

# max-pods must exceed NUMBER_OF_NODES (512) + system pods (~10).
# IPVS proxy mode: O(1) service lookup vs iptables O(n).
# node-cidr-mask-size=20: must match flannel SubnetLen so controller and flannel agree.
curl -sfL https://get.k3s.io | sh -s - \
    --disable traefik \
    --disable servicelb \
    --write-kubeconfig-mode 644 \
    --flannel-conf=/etc/k3s-flannel.json \
    --kube-proxy-arg=proxy-mode=ipvs \
    --kube-proxy-arg=ipvs-scheduler=rr \
    --kube-controller-manager-arg=node-cidr-mask-size=20 \
    --kubelet-arg=max-pods=600

# Wait for k3s API server to be ready
for i in $(seq 1 30); do
    if kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml get nodes &>/dev/null 2>&1; then
        break
    fi
    sleep 5
done

# Wait for flannel to write subnet.env — pods cannot start networking until this
# file exists. kubectl get nodes succeeds as soon as the API server is up, but
# flannel may still be initializing. Without this wait every pod (including
# CoreDNS and system pods) fails immediately with "no such file or directory".
echo "Waiting for flannel subnet.env..."
for i in $(seq 1 60); do
    if [ -f /run/flannel/subnet.env ]; then
        echo "==> flannel subnet.env ready"
        break
    fi
    [ "$i" -eq 60 ] && echo "WARNING: flannel subnet.env not found after 5 min, continuing anyway"
    sleep 5
done

# Set up kubeconfig for ec2-user
mkdir -p /home/ec2-user/.kube
sudo cp /etc/rancher/k3s/k3s.yaml /home/ec2-user/.kube/config
sudo chown ec2-user:ec2-user /home/ec2-user/.kube/config
echo "==> k3s installed and running"
kubectl --kubeconfig /home/ec2-user/.kube/config get nodes

# Scale CoreDNS resources: 512 pods generate heavy DNS traffic at startup.
# Default 170Mi limit is too low — CoreDNS CrashLoopBackOff under load.
kubectl --kubeconfig /home/ec2-user/.kube/config -n kube-system patch deployment coredns --type='json' -p='[
  {"op": "replace", "path": "/spec/replicas", "value": 2},
  {"op": "replace", "path": "/spec/template/spec/containers/0/resources/limits/memory", "value": "512Mi"},
  {"op": "replace", "path": "/spec/template/spec/containers/0/resources/requests/memory", "value": "256Mi"}
]' || true
echo "==> CoreDNS scaled to 2 replicas with 512Mi memory"
REMOTE_K3S
_pid_k3s=$!

# ─── install Apache JMeter ───────────────────────────────────────────────────
$SSH 'bash -s' << 'REMOTE_JMETER' &
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
_pid_jmeter=$!

wait $_pid_kubectl || { err "kubectl install failed"; exit 1; }
wait $_pid_k3s     || { err "k3s install failed"; exit 1; }
wait $_pid_jmeter  || { err "JMeter install failed"; exit 1; }
ok "kubectl, k3s, and JMeter installed"

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
        "ec2-user@${PUBLIC_IP}:~/blockchain/custom-consensus/pbft-enhanced/" &
    _pid_rsync_enh=$!

    rsync $RSYNC_OPTS \
        -e "ssh $SSH_OPTS" \
        "${SCRIPT_DIR}/pbft-rapidchain/" \
        "ec2-user@${PUBLIC_IP}:~/blockchain/custom-consensus/pbft-rapidchain/" &
    _pid_rsync_rc=$!

    # Upload compare-performance.sh (while rsync finishes in background)
    scp $SSH_OPTS \
        "${SCRIPT_DIR}/compare-performance.sh" \
        "ec2-user@${PUBLIC_IP}:~/blockchain/custom-consensus/compare-performance.sh"

    wait $_pid_rsync_enh || { err "rsync pbft-enhanced failed"; exit 1; }
    wait $_pid_rsync_rc  || { err "rsync pbft-rapidchain failed"; exit 1; }

    ok "Code uploaded"

    # Install pnpm dependencies on the remote
    info "Installing Node.js dependencies on EC2 in parallel ..."
    $SSH 'bash -s' << 'REMOTE_DEPS'
set -euo pipefail
pids=()
(cd ~/blockchain/custom-consensus/pbft-enhanced   && HUSKY=0 pnpm install --frozen-lockfile) & pids+=($!)
(cd ~/blockchain/custom-consensus/pbft-rapidchain && HUSKY=0 pnpm install --frozen-lockfile) & pids+=($!)
for pid in "${pids[@]}"; do wait "$pid"; done
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
export DOCKER_BUILDKIT=1
# Build all 4 images concurrently — Docker daemon safely handles parallel builds
# BuildKit enables parallel layer processing for faster builds
pids=()
(cd ~/blockchain/custom-consensus/pbft-enhanced   && sudo DOCKER_BUILDKIT=1 docker build --no-cache -f Dockerfile.p2p  -t lebaz20/blockchain-p2p-server:latest .) & pids+=($!)
(cd ~/blockchain/custom-consensus/pbft-enhanced   && sudo DOCKER_BUILDKIT=1 docker build --no-cache -f Dockerfile.core -t lebaz20/blockchain-core-server:latest .) & pids+=($!)
(cd ~/blockchain/custom-consensus/pbft-rapidchain && sudo DOCKER_BUILDKIT=1 docker build --no-cache -f Dockerfile.p2p  -t lebaz20/blockchain-rapidchain-p2p-server:latest .) & pids+=($!)
(cd ~/blockchain/custom-consensus/pbft-rapidchain && sudo DOCKER_BUILDKIT=1 docker build --no-cache -f Dockerfile.core -t lebaz20/blockchain-rapidchain-core-server:latest .) & pids+=($!)
wait "${pids[@]}"

# Import into k3s containerd — pipe directly (no temp files on disk)
pids=()
sudo docker save lebaz20/blockchain-p2p-server:latest             | sudo k3s ctr images import - & pids+=($!)
sudo docker save lebaz20/blockchain-core-server:latest            | sudo k3s ctr images import - & pids+=($!)
sudo docker save lebaz20/blockchain-rapidchain-p2p-server:latest  | sudo k3s ctr images import - & pids+=($!)
sudo docker save lebaz20/blockchain-rapidchain-core-server:latest | sudo k3s ctr images import - & pids+=($!)
for pid in "${pids[@]}"; do wait "$pid"; done
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
# Ensure inotify limits are raised for this session (kubectl port-forward)
sudo sysctl -w fs.inotify.max_user_instances=8192 2>/dev/null || true
sudo sysctl -w fs.inotify.max_user_watches=524288 2>/dev/null || true
export KUBECONFIG=/home/ec2-user/.kube/config
export NUMBER_OF_NODES=${NUMBER_OF_NODES}
export NUMBER_OF_FAULTY_NODES=${NUMBER_OF_FAULTY_NODES}
export ENHANCED_MERGE=${ENHANCED_MERGE}
export USE_HOST_NETWORK=true
export PATH=\$PATH:/usr/local/bin
cd ~/blockchain/custom-consensus
chmod +x compare-performance.sh \\
         pbft-enhanced/run-performance-test.sh pbft-enhanced/start.sh \\
         pbft-rapidchain/run-performance-test.sh pbft-rapidchain/start.sh
./compare-performance.sh 2>&1 | tee /tmp/comparison-run.log
RUNSCRIPT

$SSH "chmod +x /tmp/run-test.sh"
# -t allocates a pty so output is line-buffered and streams live to your terminal.
# The SSH -t session may return non-zero when the ControlMaster socket closes even
# if the remote command succeeded. Capture the exit code explicitly so set -e
# doesn't abort the script before the summary/cleanup phase.
_ssh_exit=0
$SSH -t "/tmp/run-test.sh" || _ssh_exit=$?
if [[ $_ssh_exit -ne 0 ]]; then
    warn "SSH session exited with code $_ssh_exit (may be benign — ControlMaster close)"
fi
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
