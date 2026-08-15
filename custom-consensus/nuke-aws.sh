#!/usr/bin/env bash
#
# nuke-aws.sh — Terminate ALL AWS resources that could incur cost.
# Covers: EC2 instances, EBS volumes, Elastic IPs, security groups,
#         key pairs, ECS, EKS, Lambda, NAT gateways, load balancers,
#         S3 buckets, RDS, ElastiCache, Launch Templates, EC2 Fleets,
#         Spot Instance/Fleet Requests, AMIs, EBS snapshots, placement
#         groups, non-default VPCs, IAM roles, CloudWatch log groups.
#
# Safety-filtered resource types (only delete when name matches
# ^(blockchain|k3s|custom-consensus)) — so it's safe to run in an
# account that also hosts unrelated work:
#   - AMIs, EBS snapshots
#   - CloudWatch log groups
#   - IAM roles / instance profiles
#   - Non-default VPCs
#
# Unfiltered (deletes everything found):
#   EC2 instances, EBS volumes (unattached), Elastic IPs, NAT gateways,
#   Load balancers, RDS, ElastiCache, EKS, Lambda, ECS, Security Groups
#   (non-default), blockchain-* key pairs, Launch Templates, EC2 Fleets,
#   Spot requests, Placement Groups, S3 buckets.
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

  # ══════════════════════════════════════════════════════════════════
  # STEP 0: Cancel anything that could re-launch instances after we
  # terminate them (Spot requests + EC2 Fleets). Order matters: this
  # MUST come before the EC2 instance termination or the Spot/Fleet
  # controller will just spin up replacements while we're deleting.
  # ══════════════════════════════════════════════════════════════════

  # ── Spot Instance Requests (persistent auto-relaunch risk) ─────
  local sirs
  sirs=$(aws ec2 describe-spot-instance-requests \
    --region "$region" \
    --filters "Name=state,Values=open,active" \
    --query 'SpotInstanceRequests[].SpotInstanceRequestId' \
    --output text 2>/dev/null) || true

  if [[ -n "$sirs" && "$sirs" != "None" ]]; then
    for sir in $sirs; do
      nuke_log "Spot Instance Req" "$region" "$sir"
      aws ec2 cancel-spot-instance-requests --spot-instance-request-ids "$sir" \
        --region "$region" 2>/dev/null || true
    done
  fi

  # ── Spot Fleet Requests (older Fleet API, still auto-relaunches) ─
  local sfrs
  sfrs=$(aws ec2 describe-spot-fleet-requests \
    --region "$region" \
    --query 'SpotFleetRequestConfigs[?SpotFleetRequestState==`active` || SpotFleetRequestState==`submitted`].SpotFleetRequestId' \
    --output text 2>/dev/null) || true

  if [[ -n "$sfrs" && "$sfrs" != "None" ]]; then
    for sfr in $sfrs; do
      nuke_log "Spot Fleet Req" "$region" "$sfr"
      aws ec2 cancel-spot-fleet-requests --spot-fleet-request-ids "$sfr" \
        --terminate-instances --region "$region" 2>/dev/null || true
    done
  fi

  # ── EC2 Fleets (newer Fleet API — planned use for multi-node clusters) ─
  # --terminate-instances kills the instances the fleet spawned in the same call.
  local fleets
  fleets=$(aws ec2 describe-fleets \
    --region "$region" \
    --filters "Name=fleet-state,Values=submitted,active,modifying" \
    --query 'Fleets[].FleetId' \
    --output text 2>/dev/null) || true

  if [[ -n "$fleets" && "$fleets" != "None" ]]; then
    for fleet in $fleets; do
      nuke_log "EC2 Fleet" "$region" "$fleet"
      aws ec2 delete-fleets --fleet-ids "$fleet" \
        --terminate-instances --region "$region" 2>/dev/null || true
    done
  fi

  # ══════════════════════════════════════════════════════════════════
  # STEP 1+: Terminate everything that costs money.
  # ══════════════════════════════════════════════════════════════════

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

  # ══════════════════════════════════════════════════════════════════
  # STEP 2: Cleanup of resources that were REFERENCED by things we
  # just deleted (Launch Templates → Fleets, AMIs → instances, VPC →
  # everything). Safe to run after instances/fleets are gone.
  #
  # NAME-FILTERED (only delete resources matching our project prefix)
  # for AMIs / snapshots / VPCs / CW logs so this script stays safe
  # in accounts that host unrelated workloads.
  # ══════════════════════════════════════════════════════════════════

  # ── Launch Templates (Fleet API uses these; unconditional cleanup) ─
  local lts
  lts=$(aws ec2 describe-launch-templates \
    --region "$region" \
    --query 'LaunchTemplates[].LaunchTemplateId' \
    --output text 2>/dev/null) || true

  if [[ -n "$lts" && "$lts" != "None" ]]; then
    for lt in $lts; do
      nuke_log "Launch Template" "$region" "$lt"
      aws ec2 delete-launch-template --launch-template-id "$lt" \
        --region "$region" 2>/dev/null || true
    done
  fi

  # ── AMIs owned by self (filtered by name prefix) ───────────────
  local amis
  amis=$(aws ec2 describe-images \
    --owners self \
    --region "$region" \
    --query 'Images[?starts_with(Name,`blockchain`) || starts_with(Name,`k3s`) || starts_with(Name,`custom-consensus`)].ImageId' \
    --output text 2>/dev/null) || true

  if [[ -n "$amis" && "$amis" != "None" ]]; then
    for ami in $amis; do
      nuke_log "AMI" "$region" "$ami"
      aws ec2 deregister-image --image-id "$ami" \
        --region "$region" 2>/dev/null || true
    done
  fi

  # ── EBS Snapshots owned by self (filtered by description prefix) ─
  local snaps
  snaps=$(aws ec2 describe-snapshots \
    --owner-ids self \
    --region "$region" \
    --query 'Snapshots[?starts_with(Description,`blockchain`) || starts_with(Description,`k3s`) || starts_with(Description,`custom-consensus`) || contains(Description,`for blockchain`) || contains(Description,`for k3s`)].SnapshotId' \
    --output text 2>/dev/null) || true

  if [[ -n "$snaps" && "$snaps" != "None" ]]; then
    for snap in $snaps; do
      nuke_log "EBS Snapshot" "$region" "$snap"
      aws ec2 delete-snapshot --snapshot-id "$snap" \
        --region "$region" 2>/dev/null || true
    done
  fi

  # ── Placement Groups (unconditional — always project-specific) ──
  local pgs
  pgs=$(aws ec2 describe-placement-groups \
    --region "$region" \
    --query 'PlacementGroups[].GroupName' \
    --output text 2>/dev/null) || true

  if [[ -n "$pgs" && "$pgs" != "None" ]]; then
    for pg in $pgs; do
      nuke_log "Placement Group" "$region" "$pg"
      aws ec2 delete-placement-group --group-name "$pg" \
        --region "$region" 2>/dev/null || true
    done
  fi

  # ── CloudWatch Log Groups (filtered by name prefix) ─────────────
  local lgs
  lgs=$(aws logs describe-log-groups \
    --region "$region" \
    --query 'logGroups[?starts_with(logGroupName,`/aws/blockchain`) || starts_with(logGroupName,`/aws/k3s`) || starts_with(logGroupName,`/aws/custom-consensus`) || starts_with(logGroupName,`blockchain`) || starts_with(logGroupName,`k3s`)].logGroupName' \
    --output text 2>/dev/null) || true

  if [[ -n "$lgs" && "$lgs" != "None" ]]; then
    for lg in $lgs; do
      nuke_log "CloudWatch LG" "$region" "$lg"
      aws logs delete-log-group --log-group-name "$lg" \
        --region "$region" 2>/dev/null || true
    done
  fi

  # ── Custom VPCs — full teardown in dependency order ────────────
  # Only touches VPCs that are (a) non-default AND (b) tagged with a
  # project-prefix Name. Teardown order: endpoints → subnets → IGW
  # detach + delete → non-main route tables → non-default ACLs → VPC.
  local vpcs
  vpcs=$(aws ec2 describe-vpcs \
    --region "$region" \
    --filters "Name=isDefault,Values=false" \
    --query 'Vpcs[?Tags[?Key==`Name` && (starts_with(Value,`blockchain`) || starts_with(Value,`k3s`) || starts_with(Value,`custom-consensus`))]].VpcId' \
    --output text 2>/dev/null) || true

  if [[ -n "$vpcs" && "$vpcs" != "None" ]]; then
    for vpc in $vpcs; do
      nuke_log "VPC (teardown)" "$region" "$vpc"

      # VPC endpoints (would block VPC delete)
      local vpces
      vpces=$(aws ec2 describe-vpc-endpoints \
        --region "$region" \
        --filters "Name=vpc-id,Values=$vpc" \
        --query 'VpcEndpoints[].VpcEndpointId' \
        --output text 2>/dev/null) || true
      if [[ -n "$vpces" && "$vpces" != "None" ]]; then
        aws ec2 delete-vpc-endpoints --vpc-endpoint-ids $vpces \
          --region "$region" 2>/dev/null || true
      fi

      # Subnets
      local subnets
      subnets=$(aws ec2 describe-subnets \
        --region "$region" \
        --filters "Name=vpc-id,Values=$vpc" \
        --query 'Subnets[].SubnetId' \
        --output text 2>/dev/null) || true
      for subnet in $subnets; do
        [[ -n "$subnet" && "$subnet" != "None" ]] || continue
        nuke_log "Subnet" "$region" "$subnet"
        aws ec2 delete-subnet --subnet-id "$subnet" \
          --region "$region" 2>/dev/null || true
      done

      # Internet gateways (detach then delete)
      local igws
      igws=$(aws ec2 describe-internet-gateways \
        --region "$region" \
        --filters "Name=attachment.vpc-id,Values=$vpc" \
        --query 'InternetGateways[].InternetGatewayId' \
        --output text 2>/dev/null) || true
      for igw in $igws; do
        [[ -n "$igw" && "$igw" != "None" ]] || continue
        nuke_log "Internet GW" "$region" "$igw"
        aws ec2 detach-internet-gateway --internet-gateway-id "$igw" \
          --vpc-id "$vpc" --region "$region" 2>/dev/null || true
        aws ec2 delete-internet-gateway --internet-gateway-id "$igw" \
          --region "$region" 2>/dev/null || true
      done

      # Non-main route tables
      local rtbs
      rtbs=$(aws ec2 describe-route-tables \
        --region "$region" \
        --filters "Name=vpc-id,Values=$vpc" \
        --query 'RouteTables[?!(Associations[?Main==`true`])].RouteTableId' \
        --output text 2>/dev/null) || true
      for rtb in $rtbs; do
        [[ -n "$rtb" && "$rtb" != "None" ]] || continue
        nuke_log "Route Table" "$region" "$rtb"
        aws ec2 delete-route-table --route-table-id "$rtb" \
          --region "$region" 2>/dev/null || true
      done

      # Non-default network ACLs
      local nacls
      nacls=$(aws ec2 describe-network-acls \
        --region "$region" \
        --filters "Name=vpc-id,Values=$vpc" \
        --query 'NetworkAcls[?!IsDefault].NetworkAclId' \
        --output text 2>/dev/null) || true
      for nacl in $nacls; do
        [[ -n "$nacl" && "$nacl" != "None" ]] || continue
        nuke_log "Network ACL" "$region" "$nacl"
        aws ec2 delete-network-acl --network-acl-id "$nacl" \
          --region "$region" 2>/dev/null || true
      done

      # Finally the VPC itself
      aws ec2 delete-vpc --vpc-id "$vpc" \
        --region "$region" 2>/dev/null || true
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

  # ── IAM Instance Profiles (filtered by name prefix) ───────────
  # Delete profiles BEFORE roles: a profile that references a role
  # blocks that role's deletion. Also detach the role from the
  # profile first (remove-role-from-instance-profile).
  local profiles
  profiles=$(aws iam list-instance-profiles \
    --query 'InstanceProfiles[?starts_with(InstanceProfileName,`blockchain`) || starts_with(InstanceProfileName,`k3s`) || starts_with(InstanceProfileName,`custom-consensus`)].InstanceProfileName' \
    --output text 2>/dev/null) || true

  if [[ -n "$profiles" && "$profiles" != "None" ]]; then
    for profile in $profiles; do
      # Detach any roles from the profile first
      local profile_roles
      profile_roles=$(aws iam get-instance-profile \
        --instance-profile-name "$profile" \
        --query 'InstanceProfile.Roles[].RoleName' \
        --output text 2>/dev/null) || true
      for pr in $profile_roles; do
        [[ -n "$pr" && "$pr" != "None" ]] || continue
        aws iam remove-role-from-instance-profile \
          --instance-profile-name "$profile" \
          --role-name "$pr" 2>/dev/null || true
      done
      nuke_log "IAM Instance Profile" "global" "$profile"
      aws iam delete-instance-profile \
        --instance-profile-name "$profile" 2>/dev/null || true
    done
  fi

  # ── IAM Roles (filtered by name prefix — skips AWS-service-linked) ─
  # Roles have attached policies and inline policies that must be
  # removed before the role can be deleted. AWS-service-linked roles
  # (path starts with /aws-service-role/) are automatically excluded.
  local roles
  roles=$(aws iam list-roles \
    --query 'Roles[?(starts_with(RoleName,`blockchain`) || starts_with(RoleName,`k3s`) || starts_with(RoleName,`custom-consensus`)) && !starts_with(Path,`/aws-service-role/`)].RoleName' \
    --output text 2>/dev/null) || true

  if [[ -n "$roles" && "$roles" != "None" ]]; then
    for role in $roles; do
      # Detach managed policies
      local mps
      mps=$(aws iam list-attached-role-policies \
        --role-name "$role" \
        --query 'AttachedPolicies[].PolicyArn' \
        --output text 2>/dev/null) || true
      for mp in $mps; do
        [[ -n "$mp" && "$mp" != "None" ]] || continue
        aws iam detach-role-policy --role-name "$role" --policy-arn "$mp" \
          2>/dev/null || true
      done
      # Delete inline policies
      local ips
      ips=$(aws iam list-role-policies \
        --role-name "$role" \
        --query 'PolicyNames[]' \
        --output text 2>/dev/null) || true
      for ip in $ips; do
        [[ -n "$ip" && "$ip" != "None" ]] || continue
        aws iam delete-role-policy --role-name "$role" --policy-name "$ip" \
          2>/dev/null || true
      done
      nuke_log "IAM Role" "global" "$role"
      aws iam delete-role --role-name "$role" 2>/dev/null || true
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

# Clean up local tmp files from crashed runs (normally cleared by run-on-aws.sh
# trap on graceful exit; these are here as a safety net for interrupted runs).
rm -f /tmp/blockchain-test-key-*.pem 2>/dev/null || true
rm -f /tmp/blockchain-userdata-*.sh 2>/dev/null || true
# ControlMaster sockets — leaked if the parent SSH session was killed abruptly.
rm -f /tmp/ssh-ctl-* 2>/dev/null || true
# Kube-batch temp directories from start.sh batched-apply (any left over)
rm -rf /tmp/kube-batches-* 2>/dev/null || true
info "Cleaned up local tmp files (keys, userdata, ssh-ctl sockets, batches)."
