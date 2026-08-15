#!/usr/bin/env python3
"""
compute-stats.py

Aggregates per-run measurements from journal-comparison.sh into journal-grade
descriptive statistics: mean, sample standard deviation, and 95% confidence
interval half-width (Student's t at df = n-1).

Input  : a results directory containing config-N{nodes}-f{faults}-r{run}/
         subdirectories, each holding pbft-{rapidchain,enhanced}-summary.txt
         (JMeter summary) and a resources.csv emitted by monitor-resources.sh.

Output : journal-stats.csv with one row per (system, nodes, fault_level) cell,
         columns documenting mean and dispersion of every measured metric.

Usage  : ./compute-stats.py <results_dir>

Reads only stdlib; no numpy/scipy dependency.
"""
import csv
import math
import os
import re
import sys
from pathlib import Path

# Student's t two-sided 95% critical values for small df (n=2..30)
# Falls back to 1.960 for df >= 30
T95 = {1: 12.706, 2: 4.303, 3: 3.182, 4: 2.776, 5: 2.571,
       6: 2.447, 7: 2.365, 8: 2.306, 9: 2.262, 10: 2.228,
       11: 2.201, 12: 2.179, 13: 2.160, 14: 2.145, 15: 2.131,
       20: 2.086, 25: 2.060, 29: 2.045}

def t_critical(n):
    """Two-sided 95 % t critical for sample size n (n-1 degrees of freedom)."""
    if n <= 1:
        return float('inf')
    df = n - 1
    if df in T95:
        return T95[df]
    # nearest tabulated key not greater than df
    keys = sorted(k for k in T95 if k <= df)
    if not keys:
        return 1.960
    return T95[keys[-1]] if df < 30 else 1.960

def summarise(values):
    """Return (mean, sd, ci95_halfwidth) for a list of floats.
    sd is the sample (Bessel-corrected) standard deviation."""
    n = len(values)
    if n == 0:
        return None, None, None
    mean = sum(values) / n
    if n < 2:
        return mean, 0.0, 0.0
    var = sum((v - mean) ** 2 for v in values) / (n - 1)
    sd = math.sqrt(var)
    ci = t_critical(n) * sd / math.sqrt(n)
    return mean, sd, ci

# Parsers — JMeter summary format used by run-performance-test.sh
THROUGHPUT_RE = re.compile(r'(?:Confirmed.*Throughput|Throughput \(tx/s\))[^\d]*([\d.]+)', re.I)
DRAIN_RE      = re.compile(r'Drain Rate[^\d]*([\d.]+)\s*%', re.I)
BLOCKS_RE     = re.compile(r'Blocks Created[^\d]*(\d+)', re.I)
SUCCESS_RE    = re.compile(r'Success Rate[^\d]*([\d.]+)\s*%', re.I)
RESPONSE_RE   = re.compile(r'(?:Avg|Average) Response Time[^\d]*([\d.]+)', re.I)
HTTP_RATE_RE  = re.compile(r'(?:HTTP|Request) (?:Rate|Throughput)[^\d]*([\d.]+)', re.I)

def parse_summary(path):
    """Extract metrics from a JMeter summary text file."""
    if not path.exists():
        return {}
    text = path.read_text()
    out = {}
    for key, regex in [
        ('throughput_txps',  THROUGHPUT_RE),
        ('drain_rate_pct',   DRAIN_RE),
        ('blocks_created',   BLOCKS_RE),
        ('success_rate_pct', SUCCESS_RE),
        ('response_time_ms', RESPONSE_RE),
        ('http_rate_rps',    HTTP_RATE_RE),
    ]:
        m = regex.search(text)
        if m:
            out[key] = float(m.group(1))
    return out

