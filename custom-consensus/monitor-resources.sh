#!/bin/bash
# monitor-resources.sh
#
# Samples per-pod CPU, memory, and network I/O across a Kubernetes blockchain
# deployment for the duration of a JMeter test run and emits a single CSV row
# per sample.  Designed to be launched in the background by journal-comparison.sh
# and stopped via SIGTERM when the test ends.
#
# Output CSV columns:
#   timestamp_unix,phase,cpu_total_mcores,cpu_p2p_mean_mcores,cpu_p2p_max_mcores,
#   mem_total_mib,mem_p2p_mean_mib,mem_p2p_max_mib,
#   net_rx_bytes_cum,net_tx_bytes_cum
#
# CPU is read from `kubectl top pods`, reported in millicores.
# Memory is read from `kubectl top pods`, reported in MiB.
# Network I/O is read from /proc/net/dev inside each pod, summed across pods.
#
# Sampling interval defaults to 5s; override with SAMPLE_INTERVAL env var.
#
# Usage:
#   ./monitor-resources.sh <output_csv> [label]
#
# The label (optional) is recorded in the `phase` column so post-hoc analysis
# can separate startup, steady-state, and drain phases.

set -uo pipefail

OUTPUT="${1:-}"
LABEL="${2:-run}"
SAMPLE_INTERVAL="${SAMPLE_INTERVAL:-5}"

if [[ -z "$OUTPUT" ]]; then
    echo "Usage: $0 <output_csv> [label]" >&2
    exit 1
fi

# Write CSV header once
mkdir -p "$(dirname "$OUTPUT")"
echo "timestamp_unix,phase,cpu_total_mcores,cpu_p2p_mean_mcores,cpu_p2p_max_mcores,mem_total_mib,mem_p2p_mean_mib,mem_p2p_max_mib,net_rx_bytes_cum,net_tx_bytes_cum" > "$OUTPUT"

# Compute aggregated values from `kubectl top pods` output.
# Output format from kubectl top: NAME CPU(cores) MEMORY(bytes)
# CPU values look like 123m or 1.5 (cores), memory like 256Mi or 1Gi.
to_millicores() {
    local val="$1"
    if [[ "$val" == *m ]]; then
        echo "${val%m}"
    else
        # whole cores → millicores
        awk -v v="$val" 'BEGIN { printf "%d", v * 1000 }'
    fi
}

to_mib() {
    local val="$1"
    if [[ "$val" == *Mi ]]; then
        echo "${val%Mi}"
    elif [[ "$val" == *Gi ]]; then
        awk -v v="${val%Gi}" 'BEGIN { printf "%d", v * 1024 }'
    elif [[ "$val" == *Ki ]]; then
        awk -v v="${val%Ki}" 'BEGIN { printf "%d", v / 1024 }'
    else
        echo "0"
    fi
}

# Sample network I/O from /proc/net/dev across all p2p-server pods.
# Runs `kubectl exec` per pod, which is expensive — we limit to a sample of
# pods (every Nth) and scale the result up.  At 500 pods sampling every 25th
# gives 20 datapoints which is enough to characterise the network load.
sample_network() {
    local pods
    pods=$(kubectl get pods -l app=p2p-server --no-headers 2>/dev/null | awk '{print $1}')
    local pod_count
    pod_count=$(echo "$pods" | wc -l | tr -d ' ')
    [[ "$pod_count" -eq 0 ]] && { echo "0,0"; return; }

    # Sample 20 pods spread across the deployment
    local stride=$(( pod_count / 20 ))
    [[ "$stride" -lt 1 ]] && stride=1

    local rx_sum=0 tx_sum=0 sample_count=0
    local i=0
    while IFS= read -r pod; do
        if (( i % stride == 0 )); then
            # /proc/net/dev: skip first 2 header lines then sum bytes across every
            # non-loopback interface. AL2023 uses ens5 (not eth0), k3s CNI adds
            # cni0/flannel.1, hostNetwork pods see the host's real NIC — a hard-
            # coded eth0 filter picked up nothing on any of these. Summing all
            # non-lo lines matches the primary NIC regardless of its name.
            local stats
            stats=$(kubectl exec "$pod" -- cat /proc/net/dev 2>/dev/null \
                | awk 'NR>2 && $1 !~ /^lo:/ { rx += $2; tx += $10 } END { print rx+0, tx+0 }')
            if [[ -n "$stats" ]]; then
                local rx tx
                read -r rx tx <<< "$stats"
                rx_sum=$(( rx_sum + rx ))
                tx_sum=$(( tx_sum + tx ))
                sample_count=$(( sample_count + 1 ))
            fi
        fi
        i=$(( i + 1 ))
    done <<< "$pods"

    # Scale up to estimate cluster-wide total
    if [[ "$sample_count" -gt 0 ]]; then
        rx_sum=$(( rx_sum * pod_count / sample_count ))
        tx_sum=$(( tx_sum * pod_count / sample_count ))
    fi
    echo "$rx_sum,$tx_sum"
}

# Trap SIGTERM/SIGINT for clean shutdown
RUNNING=true
trap 'RUNNING=false' TERM INT

# Main sampling loop
while $RUNNING; do
    TS=$(date +%s)

    # Get CPU + memory snapshot for all p2p-server pods
    TOP_OUT=$(kubectl top pods -l app=p2p-server --no-headers 2>/dev/null || echo "")

    if [[ -z "$TOP_OUT" ]]; then
        # metrics-server may not be ready yet; emit a placeholder row and retry
        echo "$TS,$LABEL,0,0,0,0,0,0,0,0" >> "$OUTPUT"
        sleep "$SAMPLE_INTERVAL"
        continue
    fi

    # Aggregate CPU
    CPU_VALS=()
    MEM_VALS=()
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local_cpu=$(echo "$line" | awk '{print $2}')
        local_mem=$(echo "$line" | awk '{print $3}')
        CPU_VALS+=("$(to_millicores "$local_cpu")")
        MEM_VALS+=("$(to_mib "$local_mem")")
    done <<< "$TOP_OUT"

    # Compute totals, means, and maxima
    CPU_TOTAL=0; CPU_MAX=0
    for v in "${CPU_VALS[@]}"; do
        CPU_TOTAL=$(( CPU_TOTAL + v ))
        [[ "$v" -gt "$CPU_MAX" ]] && CPU_MAX="$v"
    done
    CPU_MEAN=0
    [[ "${#CPU_VALS[@]}" -gt 0 ]] && CPU_MEAN=$(( CPU_TOTAL / ${#CPU_VALS[@]} ))

    MEM_TOTAL=0; MEM_MAX=0
    for v in "${MEM_VALS[@]}"; do
        MEM_TOTAL=$(( MEM_TOTAL + v ))
        [[ "$v" -gt "$MEM_MAX" ]] && MEM_MAX="$v"
    done
    MEM_MEAN=0
    [[ "${#MEM_VALS[@]}" -gt 0 ]] && MEM_MEAN=$(( MEM_TOTAL / ${#MEM_VALS[@]} ))

    # Sample network I/O (every other sample to limit kubectl exec overhead)
    if (( TS % (SAMPLE_INTERVAL * 2) == 0 )); then
        NET=$(sample_network)
    else
        NET="0,0"
    fi

    echo "$TS,$LABEL,$CPU_TOTAL,$CPU_MEAN,$CPU_MAX,$MEM_TOTAL,$MEM_MEAN,$MEM_MAX,$NET" >> "$OUTPUT"

    sleep "$SAMPLE_INTERVAL"
done

# Final summary line for downstream parsers
echo "# monitor exited at $(date +%s)" >> "$OUTPUT"
