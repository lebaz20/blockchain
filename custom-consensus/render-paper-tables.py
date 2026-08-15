#!/usr/bin/env python3
"""
render-paper-tables.py

Reads a journal-stats.csv produced by compute-stats.py and emits LaTeX
tables (booktabs style) and pgfplots-coordinate fragments matching the
labels already in thesis_paper.tex.  The outputs go into a tables/ and
figures/ subdirectory of the supplied paper directory, and the paper is
expected to \\input them.

Usage:
    ./render-paper-tables.py <journal-stats.csv> <output_paper_dir>

Output structure:
    <output_paper_dir>/tables/
        tab-throughput.tex
        tab-drain-rate.tex
        tab-blockchain-tx.tex
        tab-success-response.tex
        tab-consolidated.tex
        tab-per-node.tex
        tab-cpu-comparison.tex
        tab-memory-comparison.tex
        tab-bandwidth-comparison.tex
        tab-test-config.tex
    <output_paper_dir>/figures/
        fig-throughput-coords.tex      (just the addplot blocks)
        fig-drain-rate-coords.tex
        ...

The paper's existing \\begin{table}...\\caption{...}\\label{...}\\input{...}
\\end{table} skeleton is preserved; only the table body changes.

Stdlib only — no numpy / pandas dependency.
"""

import csv
import math
import os
import sys
from pathlib import Path


# --------------------------------------------------------------------------- #
# CSV loader
# --------------------------------------------------------------------------- #

def load_stats(csv_path):
    """Return dict {(system, nodes, fault_pct): row_dict_with_float_values}."""
    out = {}
    with open(csv_path) as f:
        reader = csv.DictReader(f)
        for r in reader:
            key = (r['system'], int(r['nodes']), int(r['fault_pct']))
            cells = {}
            for k, v in r.items():
                if k in ('system', 'nodes', 'fault_pct'):
                    continue
                try:
                    cells[k] = float(v) if v not in ('', None) else None
                except ValueError:
                    cells[k] = None
            cells['n_runs'] = int(r.get('n_runs', 0))
            out[key] = cells
    return out


# --------------------------------------------------------------------------- #
# Formatting helpers
# --------------------------------------------------------------------------- #

def fmt_pm(mean, sd, prec=1):
    """Format `mean ± sd` for booktabs."""
    if mean is None:
        return '--'
    if sd is None or sd == 0:
        return f'{mean:.{prec}f}'
    return f'{mean:.{prec}f} $\\pm$ {sd:.{prec}f}'


def fmt_one(val, prec=1):
    if val is None:
        return '--'
    return f'{val:.{prec}f}'


def gap(a, b):
    if a in (None, 0) or b in (None, 0):
        return '--'
    return f'{b / a:.2f}$\\times$'


# --------------------------------------------------------------------------- #
# Table renderers — return the *body* of the table (the rows between
# \toprule and \bottomrule), with the surrounding LaTeX skeleton kept in the
# paper so styling can stay author-controlled.
# --------------------------------------------------------------------------- #

NODE_AXIS = []     # populated from CSV
FAULT_AXIS = []    # populated from CSV


def discover_axes(stats):
    nodes = sorted({k[1] for k in stats})
    faults = sorted({k[2] for k in stats})
    return nodes, faults


def render_throughput(stats, nodes, faults):
    out = []
    out.append('\\begin{tabular}{@{}r r r r r r@{}}')
    out.append('\\toprule')
    out.append('\\textbf{Nodes} & \\textbf{Faults \\%} & '
               '\\textbf{Enhanced (tx/s)} & \\textbf{RapidChain (tx/s)} & '
               '\\textbf{Factor} & \\textbf{n} \\\\')
    out.append('\\midrule')
    for f in faults:
        for n in nodes:
            e = stats.get(('enhanced',   n, f), {})
            r = stats.get(('rapidchain', n, f), {})
            em, es = e.get('throughput_txps_mean'), e.get('throughput_txps_sd')
            rm, rs = r.get('throughput_txps_mean'), r.get('throughput_txps_sd')
            n_runs = e.get('n_runs', 0) or r.get('n_runs', 0)
            out.append(f'{n} & {f} & {fmt_pm(em, es, 1)} & {fmt_pm(rm, rs, 1)} '
                       f'& {gap(rm, em)} & {n_runs} \\\\')
        if f != faults[-1]:
            out.append('\\addlinespace')
    out.append('\\bottomrule')
    out.append('\\end{tabular}')
    return '\n'.join(out) + '\n'


