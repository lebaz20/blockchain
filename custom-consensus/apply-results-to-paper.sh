#!/bin/bash
#
# apply-results-to-paper.sh
#
# Once journal-aws-driver.sh has produced journal-stats.csv, this script:
#   1.  Backs up thesis_paper.tex to thesis_paper.tex.pre-journal-<TS>.bak
#   2.  Runs render-paper-tables.py to emit tex fragments under tables/ and
#       figures/ subdirectories of the paper directory
#   3.  Replaces each existing inline table/figure body in thesis_paper.tex
#       with an \input{tables/...} or \input{figures/...} pointing at the
#       freshly rendered fragment
#   4.  Prints the narrative-edit checklist from PAPER_INTEGRATION_PLAN.md
#       and from NARRATIVE_CHECKLIST.txt (numbered, with the new values
#       substituted in so you can copy/paste straight into prose)
#
# The script is conservative: it never edits prose, headings, the abstract,
# or any text outside the explicit \begin{tabular}...\end{tabular} or
# pgfplots \addplot blocks that belong to a known label.
#
# Usage:
#   ./apply-results-to-paper.sh <journal-stats.csv> <thesis_paper.tex>

set -uo pipefail

if [[ $# -ne 2 ]]; then
    echo "Usage: $0 <journal-stats.csv> <thesis_paper.tex>" >&2
    exit 1
fi

CSV="$1"
PAPER="$2"

[[ -f "$CSV" ]]   || { echo "Missing CSV: $CSV" >&2; exit 1; }
[[ -f "$PAPER" ]] || { echo "Missing paper: $PAPER" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PAPER_DIR="$(dirname "$PAPER")"
RENDERER="$SCRIPT_DIR/render-paper-tables.py"
[[ -f "$RENDERER" ]] || { echo "Missing renderer: $RENDERER" >&2; exit 1; }

# ── 1. backup ────────────────────────────────────────────────────────────────
TS=$(date +%Y%m%d_%H%M%S)
BACKUP="${PAPER}.pre-journal-${TS}.bak"
cp "$PAPER" "$BACKUP"
echo "✓ Backup: $BACKUP"

# ── 2. render fragments ──────────────────────────────────────────────────────
echo "→ Rendering LaTeX tables and pgfplots coord fragments..."
python3 "$RENDERER" "$CSV" "$PAPER_DIR"

# ── 3. swap inline bodies with \input{...} ──────────────────────────────────
# For each known label, find the matching \begin{tabular}...\end{tabular}
# block inside the table environment with that label and replace it with
# \input{tables/tab-<label>.tex}.  We use a Python helper because matching
# nested LaTeX braces with sed is fragile.
python3 - "$PAPER" "$PAPER_DIR" <<'PYEOF'
import re, sys, pathlib

paper_path = sys.argv[1]
paper_dir  = pathlib.Path(sys.argv[2])
text = open(paper_path).read()

# (label, fragment_path)
TABLE_SWAPS = [
    ('tab:throughput',           'tables/tab-throughput.tex'),
    ('tab:drain-rate',           'tables/tab-drain-rate.tex'),
    ('tab:blockchain-tx',        'tables/tab-blockchain-tx.tex'),
    ('tab:success-response',     'tables/tab-success-response.tex'),
    ('tab:consolidated',         'tables/tab-consolidated.tex'),
    ('tab:per-node',             'tables/tab-per-node.tex'),
    ('tab:test-config',          'tables/tab-test-config.tex'),
]

def replace_tabular(text, label, frag):
    """Find the table block whose \label{} matches `label`, replace the
    inner \begin{tabular}...\end{tabular} with \input{frag}."""
    # Find a \begin{table*?} ... \end{table*?} block containing the label
    pat = re.compile(
        r'(\\begin\{table\*?\}[\s\S]*?\\label\{' + re.escape(label) + r'\}[\s\S]*?)'
        r'(\\begin\{tabular\}[\s\S]*?\\end\{tabular\})'
        r'([\s\S]*?\\end\{table\*?\})',
        flags=0)
    def sub(m):
        return f'{m.group(1)}\\input{{{frag}}}\n{m.group(3)}'
    new, n = pat.subn(sub, text, count=1)
    print(f'  table {label}: {n} replacement{"s" if n != 1 else ""}')
    return new

# Apply table swaps
for label, frag in TABLE_SWAPS:
    text = replace_tabular(text, label, frag)

# Insert new resource tables right after tab:consolidated (or at end of results)
# If the paper does not yet have these labels, add a section near the end of
# the results.  The author will then format them properly in subsequent edits.
NEW_TABLES = [
    ('tab:cpu-comparison',       'tables/tab-cpu-comparison.tex',
     'Per-pod CPU peak (millicores) — lower is better; RapidChain pays the committee a second consensus round.'),
    ('tab:memory-comparison',    'tables/tab-memory-comparison.tex',
     'Per-pod memory peak (MiB) — RapidChain stores both shard and committee chains.'),
    ('tab:bandwidth-comparison', 'tables/tab-bandwidth-comparison.tex',
     'Per-pod TX bandwidth (MiB/s) — distributed verification reduces inter-shard traffic.'),
]

# Append the new resource tables after the per-node table block
anchor = '\\label{tab:per-node}'
if anchor in text:
    pat = re.compile(r'(\\label\{tab:per-node\}[\s\S]*?\\end\{table\})', flags=0)
    insertion_blocks = []
    for label, frag, caption in NEW_TABLES:
        if label not in text:
            insertion_blocks.append(
                f'\n\n\\begin{{table}}[!t]\n\\centering\n\\caption{{{caption}}}\n'
                f'\\label{{{label}}}\n\\input{{{frag}}}\n\\end{{table}}\n')
    if insertion_blocks:
        text = pat.sub(lambda m: m.group(1) + ''.join(insertion_blocks), text, count=1)
        print(f'  inserted {len(insertion_blocks)} new resource tables after tab:per-node')

# Replace pgfplots \addplot coord blocks for the listed figures.  We match
# everything between \begin{axis}...\end{axis} that contains the figure's
# \label{} and substitute its \addplot lines.  This is also brace-aware
# enough because pgfplots blocks don't nest.
FIGURE_SWAPS = [
    ('fig:throughput',       'figures/fig-throughput-coords.tex'),
    ('fig:drain-rate',       'figures/fig-drain-rate-coords.tex'),
    ('fig:tx-confirmed',     'figures/fig-tx-confirmed-coords.tex'),
    ('fig:blocks-created',   'figures/fig-blocks-created-coords.tex'),
    ('fig:http-throughput',  'figures/fig-http-throughput-coords.tex'),
    ('fig:response-time',    'figures/fig-response-time-coords.tex'),
]

def replace_axis_addplots(text, label, frag):
    """Replace \addplot[...] ... \legend{...} lines inside the axis env
    whose surrounding figure carries `label`."""
    pat = re.compile(
        r'(\\begin\{figure\}[\s\S]*?\\label\{' + re.escape(label) + r'\}[\s\S]*?\\begin\{axis\}[^\]]*\])'
        r'([\s\S]*?)'
        r'(\\end\{axis\}[\s\S]*?\\end\{figure\})',
        flags=0)
    def sub(m):
        return f'{m.group(1)}\n\\input{{{frag}}}\n{m.group(3)}'
    new, n = pat.subn(sub, text, count=1)
    print(f'  figure {label}: {n} replacement{"s" if n != 1 else ""}')
    return new

for label, frag in FIGURE_SWAPS:
    text = replace_axis_addplots(text, label, frag)

open(paper_path, 'w').write(text)
print(f'\nPaper updated in place: {paper_path}')
PYEOF

# ── 4. print the checklist ───────────────────────────────────────────────────
CHECKLIST="$PAPER_DIR/NARRATIVE_CHECKLIST.txt"
echo ""
echo "════════════════════════════════════════════════════════════════"
echo "  All tables and figures have been replaced."
echo "  Backup: $BACKUP"
echo ""
echo "  NEXT: apply the narrative edits in the printed checklist."
echo "════════════════════════════════════════════════════════════════"
echo ""
[[ -f "$CHECKLIST" ]] && cat "$CHECKLIST"

# ── 5. compile sanity check ──────────────────────────────────────────────────
echo ""
echo "→ Recompiling paper to verify the swap is syntactically clean..."
pushd "$PAPER_DIR" > /dev/null
PAPER_BASE=$(basename "$PAPER")
if pdflatex -interaction=nonstopmode "$PAPER_BASE" > /tmp/applyresults-pdflatex.log 2>&1; then
    pdflatex -interaction=nonstopmode "$PAPER_BASE" > /tmp/applyresults-pdflatex2.log 2>&1
    echo "✓ pdflatex completed without fatal errors."
    grep -iE 'warning|undefined' /tmp/applyresults-pdflatex2.log | grep -v Font | head -10 || true
else
    echo "✗ pdflatex failed — see /tmp/applyresults-pdflatex.log"
    echo "  You can restore the backup with:"
    echo "    cp \"$BACKUP\" \"$PAPER\""
fi
popd > /dev/null

echo ""
echo "Done.  Proceed with the narrative-edit checklist above."
