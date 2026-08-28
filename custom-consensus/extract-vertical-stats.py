#!/usr/bin/env python3
"""
extract-vertical-stats.py

Parse a journal-vertical-nps16-* directory (output of run-on-aws-cluster.sh
--journal-mode) and emit all metrics needed to fill the vertical-study tables
in thesis_paper.tex:
  - tab:vertical-throughput  (blockchain tx/s, effective tx/s, drain rate)
  - tab:vertical-cpu-mem     (CPU peak/mean mCores, memory peak/mean MiB)
  - tab:vertical-network     (RX/TX GiB per 300s run)
  - tab:vertical-latency     (median/mean HTTP ms, error %)

Usage:
    ./extract-vertical-stats.py <journal-dir>

The journal-dir must contain {enhanced,rapidchain}-run{1,2,3}/ subdirectories,
each with performance-results/*-stats.csv, *.jtl, and resources.csv.
"""
import csv
import math
import os
import sys
from pathlib import Path
from statistics import mean, stdev

def t95(n):
    """Two-sided 95% t critical value."""
    T = {1:12.706,2:4.303,3:3.182,4:2.776,5:2.571,6:2.447,7:2.365}
    if n <= 1: return float('inf')
    df = n - 1
    return T.get(df, 1.96)

def ci95(vals):
    n = len(vals)
    if n < 2: return 0
    s = stdev(vals)
    return t95(n) * s / math.sqrt(n)

def parse_stats_csv(path):
    """Parse performance-results/*-stats.csv → dict."""
    out = {}
    with open(path) as f:
        for row in csv.reader(f):
            if len(row) >= 2:
                out[row[0].strip()] = row[1].strip()
    return out

