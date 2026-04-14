#!/bin/bash
# run-multi-test.sh
# Run blockchain performance tests for multiple node counts with automatic retry.
# Reads AWS credentials from run-on-aws.txt (same format used for manual runs).
# Usage: ./run-multi-test.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER="$SCRIPT_DIR/run-on-aws.sh"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log() { echo -e "[$(date '+%H:%M:%S')] $*"; }

# ── parse credentials from run-on-aws.txt ────────────────────────────────────
TXT="$SCRIPT_DIR/run-on-aws.txt"
if [[ ! -f "$TXT" ]]; then
    log "${RED}run-on-aws.txt not found — cannot read credentials${NC}"
    exit 1
fi
AWS_KEY=$(grep -o -- '--aws-access-key [^ ]*' "$TXT" | awk '{print $2}' | head -1)
AWS_SECRET=$(grep -o -- '--aws-secret-key [^ \\]*' "$TXT" | awk '{print $2}' | head -1)
if [[ -z "$AWS_KEY" || -z "$AWS_SECRET" ]]; then
    log "${RED}Could not parse --aws-access-key / --aws-secret-key from run-on-aws.txt${NC}"
    exit 1
fi

NODE_COUNTS=(16 32 64 128 256 512)
MAX_RETRIES=3

OVERALL_PASS=0
OVERALL_FAIL=0

for NODES in "${NODE_COUNTS[@]}"; do
    attempt=1
    success=false
    while [[ $attempt -le $MAX_RETRIES ]]; do
        log "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        log "${BLUE}Nodes=$NODES  attempt $attempt/$MAX_RETRIES${NC}"
        log "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

        bash "$RUNNER" \
            --aws-access-key "$AWS_KEY" \
            --aws-secret-key "$AWS_SECRET" \
            --nodes "$NODES"
        exit_code=$?

        if [[ $exit_code -eq 0 ]]; then
            log "${GREEN}✓ Nodes=$NODES passed (attempt $attempt)${NC}"
            success=true
            OVERALL_PASS=$((OVERALL_PASS + 1))
            break
        else
            log "${YELLOW}⚠ Nodes=$NODES failed (exit $exit_code, attempt $attempt/$MAX_RETRIES)${NC}"
            if [[ $attempt -lt $MAX_RETRIES ]]; then
                log "Waiting 30s before retry..."
                sleep 30
            fi
        fi
        attempt=$((attempt + 1))
    done

    if [[ "$success" != "true" ]]; then
        log "${RED}✗ Nodes=$NODES failed after $MAX_RETRIES attempts — moving on${NC}"
        OVERALL_FAIL=$((OVERALL_FAIL + 1))
    fi
done

log "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
log "All done — ${GREEN}${OVERALL_PASS} passed${NC}, ${RED}${OVERALL_FAIL} failed${NC}"
