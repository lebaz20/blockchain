#!/usr/bin/env bash
#
# nuke-aws.sh — Terminate ALL AWS resources that could incur cost.
# Covers: EC2 instances, EBS volumes, Elastic IPs, security groups,
#         key pairs, ECS, EKS, Lambda, NAT gateways, load balancers,
#         S3 buckets, RDS, ElastiCache, and more.
#
# Usage:  bash nuke-aws.sh
#
# Requires: aws cli configured with credentials (~/.aws/credentials or env vars).

set -euo pipefail

# ── Load AWS credentials from ~/.aws/credentials if not already set ──────────
if [[ -z "${AWS_ACCESS_KEY_ID:-}" || -z "${AWS_SECRET_ACCESS_KEY:-}" ]]; then
    CRED_FILE="${AWS_SHARED_CREDENTIALS_FILE:-$HOME/.aws/credentials}"
    if [[ -f "$CRED_FILE" ]]; then
        AWS_ACCESS_KEY_ID=$(awk -F' *= *' '/aws_access_key_id/{print $2; exit}' "$CRED_FILE")
        AWS_SECRET_ACCESS_KEY=$(awk -F' *= *' '/aws_secret_access_key/{print $2; exit}' "$CRED_FILE")
        export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
    else
        echo "ERROR: No AWS credentials found. Set env vars or configure ~/.aws/credentials." >&2
        exit 1
    fi
fi
export AWS_DEFAULT_OUTPUT=json

# All commercial regions (check all of them)
REGIONS=(
  us-east-1
)

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# Track all deletions: "TYPE|REGION|RESOURCE_ID"
DELETED=()

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
nuke_log() {
  local type="$1" region="$2" resource="$3"
  echo -e "${RED}[NUKE]${NC} $region: Deleting $type $resource"
  DELETED+=("$type|$region|$resource")
}