def parse_jtl(path):
    """Parse *.jtl → (median_ms, mean_ms, error_pct)."""
    elapsed = []
    total = 0
    errors = 0
    with open(path) as f:
        reader = csv.DictReader(f)
        for row in reader:
            try:
                e = int(row['elapsed'])
                elapsed.append(e)
                total += 1
                if row.get('success','true').lower() == 'false':
                    errors += 1
            except (ValueError, KeyError):
                pass
    if not elapsed:
        return None, None, None
    elapsed.sort()
    n = len(elapsed)
    median = elapsed[n // 2]
    avg = sum(elapsed) / n
    err_pct = 100.0 * errors / total if total > 0 else 0
    return median, avg, err_pct

def parse_resources(path):
    """
    Parse resources.csv → (cpu_peak_mc, cpu_mean_mc, mem_peak_mib, mem_mean_mib,
                             net_rx_gib, net_tx_gib).
    Drops first and last 20% of rows as startup/drain (same as compute-stats.py).
    Network is computed as sum of positive inter-sample deltas to handle pod
    restarts and scaled-sampling artefacts that cause cumulative counters to drop.
    """
    rows = []
    with open(path) as f:
        for row in csv.DictReader(f):
            phase = row.get('phase') or ''
            if phase.startswith('#'):
                continue
            try:
                rows.append({k: float(v) for k, v in row.items() if k != 'phase'})
            except (ValueError, TypeError):
                pass
    if not rows:
        return None, None, None, None, None, None

    n = len(rows)
    lo, hi = int(n * 0.2), int(n * 0.8)
    window = rows[lo:hi] if hi > lo else rows

    cpu_peaks = [r['cpu_p2p_max_mcores'] for r in window if r.get('cpu_p2p_max_mcores', 0) > 0]
    cpu_means = [r['cpu_p2p_mean_mcores'] for r in window if r.get('cpu_p2p_mean_mcores', 0) > 0]
    mem_peaks = [r['mem_p2p_max_mib'] for r in window if r.get('mem_p2p_max_mib', 0) > 0]
    mem_means = [r['mem_p2p_mean_mib'] for r in window if r.get('mem_p2p_mean_mib', 0) > 0]

    cpu_peak = max(cpu_peaks) if cpu_peaks else None
    cpu_mean = mean(cpu_means) if cpu_means else None
    mem_peak = max(mem_peaks) if mem_peaks else None
    mem_mean = mean(mem_means) if mem_means else None

    # Network: sum positive inter-sample deltas to handle counter resets caused
    # by pod restarts or changes in the set of sampled pods (scaled sampling).
    rx_vals = [r['net_rx_bytes_cum'] for r in rows if r.get('net_rx_bytes_cum', 0) > 0]
    tx_vals = [r['net_tx_bytes_cum'] for r in rows if r.get('net_tx_bytes_cum', 0) > 0]

    def sum_positive_deltas(vals):
        if len(vals) < 2:
            return None
        total = 0
        for i in range(1, len(vals)):
            delta = vals[i] - vals[i-1]
            if delta > 0:
                total += delta
        return total if total > 0 else None

    rx_bytes = sum_positive_deltas(rx_vals)
    tx_bytes = sum_positive_deltas(tx_vals)
    net_rx_gib = rx_bytes / (1024**3) if rx_bytes is not None else None
    net_tx_gib = tx_bytes / (1024**3) if tx_bytes is not None else None

    return cpu_peak, cpu_mean, mem_peak, mem_mean, net_rx_gib, net_tx_gib

def process_system(journal_dir, system):
    """Return list of per-run metric dicts for this system."""
    runs = []
    for run_n in range(1, 10):
        run_dir = journal_dir / f'{system}-run{run_n}'
        if not run_dir.exists():
            break

        perf_dir = run_dir / 'performance-results'
        if not perf_dir.exists():
            print(f'  [{system} run{run_n}] no performance-results dir — skipping')
            continue

        # Find stats CSV
        stats_files = sorted(perf_dir.glob('*-stats.csv'))
        jtl_files   = sorted(perf_dir.glob('*.jtl'))
        res_file    = run_dir / 'resources.csv'

        if not stats_files:
            print(f'  [{system} run{run_n}] no stats CSV — skipping')
            continue

        stats = parse_stats_csv(stats_files[-1])

        try:
            blockchain_txps = float(stats.get('Blockchain TX Rate (tx/s)', 0))
            effective_txps  = float(stats.get('Effective TX Rate (tx/s)', 0))
            drain_pct       = float(stats.get('Drain Rate (%)', 0))
            avg_resp_ms     = float(stats.get('Average Response Time (ms)', 0))
            success_pct     = float(stats.get('Success Rate (%)', 0))
            total_blocks    = int(float(stats.get('Total Blocks Created', 0) or
                                        stats.get('Blocks Created', 0) or 0))
            nodes_resp      = int(float(stats.get('Nodes Responded', 0)))
            num_nodes       = int(float(stats.get('Number of Nodes Used', 0)))
            nodes_per_shard = int(float(stats.get('Nodes Per Shard', 0)))
        except (ValueError, TypeError) as e:
            print(f'  [{system} run{run_n}] parse error: {e}')
            continue

        median_ms = err_pct = None
        if jtl_files:
            med, avg_jtl, err = parse_jtl(jtl_files[-1])
            median_ms = med
            err_pct = err

        cpu_peak = cpu_mean = mem_peak = mem_mean = rx_gib = tx_gib = None
        if res_file.exists():
            cpu_peak, cpu_mean, mem_peak, mem_mean, rx_gib, tx_gib = parse_resources(res_file)

        m = {
            'run': run_n,
            'blockchain_txps': blockchain_txps,
            'effective_txps':  effective_txps,
            'drain_pct':       drain_pct,
            'avg_resp_ms':     avg_resp_ms,
            'success_pct':     success_pct,
            'median_ms':       median_ms,
            'err_pct':         err_pct,
            'total_blocks':    total_blocks,
            'nodes_responded': nodes_resp,
            'num_nodes':       num_nodes,
            'nodes_per_shard': nodes_per_shard,
            'cpu_peak_mc':     cpu_peak,
            'cpu_mean_mc':     cpu_mean,
            'mem_peak_mib':    mem_peak,
            'mem_mean_mib':    mem_mean,
            'net_rx_gib':      rx_gib,
            'net_tx_gib':      tx_gib,
        }
        runs.append(m)
        print(f'  [{system} run{run_n}] blocks={total_blocks} '
              f'blockchain={blockchain_txps:.1f} tx/s drain={drain_pct:.1f}% '
              f'nodes={nodes_resp}')
    return runs

def agg(vals):
    """Return (mean, ±ci95) string for LaTeX, or '--'."""
    good = [v for v in vals if v is not None]
    if not good:
        return '--', '--'
    m = mean(good)
    c = ci95(good) if len(good) >= 2 else 0
    return m, c

def fmt(m, c=None, prec=1):
    if m == '--':
        return '--'
    if c is None or c == 0:
        return f'{m:.{prec}f}'
    return f'{m:.{prec}f} ±{c:.{prec}f}'

def main(journal_dir_str):
    jdir = Path(journal_dir_str)
    if not jdir.is_dir():
        sys.exit(f'Not a directory: {journal_dir_str}')

    print(f'\n{"="*60}')
    print(f'  Journal run: {jdir.name}')
    print(f'{"="*60}\n')

    results = {}
    for system in ('enhanced', 'rapidchain'):
        print(f'--- {system} ---')
        results[system] = process_system(jdir, system)
        print()

    # Aggregate
    print(f'\n{"="*60}')
    print('  AGGREGATED METRICS (mean ± 95% CI across runs)')
    print(f'{"="*60}\n')

    for system in ('enhanced', 'rapidchain'):
        runs = results[system]
        label = 'ENH' if system == 'enhanced' else 'RC'
        n = len(runs)
        print(f'{label} ({n} runs):')
        if not runs:
            print('  NO DATA')
            continue

        def pull(key):
            return [r[key] for r in runs if r.get(key) is not None]

        m_bk, c_bk = agg(pull('blockchain_txps'))
        m_ef, c_ef = agg(pull('effective_txps'))
        m_dr, c_dr = agg(pull('drain_pct'))
        m_md, c_md = agg(pull('median_ms'))
        m_av, c_av = agg(pull('avg_resp_ms'))
        m_er, c_er = agg(pull('err_pct'))
        m_cp, c_cp = agg(pull('cpu_peak_mc'))
        m_cm, c_cm = agg(pull('cpu_mean_mc'))
        m_mp, c_mp = agg(pull('mem_peak_mib'))
        m_mm, c_mm = agg(pull('mem_mean_mib'))
        m_rx, c_rx = agg(pull('net_rx_gib'))
        m_tx, c_tx = agg(pull('net_tx_gib'))

        print(f'  Throughput table:')
        print(f'    Blockchain tx/s   : {fmt(m_bk, c_bk)}')
        print(f'    Effective tx/s    : {fmt(m_ef, c_ef)}')
        print(f'    Drain rate %      : {fmt(m_dr, c_dr)}')
        print(f'  CPU/mem table:')
        print(f'    CPU peak mC       : {fmt(m_cp, c_cp, 0)}')
        print(f'    CPU mean mC       : {fmt(m_cm, c_cm, 0)}')
        print(f'    Mem peak MiB      : {fmt(m_mp, c_mp, 0)}')
        print(f'    Mem mean MiB      : {fmt(m_mm, c_mm, 0)}')
        print(f'  Network table:')
        print(f'    RX GiB            : {fmt(m_rx, c_rx, 1)}')
        print(f'    TX GiB            : {fmt(m_tx, c_tx, 1)}')
        print(f'  Latency table:')
        print(f'    Median HTTP ms    : {fmt(m_md, c_md, 0)}')
        print(f'    Mean HTTP ms      : {fmt(m_av, c_av, 0)}')
        print(f'    Error %           : {fmt(m_er, c_er, 1)}')
        print()

    print('LaTeX rows to insert (copy into thesis_paper.tex):')
    print()

    # Compute ratios for the throughput paragraph
    enh_runs = results['enhanced']
    rc_runs  = results['rapidchain']

    def gmean(system, key):
        vals = [r[key] for r in results[system] if r.get(key) is not None]
        return mean(vals) if vals else None

    e_bk = gmean('enhanced', 'blockchain_txps')
    r_bk = gmean('rapidchain', 'blockchain_txps')
    e_ef = gmean('enhanced', 'effective_txps')
    r_ef = gmean('rapidchain', 'effective_txps')
    e_dr = gmean('enhanced', 'drain_pct')
    r_dr = gmean('rapidchain', 'drain_pct')
    e_cp = gmean('enhanced', 'cpu_peak_mc')
    r_cp = gmean('rapidchain', 'cpu_peak_mc')
    e_cm = gmean('enhanced', 'cpu_mean_mc')
    r_cm = gmean('rapidchain', 'cpu_mean_mc')
    e_mp = gmean('enhanced', 'mem_peak_mib')
    r_mp = gmean('rapidchain', 'mem_peak_mib')
    e_mm = gmean('enhanced', 'mem_mean_mib')
    r_mm = gmean('rapidchain', 'mem_mean_mib')
    e_rx = gmean('enhanced', 'net_rx_gib')
    r_rx = gmean('rapidchain', 'net_rx_gib')
    e_tx = gmean('enhanced', 'net_tx_gib')
    r_tx = gmean('rapidchain', 'net_tx_gib')
    e_md = gmean('enhanced', 'median_ms')
    r_md = gmean('rapidchain', 'median_ms')
    e_av = gmean('enhanced', 'avg_resp_ms')
    r_av = gmean('rapidchain', 'avg_resp_ms')
    e_er = gmean('enhanced', 'err_pct')
    r_er = gmean('rapidchain', 'err_pct')

    def r(v): return f'{v:.1f}' if v is not None else '--'
    def ri(v): return f'{v:.0f}' if v is not None else '--'
    def ratio(a, b):
        if a and b and b > 0:
            return f'{a/b:.2f}×'
        return '--'

    # Derive label from the first run that has node metadata
    all_runs = results['enhanced'] + results['rapidchain']
    num_nodes_label = next((r['num_nodes'] for r in all_runs if r.get('num_nodes')), 0)
    nps_label = next((r['nodes_per_shard'] for r in all_runs if r.get('nodes_per_shard')), 0)
    row_label = f'N={num_nodes_label}, NPS={nps_label}' if num_nodes_label and nps_label else 'N=?, NPS=?'

    print('tab:vertical-throughput row:')
    print(f'{row_label}  & \\textbf{{{r(e_bk)}}}  & {r(r_bk)}  & '
          f'\\textbf{{{r(e_ef)}}}  & {r(r_ef)}  & {r(e_dr)} & {r(r_dr)} \\\\')
    print()
    print('tab:vertical-cpu-mem row:')
    print(f'{row_label}  & {ri(e_cp)} / {ri(e_cm)}  & {ri(r_cp)} / {ri(r_cm)}  & '
          f'{ri(e_mp)} / {ri(e_mm)}  & {ri(r_mp)} / {ri(r_mm)} \\\\')
    print()
    print('tab:vertical-network row:')
    print(f'{row_label}  & {r(e_rx)}  & {r(r_rx)}  & {r(e_tx)}  & {r(r_tx)} \\\\')
    print()
    print('tab:vertical-latency row:')
    print(f'{row_label}  & {ri(e_md)}  & {ri(r_md)}  & {ri(e_av)}  & {ri(r_av)}  & '
          f'{r(e_er)}  & {r(r_er)} \\\\')
    print()
    print(f'pgfplots fig:vertical-resources NPS={nps_label} coordinate (add to each addplot):')
    print(f'  Enh CPU peak:  (NPS{nps_label},{ri(e_cp)})')
    print(f'  RC CPU peak :  (NPS{nps_label},{ri(r_cp)})')
    print(f'  Enh Mem peak:  (NPS{nps_label},{ri(e_mp)})')
    print(f'  RC Mem peak :  (NPS{nps_label},{ri(r_mp)})')
    print()
    print(f'fig:vertical-latency-throughput NPS={nps_label} coordinate (add to each addplot):')
    print(f'  ENH median:  ({nps_label},{ri(e_md)})')
    print(f'  RC median :  ({nps_label},{ri(r_md)})')
    print()
    if e_bk and r_bk and r_bk > 0:
        print(f'Throughput ratio ENH/RC: {e_bk/r_bk:.2f}×')
    if e_ef and r_ef and r_ef > 0:
        print(f'Effective ratio ENH/RC:  {e_ef/r_ef:.2f}×')
    if e_dr and r_dr:
        print(f'Drain-rate gap:         +{e_dr - r_dr:.1f}pp')
    if e_rx and r_rx and r_rx > 0:
        print(f'RX bandwidth ratio:     {e_rx/r_rx:.2f}×')

if __name__ == '__main__':
    if len(sys.argv) != 2:
        sys.exit('Usage: extract-vertical-stats.py <journal-dir>')
    main(sys.argv[1])