def render_drain(stats, nodes, faults):
    out = []
    out.append('\\begin{tabular}{@{}r r r r@{}}')
    out.append('\\toprule')
    out.append('\\textbf{Nodes} & \\textbf{Faults \\%} & '
               '\\textbf{Enhanced (\\%)} & \\textbf{RapidChain (\\%)} \\\\')
    out.append('\\midrule')
    for f in faults:
        for n in nodes:
            e = stats.get(('enhanced',   n, f), {})
            r = stats.get(('rapidchain', n, f), {})
            out.append(f'{n} & {f} & '
                       f'{fmt_pm(e.get("drain_rate_pct_mean"), e.get("drain_rate_pct_sd"), 1)} & '
                       f'{fmt_pm(r.get("drain_rate_pct_mean"), r.get("drain_rate_pct_sd"), 1)} \\\\')
        if f != faults[-1]:
            out.append('\\addlinespace')
    out.append('\\bottomrule')
    out.append('\\end{tabular}')
    return '\n'.join(out) + '\n'


def render_blockchain_tx(stats, nodes, faults):
    out = []
    out.append('\\begin{tabular}{@{}r r r r | r r@{}}')
    out.append('\\toprule')
    out.append('\\textbf{Nodes} & \\textbf{Faults} & '
               '\\multicolumn{2}{c|}{\\textbf{Blockchain TX Rate}} & '
               '\\multicolumn{2}{c}{\\textbf{Blocks Created}} \\\\')
    out.append(' & \\textbf{\\%} & \\textbf{Enh.} & \\textbf{RC} '
               '& \\textbf{Enh.} & \\textbf{RC} \\\\')
    out.append('\\midrule')
    for f in faults:
        for n in nodes:
            e = stats.get(('enhanced',   n, f), {})
            r = stats.get(('rapidchain', n, f), {})
            out.append(f'{n} & {f} & '
                       f'{fmt_one(e.get("throughput_txps_mean"), 1)} & '
                       f'{fmt_one(r.get("throughput_txps_mean"), 1)} & '
                       f'{fmt_one(e.get("blocks_created_mean"), 0)} & '
                       f'{fmt_one(r.get("blocks_created_mean"), 0)} \\\\')
        if f != faults[-1]:
            out.append('\\addlinespace')
    out.append('\\bottomrule')
    out.append('\\end{tabular}')
    return '\n'.join(out) + '\n'


def render_success_response(stats, nodes, faults):
    out = []
    out.append('\\begin{tabular}{@{}r r r r | r r@{}}')
    out.append('\\toprule')
    out.append('\\textbf{Nodes} & \\textbf{Faults} & '
               '\\multicolumn{2}{c|}{\\textbf{Success Rate (\\%)}} & '
               '\\multicolumn{2}{c}{\\textbf{Avg Resp.\\ Time (ms)}} \\\\')
    out.append(' & \\textbf{\\%} & \\textbf{Enh.} & \\textbf{RC} '
               '& \\textbf{Enh.} & \\textbf{RC} \\\\')
    out.append('\\midrule')
    for f in faults:
        for n in nodes:
            e = stats.get(('enhanced',   n, f), {})
            r = stats.get(('rapidchain', n, f), {})
            out.append(f'{n} & {f} & '
                       f'{fmt_one(e.get("success_rate_pct_mean"), 2)} & '
                       f'{fmt_one(r.get("success_rate_pct_mean"), 2)} & '
                       f'{fmt_one(e.get("response_time_ms_mean"), 0)} & '
                       f'{fmt_one(r.get("response_time_ms_mean"), 0)} \\\\')
        if f != faults[-1]:
            out.append('\\addlinespace')
    out.append('\\bottomrule')
    out.append('\\end{tabular}')
    return '\n'.join(out) + '\n'