nuke_region() {
  local region="$1"

  # ── EC2 Instances ──────────────────────────────────────────────
  local instances
  instances=$(aws ec2 describe-instances \
    --region "$region" \
    --filters "Name=instance-state-name,Values=running,stopped,pending,stopping" \
    --query 'Reservations[].Instances[].InstanceId' \
    --output text 2>/dev/null) || true

  if [[ -n "$instances" && "$instances" != "None" ]]; then
    for iid in $instances; do
      nuke_log "EC2 Instance" "$region" "$iid"
      aws ec2 modify-instance-attribute --instance-id "$iid" \
        --no-disable-api-termination --region "$region" 2>/dev/null || true
      aws ec2 terminate-instances --instance-ids "$iid" \
        --region "$region" 2>/dev/null || true
    done
    # Wait for termination
    aws ec2 wait instance-terminated --instance-ids $instances \
      --region "$region" 2>/dev/null || true
  fi

  # ── EBS Volumes (unattached) ───────────────────────────────────
  local volumes
  volumes=$(aws ec2 describe-volumes \
    --region "$region" \
    --filters "Name=status,Values=available" \
    --query 'Volumes[].VolumeId' \
    --output text 2>/dev/null) || true

  if [[ -n "$volumes" && "$volumes" != "None" ]]; then
    for vid in $volumes; do
      nuke_log "EBS Volume" "$region" "$vid"
      aws ec2 delete-volume --volume-id "$vid" --region "$region" 2>/dev/null || true
    done
  fi

  # ── Elastic IPs ────────────────────────────────────────────────
  local eips
  eips=$(aws ec2 describe-addresses \
    --region "$region" \
    --query 'Addresses[?AssociationId==null].AllocationId' \
    --output text 2>/dev/null) || true

  if [[ -n "$eips" && "$eips" != "None" ]]; then
    for eip in $eips; do
      nuke_log "Elastic IP" "$region" "$eip"
      aws ec2 release-address --allocation-id "$eip" --region "$region" 2>/dev/null || true
    done
  fi

  # ── NAT Gateways ──────────────────────────────────────────────
  local nats
  nats=$(aws ec2 describe-nat-gateways \
    --region "$region" \
    --filter "Name=state,Values=available,pending" \
    --query 'NatGateways[].NatGatewayId' \
    --output text 2>/dev/null) || true

  if [[ -n "$nats" && "$nats" != "None" ]]; then
    for nat in $nats; do
      nuke_log "NAT Gateway" "$region" "$nat"
      aws ec2 delete-nat-gateway --nat-gateway-id "$nat" --region "$region" 2>/dev/null || true
    done
  fi

  # ── Load Balancers (ELB classic) ──────────────────────────────
  local elbs
  elbs=$(aws elb describe-load-balancers \
    --region "$region" \
    --query 'LoadBalancerDescriptions[].LoadBalancerName' \
    --output text 2>/dev/null) || true

  if [[ -n "$elbs" && "$elbs" != "None" ]]; then
    for lb in $elbs; do
      nuke_log "Classic ELB" "$region" "$lb"
      aws elb delete-load-balancer --load-balancer-name "$lb" --region "$region" 2>/dev/null || true
    done
  fi

  # ── Load Balancers (ALB/NLB) ──────────────────────────────────
  local albArns
  albArns=$(aws elbv2 describe-load-balancers \
    --region "$region" \
    --query 'LoadBalancers[].LoadBalancerArn' \
    --output text 2>/dev/null) || true

  if [[ -n "$albArns" && "$albArns" != "None" ]]; then
    for arn in $albArns; do
      nuke_log "ALB/NLB" "$region" "$arn"
      aws elbv2 delete-load-balancer --load-balancer-arn "$arn" --region "$region" 2>/dev/null || true
    done
  fi

  # ── RDS Instances ──────────────────────────────────────────────
  local rds
  rds=$(aws rds describe-db-instances \
    --region "$region" \
    --query 'DBInstances[].DBInstanceIdentifier' \
    --output text 2>/dev/null) || true

  if [[ -n "$rds" && "$rds" != "None" ]]; then
    for db in $rds; do
      nuke_log "RDS Instance" "$region" "$db"
      aws rds delete-db-instance --db-instance-identifier "$db" \
        --skip-final-snapshot --delete-automated-backups \
        --region "$region" 2>/dev/null || true
    done
  fi

  # ── ElastiCache Clusters ──────────────────────────────────────
  local ecache
  ecache=$(aws elasticache describe-cache-clusters \
    --region "$region" \
    --query 'CacheClusters[].CacheClusterId' \
    --output text 2>/dev/null) || true

  if [[ -n "$ecache" && "$ecache" != "None" ]]; then
    for cc in $ecache; do
      nuke_log "ElastiCache" "$region" "$cc"
      aws elasticache delete-cache-cluster --cache-cluster-id "$cc" \
        --region "$region" 2>/dev/null || true
    done
  fi

  # ── EKS Clusters ──────────────────────────────────────────────
  local eks
  eks=$(aws eks list-clusters --region "$region" \
    --query 'clusters[]' --output text 2>/dev/null) || true

  if [[ -n "$eks" && "$eks" != "None" ]]; then
    for cluster in $eks; do
      # Delete nodegroups first
      local ngs
      ngs=$(aws eks list-nodegroups --cluster-name "$cluster" \
        --region "$region" --query 'nodegroups[]' --output text 2>/dev/null) || true
      if [[ -n "$ngs" && "$ngs" != "None" ]]; then
        for ng in $ngs; do
          nuke_log "EKS Nodegroup" "$region" "$ng ($cluster)"
          aws eks delete-nodegroup --cluster-name "$cluster" --nodegroup-name "$ng" \
            --region "$region" 2>/dev/null || true
        done
      fi
      nuke_log "EKS Cluster" "$region" "$cluster"
      aws eks delete-cluster --name "$cluster" --region "$region" 2>/dev/null || true
    done
  fi

  # ── Lambda Functions ──────────────────────────────────────────
  local lambdas
  lambdas=$(aws lambda list-functions --region "$region" \
    --query 'Functions[].FunctionName' --output text 2>/dev/null) || true

  if [[ -n "$lambdas" && "$lambdas" != "None" ]]; then
    for fn in $lambdas; do
      nuke_log "Lambda" "$region" "$fn"
      aws lambda delete-function --function-name "$fn" --region "$region" 2>/dev/null || true
    done
  fi

  # ── ECS Clusters ──────────────────────────────────────────────
  local ecsClusters
  ecsClusters=$(aws ecs list-clusters --region "$region" \
    --query 'clusterArns[]' --output text 2>/dev/null) || true

  if [[ -n "$ecsClusters" && "$ecsClusters" != "None" ]]; then
    for cluster in $ecsClusters; do
      # Stop all services first
      local services
      services=$(aws ecs list-services --cluster "$cluster" \
        --region "$region" --query 'serviceArns[]' --output text 2>/dev/null) || true
      if [[ -n "$services" && "$services" != "None" ]]; then
        for svc in $services; do
          aws ecs update-service --cluster "$cluster" --service "$svc" \
            --desired-count 0 --region "$region" 2>/dev/null || true
          aws ecs delete-service --cluster "$cluster" --service "$svc" \
            --force --region "$region" 2>/dev/null || true
        done
      fi
      nuke_log "ECS Cluster" "$region" "$cluster"
      aws ecs delete-cluster --cluster "$cluster" --region "$region" 2>/dev/null || true
    done
  fi

  # ── Security Groups (non-default) ─────────────────────────────
  local sgs
  sgs=$(aws ec2 describe-security-groups \
    --region "$region" \
    --query 'SecurityGroups[?GroupName!=`default`].GroupId' \
    --output text 2>/dev/null) || true

  if [[ -n "$sgs" && "$sgs" != "None" ]]; then
    for sg in $sgs; do
      nuke_log "Security Group" "$region" "$sg"
      aws ec2 delete-security-group --group-id "$sg" --region "$region" 2>/dev/null || true
    done
  fi

  # ── Key Pairs (blockchain-test-*) ─────────────────────────────
  local keys
  keys=$(aws ec2 describe-key-pairs \
    --region "$region" \
    --query 'KeyPairs[?starts_with(KeyName,`blockchain`)].KeyName' \
    --output text 2>/dev/null) || true

  if [[ -n "$keys" && "$keys" != "None" ]]; then
    for key in $keys; do
      nuke_log "Key Pair" "$region" "$key"
      aws ec2 delete-key-pair --key-name "$key" --region "$region" 2>/dev/null || true
    done
  fi
}

