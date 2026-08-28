#!/bin/bash
#
# collect-ablation-results.sh
#
# After run-ablation-study.sh completes, this script:
#   1. Finds the most recent A, B, C output dirs
#   2. Aggregates metrics from *-stats.csv files (median across runs)
#   3. Updates the \abl... macros in thesis_paper.tex
#
# Usage:
#   ./collect-ablation-results.sh
#   ./collect-ablation-results.sh --a-dir <path> --b-dir <path> --c-dir <path>

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PAPER="/Users/mohamedlabib/www/blockchain/thesis/thesis paper/thesis_paper.tex"

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
log() { echo -e "[$(date '+%H:%M:%S')] $*"; }

# ── parse args ────────────────────────────────────────────────────────────────
A_DIR=""; B_DIR=""; C_DIR=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --a-dir) A_DIR="$2"; shift 2 ;;
        --b-dir) B_DIR="$2"; shift 2 ;;
        --c-dir) C_DIR="$2"; shift 2 ;;
        *) echo "Unknown arg: $1" >&2; exit 1 ;;
    esac
done

# Auto-detect most recent dirs if not specified
[[ -z "$A_DIR" ]] && A_DIR=$(ls -d "$SCRIPT_DIR"/journal-ablation-A-full-enh-* 2>/dev/null | sort | tail -1)
[[ -z "$B_DIR" ]] && B_DIR=$(ls -d "$SCRIPT_DIR"/journal-ablation-B-no-pipeline-* 2>/dev/null | sort | tail -1)
[[ -z "$C_DIR" ]] && C_DIR=$(ls -d "$SCRIPT_DIR"/journal-ablation-C-no-shardmerge-* 2>/dev/null | sort | tail -1)

[[ -n "$A_DIR" && -d "$A_DIR" ]] || { echo -e "${RED}No A (full ENH) dir found.${NC}" >&2; exit 1; }
[[ -n "$B_DIR" && -d "$B_DIR"  ]] || { echo -e "${RED}No B (no-pipeline) dir found.${NC}" >&2; exit 1; }
[[ -n "$C_DIR" && -d "$C_DIR"  ]] || { echo -e "${RED}No C (no-shardmerge) dir found.${NC}" >&2; exit 1; }

log "A dir (full ENH):    $A_DIR"
log "B dir (no pipeline): $B_DIR"
log "C dir (no shard mrg): $C_DIR"

# ── helpers ───────────────────────────────────────────────────────────────────
get_median() {
    local dir="$1"
    local metric="$2"
    python3 - "$dir" "$metric" <<'PYEOF'
import sys, csv, statistics, pathlib
base = pathlib.Path(sys.argv[1])
metric = sys.argv[2]
values = []
for csv_path in sorted(base.rglob("*-stats.csv")):
    try:
        with open(csv_path) as f:
            for row in csv.DictReader(f, fieldnames=["Metric","Value"]):
                if row["Metric"].strip() == metric:
                    try: values.append(float(row["Value"].strip()))
                    except ValueError: pass
    except Exception: pass
if not values: print("N/A")
elif len(values) == 1: print(f"{values[0]:.2f}")
else: print(f"{statistics.median(values):.2f}")
PYEOF
}

get_median_int() {
    local dir="$1"
    local metric="$2"
    python3 - "$dir" "$metric" <<'PYEOF'
import sys, csv, statistics, pathlib
base = pathlib.Path(sys.argv[1])
metric = sys.argv[2]
values = []
for csv_path in sorted(base.rglob("*-stats.csv")):
    try:
        with open(csv_path) as f:
            for row in csv.DictReader(f, fieldnames=["Metric","Value"]):
                if row["Metric"].strip() == metric:
                    try: values.append(float(row["Value"].strip()))
                    except ValueError: pass
    except Exception: pass
if not values: print("N/A")
else: print(f"{int(round(statistics.median(values)))}")
PYEOF
}

# ── collect metrics ───────────────────────────────────────────────────────────
log "Collecting ENH (full) metrics..."
ENH_TX=$(get_median     "$A_DIR" "Blockchain TX Rate (tx/s)")
ENH_EFF=$(get_median    "$A_DIR" "Effective TX Rate (tx/s)")
ENH_DRAIN=$(get_median  "$A_DIR" "Drain Rate (%)")
ENH_BLOCKS=$(get_median_int "$A_DIR" "Total Blocks Created")
ENH_TXPB=$(get_median   "$A_DIR" "Avg Transactions per Block")
ENH_ROUND=$(get_median  "$A_DIR" "Median Round Time (ms)")
ENH_RESP=$(get_median_int "$A_DIR" "Average Response Time (ms)")
ENH_SUCCESS=$(get_median "$A_DIR" "Success Rate (%)")
log "  TX/s=$ENH_TX  Eff=$ENH_EFF  Drain=$ENH_DRAIN%  Blocks=$ENH_BLOCKS  Round=${ENH_ROUND}ms  Resp=${ENH_RESP}ms  Success=$ENH_SUCCESS%"