def parse_resources(path):
    """Reduce a per-run resource CSV to mean / peak per resource."""
    if not path.exists():
        return {}
    rows = []
    with open(path) as f:
        reader = csv.DictReader(f)
        for r in reader:
            if r.get('phase', '').startswith('#'):
                continue
            try:
                rows.append({k: float(v) for k, v in r.items() if k != 'phase'})
            except (ValueError, TypeError):
                pass
    if not rows:
        return {}
    # Steady-state window: drop first 20 % (startup) and last 20 % (drain)
    n = len(rows)
    lo, hi = int(n * 0.2), int(n * 0.8)
    window = rows[lo:hi] if hi > lo else rows

    out = {}
    keys_mean = ['cpu_total_mcores', 'cpu_p2p_mean_mcores',
                 'mem_total_mib', 'mem_p2p_mean_mib']
    keys_max = ['cpu_p2p_max_mcores', 'mem_p2p_max_mib']
    for k in keys_mean:
        vals = [r[k] for r in window if k in r]
        if vals:
            out[f'{k}_mean'] = sum(vals) / len(vals)
    for k in keys_max:
        vals = [r[k] for r in window if k in r]
        if vals:
            out[f'{k}_peak'] = max(vals)
    # Bandwidth: take first and last cumulative values, compute MiB/s
    rx_vals = [r['net_rx_bytes_cum'] for r in rows if r.get('net_rx_bytes_cum', 0) > 0]
    tx_vals = [r['net_tx_bytes_cum'] for r in rows if r.get('net_tx_bytes_cum', 0) > 0]
    if len(rx_vals) >= 2 and 'timestamp_unix' in rows[0]:
        first_ts = rows[0]['timestamp_unix']
        last_ts  = rows[-1]['timestamp_unix']
        dt = last_ts - first_ts
        if dt > 0:
            out['net_rx_mibps'] = (rx_vals[-1] - rx_vals[0]) / dt / (1024 * 1024)
            out['net_tx_mibps'] = (tx_vals[-1] - tx_vals[0]) / dt / (1024 * 1024)
    return out

CONFIG_RE = re.compile(r'config-N(\d+)-f(\d+)-r(\d+)')

def main(results_dir):
    root = Path(results_dir)
    if not root.is_dir():
        sys.exit(f'Not a directory: {results_dir}')

    # Group runs by (system, nodes, fault_level)
    cells = {}
    for cfg_dir in sorted(root.glob('config-N*-f*-r*')):
        m = CONFIG_RE.search(cfg_dir.name)
        if not m:
            continue
        nodes, faults, run = int(m.group(1)), int(m.group(2)), int(m.group(3))
        for system in ('rapidchain', 'enhanced'):
            summary_path  = cfg_dir / f'pbft-{system}-summary.txt'
            resource_path = cfg_dir / f'pbft-{system}-resources.csv'
            metrics = parse_summary(summary_path)
            metrics.update(parse_resources(resource_path))
            if not metrics:
                continue
            key = (system, nodes, faults)
            cells.setdefault(key, []).append((run, metrics))

    # Aggregate
    columns = [
        'throughput_txps', 'drain_rate_pct', 'blocks_created',
        'success_rate_pct', 'response_time_ms', 'http_rate_rps',
        'cpu_total_mcores_mean', 'cpu_p2p_mean_mcores_mean',
        'cpu_p2p_max_mcores_peak',
        'mem_total_mib_mean', 'mem_p2p_mean_mib_mean',
        'mem_p2p_max_mib_peak',
        'net_rx_mibps', 'net_tx_mibps',
    ]

    out_path = root / 'journal-stats.csv'
    with open(out_path, 'w', newline='') as f:
        w = csv.writer(f)
        header = ['system', 'nodes', 'fault_pct', 'n_runs']
        for c in columns:
            header += [f'{c}_mean', f'{c}_sd', f'{c}_ci95']
        w.writerow(header)

        for (system, nodes, faults), runs in sorted(cells.items()):
            row = [system, nodes, faults, len(runs)]
            for c in columns:
                vals = [m.get(c) for _, m in runs if m.get(c) is not None]
                mean, sd, ci = summarise(vals)
                row += [mean if mean is not None else '',
                        sd   if sd   is not None else '',
                        ci   if ci   is not None else '']
            w.writerow(row)

    print(f'Wrote {out_path}')
    print(f'  cells: {len(cells)}')
    for (system, nodes, faults), runs in sorted(cells.items()):
        print(f'    {system:11s} N={nodes:3d}  f={faults:2d}%  runs={len(runs)}')

if __name__ == '__main__':
    if len(sys.argv) != 2:
        sys.exit('Usage: compute-stats.py <results_dir>')
    main(sys.argv[1])