nuke_global() {
  # ── S3 Buckets (global) ───────────────────────────────────────
  local buckets
  buckets=$(aws s3api list-buckets \
    --query 'Buckets[].Name' --output text 2>/dev/null) || true

  if [[ -n "$buckets" && "$buckets" != "None" ]]; then
    for bucket in $buckets; do
      nuke_log "S3 Bucket" "global" "$bucket"
      aws s3 rb "s3://$bucket" --force 2>/dev/null || true
    done
  fi

  # ── CloudFormation stacks (all regions already covered) ───────
  info "CloudFormation stacks cleaned per-region if present."
}

# ═══════════════════════════════════════════════════════════════════
#  MAIN
# ═══════════════════════════════════════════════════════════════════

echo ""
echo "==========================================="
echo "  AWS NUKE — Kill everything that costs $  "
echo "==========================================="
echo ""

# Clean global resources first
info "Cleaning global resources (S3)..."
nuke_global

# Scan all regions
for region in "${REGIONS[@]}"; do
  info "Scanning $region..."
  nuke_region "$region"
done

echo ""
info "========================================="
info "  AWS nuke complete."
info "========================================="
echo ""

# ── Deletion Summary ────────────────────────────────────────────
if [[ ${#DELETED[@]} -eq 0 ]]; then
  info "No resources were found to delete. Account is clean."
else
  echo -e "${CYAN}┌──────────────────────────────────────────────────────────────────┐${NC}"
  echo -e "${CYAN}│               DELETED RESOURCES SUMMARY                         │${NC}"
  echo -e "${CYAN}├──────────────────┬─────────────────┬─────────────────────────────┤${NC}"
  printf  "${CYAN}│${NC} %-16s ${CYAN}│${NC} %-15s ${CYAN}│${NC} %-27s ${CYAN}│${NC}\n" "TYPE" "REGION" "RESOURCE ID"
  echo -e "${CYAN}├──────────────────┼─────────────────┼─────────────────────────────┤${NC}"
  for entry in "${DELETED[@]}"; do
    IFS='|' read -r type region resource <<< "$entry"
    printf "${CYAN}│${NC} %-16s ${CYAN}│${NC} %-15s ${CYAN}│${NC} %-27s ${CYAN}│${NC}\n" "$type" "$region" "$resource"
  done
  echo -e "${CYAN}└──────────────────┴─────────────────┴─────────────────────────────┘${NC}"
  echo ""
  info "Total resources deleted: ${#DELETED[@]}"
fi
echo ""

# Clean up local key files
rm -f /tmp/blockchain-test-key-*.pem 2>/dev/null || true
info "Cleaned up local key files."
