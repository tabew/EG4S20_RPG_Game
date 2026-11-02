#!/usr/bin/env python3
"""Measure real sd_spi wire throughput and assert delayed physical-pin timing.

No source snapshots or RTL rewriting. The 25MHz candidate MUST fail timing;
this is evidence for the 12.5MHz default, not board qualification.
"""
from __future__ import annotations
import argparse
import json
from pathlib import Path
import re
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def tool(name: str) -> str:
    found = shutil.which(name)
    local = ROOT / 'tools' / 'iverilog' / 'bin' / (name + '.exe')
    if found:
        return found
    if local.exists():
        return str(local)
    raise SystemExit('Missing simulator: ' + name)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sectors', type=int, default=64,
                        help='sectors per card type per timing case (default 64; 64 KiB total)')
    parser.add_argument('--out', type=Path, default=ROOT / 'sim/sd/out/spi_timing')
    args = parser.parse_args()
    if args.sectors < 2:
        parser.error('--sectors must be at least 2')
    args.out.mkdir(parents=True, exist_ok=True)
    iv, vvp = tool('iverilog'), tool('vvp')
    # tCO=14ns, return-path board delay=4/6ns; independent outbound skew.
    cases = [
        ('baseline_6m25', 3, 4, 0, 0, False),
        ('production_12m5', 1, 4, 0, 0, False),
        ('production_clock_skew', 1, 6, 4, 0, False),
        ('production_mosi_skew', 1, 6, 0, 4, False),
        ('candidate_25m_rejected', 0, 4, 0, 0, True),
    ]
    results = []
    for name, div, miso_delay, clock_delay, mosi_delay, reject in cases:
        image = args.out / (name + '.vvp')
        command = [iv, '-g2001', '-s', 'tb_sd_spi_timing', '-o', str(image),
                   '-Ptb_sd_spi_timing.TEST_FAST_DIV=' + str(div),
                   '-Ptb_sd_spi_timing.SECTORS=' + str(args.sectors),
                   '-Ptb_sd_spi_timing.MISO_BOARD_NS=' + str(miso_delay),
                   '-Ptb_sd_spi_timing.CLOCK_BOARD_NS=' + str(clock_delay),
                   '-Ptb_sd_spi_timing.MOSI_BOARD_NS=' + str(mosi_delay),
                   str(ROOT / 'sim/sd/tb_sd_spi_timing.v'),
                   str(ROOT / 'rtl/common/key_debounce.v')]
        compiled = subprocess.run(command, cwd=ROOT, capture_output=True, text=True)
        if compiled.returncode:
            raise SystemExit(compiled.stdout + compiled.stderr)
        run = subprocess.run([vvp, str(image)], cwd=ROOT, capture_output=True, text=True, timeout=180)
        output = compiled.stdout + compiled.stderr + run.stdout + run.stderr
        (args.out / (name + '.log')).write_text(output)
        timings = [dict(div=int(d), hc=int(h), sectors=int(s), bytes=int(b), cycles=int(c), ns=int(t))
                   for d, h, s, b, c, t in re.findall(
                       r'THROUGHPUT div=(\d+) hc=(\d+) sectors=(\d+) bytes=(\d+) cycles=(\d+) ns=(\d+)', output)]
        passed = (run.returncode != 0 and bool(re.search(r'MOSI_(SETUP|HOLD)', output))) if reject else (
            run.returncode == 0 and 'PASS sd_spi_timing' in output and len(timings) == 2)
        entry = dict(case=name, passed=passed, expected_timing_rejection=reject,
                     fast_div=div, card_tco_ns=14, miso_board_ns=miso_delay,
                     clock_board_ns=clock_delay, mosi_board_ns=mosi_delay,
                     measurements=timings, log=str(args.out / (name + '.log')))
        results.append(entry)
        print(('PASS ' if passed else 'FAIL ') + name, flush=True)
        for line in output.splitlines():
            if line.startswith(('THROUGHPUT', 'TIMING', 'FATAL')):
                print('  ' + line, flush=True)
    baseline = results[0]['measurements']
    production = results[1]['measurements']
    speedups = []
    if len(baseline) == len(production) == 2:
        for old, new in zip(baseline, production):
            ratio = old['cycles'] / new['cycles']
            speedups.append(dict(hc=new['hc'], speedup=ratio,
                                 baseline_cycles=old['cycles'], production_cycles=new['cycles']))
            print('Measured SDHC=%d speedup=%.4fx' % (new['hc'], ratio), flush=True)
    passed = all(r['passed'] for r in results) and len(speedups) == 2 and all(s['speedup'] >= 1.7 for s in speedups)
    report = dict(passed=passed, sectors_per_card=args.sectors, results=results,
                  speedups=speedups, minimum_speedup=1.7,
                  scope='50MHz RTL simulation; no board signal-integrity or place-and-route qualification')
    (args.out / 'results.json').write_text(json.dumps(report, indent=2) + '\n')
    return 0 if passed else 1


if __name__ == '__main__':
    raise SystemExit(main())
