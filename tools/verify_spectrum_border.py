#!/usr/bin/env python3
"""Public RGB isolation regression, real ROMs, both native and scaled timings.

The legacy reference removes ONLY the new border block, optional ports and final
mux from the production source; existing renderer paths are otherwise identical.
No forced internal signals, alternate raster, or test-only source design is used.
"""
from pathlib import Path
import argparse
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--mode', type=int, choices=(1, 3), action='append')
    ap.add_argument('--distinct-only', action='store_true', help='one full frame with eight distinct visible band heights')
    ap.add_argument('--out', type=Path, default=ROOT / 'sim/sd/out/spectrum_border')
    args = ap.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    iv = ROOT / 'tools/iverilog/bin/iverilog.exe'
    vvp = ROOT / 'tools/iverilog/bin/vvp.exe'
    source = (ROOT / 'rtl/video/rpg_video.v').read_text(encoding='utf-8')
    if 'function [15:0] spectrum_tile_rgb;' in source:
        # The former exact bar-height/color oracle describes the historical style.
        # Preserve that runner for old sources; current tiled style has its own
        # public RGB isolation, brightness, grid and frame-snapshot checks.
        command = [sys.executable, '-B', str(ROOT / 'tools/verify_neon_frame.py'), '--out', str(args.out)]
        for mode in args.mode or ():
            command += ['--mode', str(mode)]
        if args.distinct_only:
            command += ['--preview-only']
        print('Current tiled neon frame: forwarding to verify_neon_frame.py', flush=True)
        return subprocess.call(command, cwd=ROOT)
    legacy = source[:source.index('\nendmodule') + len('\nendmodule')]
    start = legacy.index('    // Real-spectrum replacement is restricted')
    end = legacy.index('    //---------------------------------------------------------\n    // 诊断色条', start)
    legacy = legacy[:start] + legacy[end:]
    legacy = legacy.replace('module rpg_video #(', 'module rpg_video_legacy #(', 1)
    legacy = legacy.replace('    output wire [23:0] rgb_full,\n    // Optional real-spectrum outer frame. Open/X enable retains legacy pixels.\n    input wire spectrum_border_en,\n    input wire [63:0] spectrum_levels // eight unsigned bytes, clamped to 0..120', '    output wire [23:0] rgb_full', 1)
    legacy = legacy.replace(': spectrum_pix;', ': pix;').replace('expand565(spectrum_pix)', 'expand565(pix)')
    if 'spectrum_' in legacy:
        raise RuntimeError('Reference extraction left spectrum logic behind')
    baseline = args.out / 'rpg_video_legacy.v'
    baseline.write_text(legacy, encoding='utf-8')
    sources = [ROOT/'sim/sd/tb_spectrum_border.v', ROOT/'rtl/video/rpg_video.v', baseline,
               ROOT/'rtl/video/vid_timing.v', ROOT/'rtl/video/mon_layer.v',
               ROOT/'rtl/gen/ui_rom.v', ROOT/'rtl/gen/anim_rom.v', ROOT/'rtl/gen/mon_rom.v']
    for mode in args.mode or (1, 3):
        suffix = '_distinct' if args.distinct_only else ''
        exe = args.out / f'border_mode{mode}{suffix}.vvp'
        subprocess.run([str(iv), '-g2001', '-Wall', f'-DBORDER_MODE={mode}', '-s',
                        'tb_spectrum_border', '-o', str(exe), *map(str, sources)], cwd=ROOT, check=True)
        started = time.monotonic()
        result = subprocess.run([str(vvp), str(exe), *(['+distinct_only'] if args.distinct_only else [])], cwd=ROOT, text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=1200)
        (args.out / f'border_mode{mode}{suffix}.log').write_text(result.stdout, encoding='utf-8')
        print(result.stdout, end='', flush=True)
        print(f'MODE {mode}: {time.monotonic()-started:.1f}s', flush=True)
        if result.returncode or 'PASS spectrum_border' not in result.stdout:
            return result.returncode or 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