def render_resource(stats, nodes, faults, metric_mean, metric_label, unit, prec=0):
    """Generic renderer for CPU/memory/bandwidth tables."""
    out = []
    out.append('\\begin{tabular}{@{}r r r r r@{}}')
    out.append('\\toprule')
    out.append(f'\\textbf{{Nodes}} & \\textbf{{Faults \\%}} & '
               f'\\textbf{{Enhanced ({unit})}} & \\textbf{{RapidChain ({unit})}} & '
               f'\\textbf{{Ratio (R/E)}} \\\\')
    out.append('\\midrule')
    for f in faults:
        for n in nodes:
            e = stats.get(('enhanced',   n, f), {})
            r = stats.get(('rapidchain', n, f), {})
            em = e.get(metric_mean)
            rm = r.get(metric_mean)
            ratio = '--'
            if em not in (None, 0) and rm not in (None, 0):
                ratio = f'{rm / em:.2f}$\\times$'
            out.append(f'{n} & {f} & '
                       f'{fmt_one(em, prec)} & {fmt_one(rm, prec)} & {ratio} \\\\')
        if f != faults[-1]:
            out.append('\\addlinespace')
    out.append('\\bottomrule')
    out.append('\\end{tabular}')
    return '\n'.join(out) + '\n'


def render_per_node(stats, nodes, faults):
    out = []
    out.append('\\begin{tabular}{@{}r r r r r@{}}')
    out.append('\\toprule')
    out.append('\\textbf{Nodes} & \\textbf{Faults \\%} & '
               '\\textbf{Enhanced (tx/s/node)} & \\textbf{RapidChain (tx/s/node)} & '
               '\\textbf{Factor} \\\\')
    out.append('\\midrule')
    for f in faults:
        for n in nodes:
            e = stats.get(('enhanced',   n, f), {})
            r = stats.get(('rapidchain', n, f), {})
            em = e.get('throughput_txps_mean')
            rm = r.get('throughput_txps_mean')
            ep = em / n if em else None
            rp = rm / n if rm else None
            fact = gap(rp, ep) if (ep and rp) else '--'
            out.append(f'{n} & {f} & {fmt_one(ep, 2)} & {fmt_one(rp, 2)} & {fact} \\\\')
        if f != faults[-1]:
            out.append('\\addlinespace')
    out.append('\\bottomrule')
    out.append('\\end{tabular}')
    return '\n'.join(out) + '\n'


