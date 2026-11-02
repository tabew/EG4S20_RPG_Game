"""Verify only mon_layer using an independent forward-transform RGB565 oracle.

Default: all 25 monsters x 8 transforms x fade {8,4,0}, full 144x144
pixels and a one-pixel border, X/Z defaults, reset, and ROM byte bounds.
No main renderer, other layers, SD/SDRAM, or hardware is involved.
Compile the actual production module as Verilog-2001.

--demonstrate-regressions additionally reproduces the original three-clock
contract failure from the user's pre-transform backup, and independently
reintroduces ONLY its missing palette-drain cycle into a temporary module.
The second demonstration must report exactly 153 wrong pixels: the actual
monster 21's 17 palette-15 source pixels, each displayed nine times.
"""
from pathlib import Path
import argparse
import hashlib
import json
import re
import shutil
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
BENCH = ROOT / 'sim/monster/tb_mon_sprite_rgb.v'
MODULE = ROOT / 'rtl/video/mon_layer.v'
ROM = ROOT / 'rtl/gen/mon_rom.v'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--quick', action='store_true', help='one untransformed full raster only')
    parser.add_argument('--demonstrate-regressions', action='store_true')
    parser.add_argument('--legacy-source', type=Path, default=ROOT / 'build/pre_monster_transform_source/rtl/video/mon_layer.v')
    parser.add_argument('--timeout', type=int, default=1200)
    parser.add_argument('--out', type=Path, default=ROOT / 'sim/monster/out')
    args = parser.parse_args()
    local = ROOT / 'tools/iverilog/bin'
    compiler = str(local / 'iverilog.exe') if (local / 'iverilog.exe').exists() else shutil.which('iverilog')
    runtime = str(local / 'vvp.exe') if (local / 'vvp.exe').exists() else shutil.which('vvp')
    if not compiler or not runtime:
        raise SystemExit('Icarus Verilog and vvp required in tools/iverilog/bin or PATH')
    args.out.mkdir(parents=True, exist_ok=True)
    report = {'oracle': 'forward source rotation then display mirror; integer division by 3; independent ROM arrays',
              'language': 'Verilog-2001 (-g2001 -Wall)', 'latency': 'sample at P1, public RGB/valid at P3, same as renderer de3',
              'sha256': {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
                         for p in (MODULE, ROM, ROOT / 'rtl/gen/mon.hex', ROOT / 'rtl/gen/monpal.hex', BENCH)},
              'runs': []}
    with tempfile.TemporaryDirectory(prefix='monster_sprite_') as temporary:
        temp = Path(temporary)

        def run(name, source, defines=(), plusargs=(), expected_errors=0):
            binary = temp / (name + '.vvp')
            command = [compiler, '-g2001', '-Wall', *defines, '-s', 'tb_mon_sprite_rgb', '-o', str(binary),
                       str(source), str(ROM), str(BENCH)]
            subprocess.run(command, cwd=ROOT, check=True)
            started = time.monotonic()
            # Preserve exact simulator output and machine-readable final counts.
            completed = subprocess.run([runtime, str(binary), *plusargs], cwd=ROOT,
                                       text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                       timeout=args.timeout, check=True)
            text = completed.stdout
            print(text, end='', flush=True)
            (args.out / (name + '.log')).write_text(text, encoding='utf-8')
            match = re.search(r'^COUNTS (.+)$', text, re.M)
            if not match:
                raise RuntimeError(f'{name}: no final counts')
            counts = {k: int(v) for k, v in re.findall(r'(\w+)=(\d+)', match.group(1))}
            if counts['errors'] != expected_errors:
                raise RuntimeError(f'{name}: expected {expected_errors} errors, got {counts["errors"]}')
            report['runs'].append({'name': name, 'counts': counts, 'seconds': round(time.monotonic()-started, 3)})

        if args.demonstrate_regressions:
            if not args.legacy_source.is_file():
                raise SystemExit('Original source required by --demonstrate-regressions; pass --legacy-source')
            run('original_pipeline_failure', args.legacy_source, ('-DLEGACY',), ('+baseline',), 666)
            text = MODULE.read_text(encoding='utf-8')
            old = "if (pcnt == 5'd16) begin"
            if text.count(old) != 1:
                raise RuntimeError('Cannot isolate palette drain regression')
            broken = temp / 'mon_palette_without_drain.v'
            broken.write_text(text.replace(old, "if (pcnt == 5'd15) begin"), encoding='utf-8')
            run('isolated_palette15_failure', broken, plusargs=('+baseline', '+palette_only'), expected_errors=153)
            run('palette15_fixed', MODULE, plusargs=('+latency_only', '+palette_only'))
        run('quick' if args.quick else 'exhaustive', MODULE, plusargs=('+latency_only',) if args.quick else ())
    destination = args.out / 'report.json'
    destination.write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    print(f'PASS report: {destination}')


if __name__ == '__main__':
    main()