log "Collecting ENH-NP (no pipeline) metrics..."
NP_TX=$(get_median     "$B_DIR" "Blockchain TX Rate (tx/s)")
NP_EFF=$(get_median    "$B_DIR" "Effective TX Rate (tx/s)")
NP_DRAIN=$(get_median  "$B_DIR" "Drain Rate (%)")
NP_BLOCKS=$(get_median_int "$B_DIR" "Total Blocks Created")
NP_TXPB=$(get_median   "$B_DIR" "Avg Transactions per Block")
NP_ROUND=$(get_median  "$B_DIR" "Median Round Time (ms)")
NP_RESP=$(get_median_int "$B_DIR" "Average Response Time (ms)")
NP_SUCCESS=$(get_median "$B_DIR" "Success Rate (%)")
log "  TX/s=$NP_TX  Eff=$NP_EFF  Drain=$NP_DRAIN%  Blocks=$NP_BLOCKS  Round=${NP_ROUND}ms  Resp=${NP_RESP}ms  Success=$NP_SUCCESS%"

log "Collecting ENH-NM (no shard merge) metrics..."
NM_TX=$(get_median     "$C_DIR" "Blockchain TX Rate (tx/s)")
NM_EFF=$(get_median    "$C_DIR" "Effective TX Rate (tx/s)")
NM_DRAIN=$(get_median  "$C_DIR" "Drain Rate (%)")
NM_BLOCKS=$(get_median_int "$C_DIR" "Total Blocks Created")
NM_TXPB=$(get_median   "$C_DIR" "Avg Transactions per Block")
NM_ROUND=$(get_median  "$C_DIR" "Median Round Time (ms)")
NM_RESP=$(get_median_int "$C_DIR" "Average Response Time (ms)")
NM_SUCCESS=$(get_median "$C_DIR" "Success Rate (%)")
log "  TX/s=$NM_TX  Eff=$NM_EFF  Drain=$NM_DRAIN%  Blocks=$NM_BLOCKS  Round=${NM_ROUND}ms  Resp=${NM_RESP}ms  Success=$NM_SUCCESS%"

# ── patch thesis_paper.tex ────────────────────────────────────────────────────
TS=$(date +%Y%m%d_%H%M%S)
BACKUP="${PAPER}.pre-ablation-${TS}.bak"
cp "$PAPER" "$BACKUP"
log "Backup: $BACKUP"

patch_macro() {
    local name="$1"
    local value="$2"
    sed -i '' "s|\\\\newcommand{\\\\${name}}{[^}]*}|\\\\newcommand{\\\\${name}}{${value}}|g" "$PAPER"
}

log "Patching thesis_paper.tex..."

# ENH (full) row — replaces the vertical-study NPS=4 placeholder
patch_macro "ablEnhTx"         "$ENH_TX"
patch_macro "ablEnhEff"        "$ENH_EFF"
patch_macro "ablEnhDrain"      "$ENH_DRAIN"
patch_macro "ablEnhBlocks"     "$ENH_BLOCKS"
patch_macro "ablEnhTxPerBlock" "$ENH_TXPB"
patch_macro "ablEnhRound"      "$ENH_ROUND"
patch_macro "ablEnhResp"       "$ENH_RESP"
patch_macro "ablEnhSuccess"    "$ENH_SUCCESS"

# ENH-NP row
patch_macro "ablNpTx"         "$NP_TX"
patch_macro "ablNpEff"        "$NP_EFF"
patch_macro "ablNpDrain"      "$NP_DRAIN"
patch_macro "ablNpBlocks"     "$NP_BLOCKS"
patch_macro "ablNpTxPerBlock" "$NP_TXPB"
patch_macro "ablNpRound"      "$NP_ROUND"
patch_macro "ablNpResp"       "$NP_RESP"
patch_macro "ablNpSuccess"    "$NP_SUCCESS"
patch_macro "ablNpTxN"        "$NP_TX"
patch_macro "ablNpDrainN"     "$NP_DRAIN"

# ENH-NM row
patch_macro "ablNmTx"         "$NM_TX"
patch_macro "ablNmEff"        "$NM_EFF"
patch_macro "ablNmDrain"      "$NM_DRAIN"
patch_macro "ablNmBlocks"     "$NM_BLOCKS"
patch_macro "ablNmTxPerBlock" "$NM_TXPB"
patch_macro "ablNmRound"      "$NM_ROUND"
patch_macro "ablNmResp"       "$NM_RESP"
patch_macro "ablNmSuccess"    "$NM_SUCCESS"
patch_macro "ablNmTxN"        "$NM_TX"
patch_macro "ablNmDrainN"     "$NM_DRAIN"

log "${GREEN}✓ thesis_paper.tex updated${NC}"
log ""
log "Recompile to regenerate PDF:"
log "  cd 'thesis/thesis paper' && pdflatex thesis_paper.tex"