def render_consolidated(stats, nodes, faults):
    """Side-by-side at representative scales — smallest, mid, largest."""
    if not nodes:
        return ''
    representatives = [nodes[0], nodes[len(nodes) // 2], nodes[-1]]
    out = []
    out.append('\\begin{tabular}{@{}r r r r r r r r r r r@{}}')
    out.append('\\toprule')
    out.append(' & & \\multicolumn{2}{c}{\\textbf{Throughput (tx/s)}} '
               '& \\multicolumn{2}{c}{\\textbf{Drain (\\%)}} '
               '& \\multicolumn{2}{c}{\\textbf{Blocks}} '
               '& \\multicolumn{2}{c}{\\textbf{Success (\\%)}} '
               '& \\textbf{Resp.\\ (ms)} \\\\')
    out.append('\\cmidrule(lr){3-4}\\cmidrule(lr){5-6}\\cmidrule(lr){7-8}\\cmidrule(lr){9-10}')
    out.append('\\textbf{Nodes} & \\textbf{f\\%} & '
               '\\textbf{Enh.} & \\textbf{RC} & '
               '\\textbf{Enh.} & \\textbf{RC} & '
               '\\textbf{Enh.} & \\textbf{RC} & '
               '\\textbf{Enh.} & \\textbf{RC} & '
               '\\textbf{Enh./RC} \\\\')
    out.append('\\midrule')
    for f in faults:
        for n in representatives:
            e = stats.get(('enhanced',   n, f), {})
            r = stats.get(('rapidchain', n, f), {})
            out.append(f'{n} & {f} & '
                       f'{fmt_one(e.get("throughput_txps_mean"), 1)} & {fmt_one(r.get("throughput_txps_mean"), 1)} & '
                       f'{fmt_one(e.get("drain_rate_pct_mean"), 1)} & {fmt_one(r.get("drain_rate_pct_mean"), 1)} & '
                       f'{fmt_one(e.get("blocks_created_mean"), 0)} & {fmt_one(r.get("blocks_created_mean"), 0)} & '
                       f'{fmt_one(e.get("success_rate_pct_mean"), 1)} & {fmt_one(r.get("success_rate_pct_mean"), 1)} & '
                       f'{fmt_one(e.get("response_time_ms_mean"), 0)}/{fmt_one(r.get("response_time_ms_mean"), 0)} \\\\')
        if f != faults[-1]:
            out.append('\\addlinespace')
    out.append('\\bottomrule')
    out.append('\\end{tabular}')
    return '\n'.join(out) + '\n'


# --------------------------------------------------------------------------- #
# pgfplots coordinate fragments — these are \input-ed inside an existing
# axis environment in the paper, so we emit only the \addplot lines.
# --------------------------------------------------------------------------- #

def render_coords(stats, nodes, faults, metric):
    """Return two \\addplot lines (enhanced, then rapidchain) per fault level."""
    lines = []
    colours = {0: ('blue', 'red'), 33: ('blue!50!cyan', 'red!50!orange')}
    for f in faults:
        eh_pts, rc_pts = [], []
        for n in nodes:
            e = stats.get(('enhanced',   n, f), {})
            r = stats.get(('rapidchain', n, f), {})
            if e.get(metric) is not None: eh_pts.append((n, e[metric]))
            if r.get(metric) is not None: rc_pts.append((n, r[metric]))
        if eh_pts:
            c_e, _ = colours.get(f, ('blue', 'red'))
            pts = ''.join(f'({n},{v:.2f})' for n, v in eh_pts)
            lines.append(f'\\addplot[color={c_e}, mark=square, thick] coordinates {{ {pts} }};')
        if rc_pts:
            _, c_r = colours.get(f, ('blue', 'red'))
            pts = ''.join(f'({n},{v:.2f})' for n, v in rc_pts)
            lines.append(f'\\addplot[color={c_r}, mark=triangle, thick] coordinates {{ {pts} }};')
    legend = '\\legend{' + ', '.join(
        item for f in faults for item in
        (f'EnhancedBFT (f={f}\\%)', f'RapidChain (f={f}\\%)')
    ) + '}'
    lines.append(legend)
    return '\n'.join(lines) + '\n'


# --------------------------------------------------------------------------- #
# Test-config table — replaces the existing one with the new matched config
# --------------------------------------------------------------------------- #

def render_test_config(stats, nodes, faults):
    out = []
    out.append('\\begin{tabular}{@{}r r r c r r@{}}')
    out.append('\\toprule')
    out.append('\\textbf{Nodes} & \\textbf{Faults \\%} & '
               '\\textbf{Throughput Cap (req/s)} & \\textbf{Duration} & '
               '\\textbf{Shard Size} & \\textbf{Runs} \\\\')
    out.append('\\midrule')
    for n in nodes:
        for f in faults:
            n_runs = stats.get(('enhanced', n, f), {}).get('n_runs', 0)
            out.append(f'{n} & {f} & 10\\,000 & 300\\,s & 100 & {n_runs} \\\\')
    out.append('\\bottomrule')
    out.append('\\end{tabular}')
    return '\n'.join(out) + '\n'


# --------------------------------------------------------------------------- #
# Main driver
# --------------------------------------------------------------------------- #

CHECKLIST_TEMPLATE = '''
================================================================
NARRATIVE EDIT CHECKLIST — apply by hand in thesis_paper.tex
================================================================
The numeric tables and figure coordinates are now regenerated.
The following prose passages still hard-code numbers and need
manual editing.  Each item references the new value to substitute.

ABSTRACT
  [ ] "33--239 confirmed transactions per second"
      → "{min_e_throughput:.0f}--{max_e_throughput:.0f} confirmed transactions per second"
  [ ] "230 tx/s at 512 nodes"
      → "{max_e_throughput_node500:.0f} tx/s at 500 nodes"
  [ ] "peaks at $\\\\approx$51 tx/s at 256 nodes and degrades to 7 tx/s"
      → "peaks at $\\\\approx${max_r_throughput:.0f} tx/s and degrades to {min_r_throughput:.0f} tx/s under fault load"
  [ ] "above 90\\% from 32 nodes onward (peak 98\\%) versus a 53\\% peak"
      → re-quote against new drain numbers

SECTION 1 (Introduction, contributions)
  [ ] "scales linearly from 32 to 256 nodes (33--239~tx/s)"
      → re-anchor to 100--500 node range
  [ ] "4.7$\\\\times$--7.0$\\\\times$ across 32--256 nodes and reach 31$\\\\times$"
      → re-quote gap factors from new tab:throughput

SECTION 5.3 (results narrative)
  [ ] Throughput paragraph at start of §5.3.1
  [ ] Drain-rate paragraph at start of §5.3.2
  [ ] Block-counts narrative in §5.3.3 ("2.5--6.2$\\\\times$ more blocks")
  [ ] Success-rate paragraph in §5.3.4
  [ ] §5.3.5 protocol-event counts ("42 distinct shard merges")
      — DROP entirely, these were k=4-specific

SECTION 5.4 (scalability)
  [ ] "doubling ratio... 4.2$\\\\times$, 2.0$\\\\times$, 2.3$\\\\times$, 1.6$\\\\times$"
      → recompute scale-to-scale ratios from new throughput sequence

SECTION 5.6 (per-mechanism attribution)
  [ ] Re-anchor scale fingerprints from "16/32/64/128/256/512" to "100/200/300/400/500"
  [ ] Update "shard-merge protocol reclaims ~41 %" — at k=100, shards rarely die
      so this contribution is now analytical, not measured

SECTION 7 (Limitations)
  [ ] §7.7 evaluation-scope paragraphs reference test setup numbers (CPU cap,
      block threshold, duration) — update to journal-grade values
  [ ] §7.6 "expected drain rate caveat" — reframe: at k=100 the merge mechanism
      is dormant, so the caveat does not bind for the empirical claim

SECTION 8 (Conclusions)
  [ ] §8.1 first paragraph "scales linearly from 32 to 256 nodes (33--239~tx/s)"
  [ ] §8.1 first paragraph "4.7$\\\\times$--7.0$\\\\times$... 31$\\\\times$"

SHARD-HEALTH TABLE (tab:shard-health)
  [ ] Was computed at k=4 — recompute at k=100 (most shards stay healthy,
      so the dead/recovered/merged columns become very small numbers)
  [ ] Caption reframes the table as illustrating the analytic merge-utility
      function rather than the empirical regime now studied

After applying all of the above, recompile:
    cd thesis/thesis\\ paper
    pdflatex thesis_paper.tex && pdflatex thesis_paper.tex
================================================================
'''


def main(csv_path, out_dir):
    stats = load_stats(csv_path)
    if not stats:
        sys.exit(f'No data in {csv_path}')

    nodes, faults = discover_axes(stats)
    print(f'Loaded {len(stats)} cells across {len(nodes)} scales and {len(faults)} fault levels.')

    tables_dir  = Path(out_dir) / 'tables'
    figures_dir = Path(out_dir) / 'figures'
    tables_dir.mkdir(parents=True, exist_ok=True)
    figures_dir.mkdir(parents=True, exist_ok=True)

    # ── Tables ──────────────────────────────────────────────────────────────
    table_emitters = {
        'tab-throughput.tex':           render_throughput,
        'tab-drain-rate.tex':           render_drain,
        'tab-blockchain-tx.tex':        render_blockchain_tx,
        'tab-success-response.tex':     render_success_response,
        'tab-consolidated.tex':         render_consolidated,
        'tab-per-node.tex':             render_per_node,
        'tab-test-config.tex':          render_test_config,
    }
    for name, fn in table_emitters.items():
        (tables_dir / name).write_text(fn(stats, nodes, faults))
        print(f'  wrote {tables_dir/name}')

    # Resource tables (CPU/mem/bandwidth)
    (tables_dir / 'tab-cpu-comparison.tex').write_text(
        render_resource(stats, nodes, faults,
                        'cpu_p2p_max_mcores_peak_mean',
                        'Per-pod CPU peak', 'millicores', prec=0))
    (tables_dir / 'tab-memory-comparison.tex').write_text(
        render_resource(stats, nodes, faults,
                        'mem_p2p_max_mib_peak_mean',
                        'Per-pod memory peak', 'MiB', prec=0))
    (tables_dir / 'tab-bandwidth-comparison.tex').write_text(
        render_resource(stats, nodes, faults,
                        'net_tx_mibps_mean',
                        'TX bandwidth', 'MiB/s', prec=2))
    print(f'  wrote {tables_dir}/tab-cpu-comparison.tex, tab-memory-comparison.tex, tab-bandwidth-comparison.tex')

    # ── pgfplots coord fragments ────────────────────────────────────────────
    coord_emitters = {
        'fig-throughput-coords.tex':       'throughput_txps_mean',
        'fig-drain-rate-coords.tex':       'drain_rate_pct_mean',
        'fig-tx-confirmed-coords.tex':     'throughput_txps_mean',  # × duration in paper
        'fig-blocks-created-coords.tex':   'blocks_created_mean',
        'fig-http-throughput-coords.tex':  'http_rate_rps_mean',
        'fig-response-time-coords.tex':    'response_time_ms_mean',
    }
    for name, metric in coord_emitters.items():
        (figures_dir / name).write_text(render_coords(stats, nodes, faults, metric))
        print(f'  wrote {figures_dir/name}')

    # ── narrative-edit checklist (printed + saved) ──────────────────────────
    # Compute the numbers the checklist needs to surface
    def pull(system, fault, metric):
        return [stats[(system, n, fault)][metric]
                for n in nodes
                if (system, n, fault) in stats and stats[(system, n, fault)].get(metric) is not None]
    eh_thru_33 = pull('enhanced', 33, 'throughput_txps_mean') or [0]
    rc_thru_33 = pull('rapidchain', 33, 'throughput_txps_mean') or [0]
    n500_thru  = stats.get(('enhanced', 500, 33), {}).get('throughput_txps_mean', 0)

    checklist = CHECKLIST_TEMPLATE.format(
        min_e_throughput     = min(eh_thru_33),
        max_e_throughput     = max(eh_thru_33),
        max_e_throughput_node500 = n500_thru or max(eh_thru_33),
        max_r_throughput     = max(rc_thru_33),
        min_r_throughput     = min(rc_thru_33),
    )
    print(checklist)
    (Path(out_dir) / 'NARRATIVE_CHECKLIST.txt').write_text(checklist)
    print(f'  wrote {out_dir}/NARRATIVE_CHECKLIST.txt')


if __name__ == '__main__':
    if len(sys.argv) != 3:
        sys.exit('Usage: render-paper-tables.py <journal-stats.csv> <output_paper_dir>')
    main(sys.argv[1], sys.argv[2])
