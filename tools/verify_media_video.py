#!/usr/bin/env python3
"""Run focused public RGB/address media tests and the unchanged legacy benches."""
from pathlib import Path
import argparse
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]


def tool(name, explicit):
    if explicit:
        return str(Path(explicit).resolve())
    found = shutil.which(name)
    if found:
        return found
    for base in (ROOT / 'tools/iverilog', ROOT / 'tools/iverilog/mingw64', ROOT / 'tools/oss-cad-suite'):
        for rel in (f'bin/{name}.exe', f'{name}.exe'):
            path = base / rel
            if path.is_file():
                return str(path)
    raise SystemExit(f'{name} unavailable; pass --{name} PATH')


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--iverilog')
    ap.add_argument('--vvp')
    ap.add_argument('--case', action='append', help='Run only the named bench; repeatable')
    ap.add_argument('--out', type=Path, default=ROOT / 'sim/sd/out/media_video')
    args = ap.parse_args()
    iv, vvp = tool('iverilog', args.iverilog), tool('vvp', args.vvp)
    args.out.mkdir(parents=True, exist_ok=True)
    for bench in ('media_zoom_hud', 'media_cea', 'media_rgb888', 'media_fullframe', 'media_fullbars', 'media_pipeline', 'media_video', 'media_frame', 'sd_diag', 'sd_display'):
        if args.case and bench not in args.case:
            continue
        exe = (args.out / f'{bench}.vvp').resolve()
        source = ROOT / 'sim/sd' / ('tb_media_video.v' if bench.startswith('media_') and bench != 'media_zoom_hud' else f'tb_{bench}.v')
        cmd = [iv, ('-g2001' if bench == 'media_zoom_hud' else '-g2012'), '-s', f'tb_{bench}', '-o', str(exe), str(source), str(ROOT/'rtl/video/rpg_video.v')]
        if bench in ('media_cea', 'media_frame', 'media_fullframe', 'media_fullbars'):
            cmd.append(str(ROOT/'rtl/video/vid_timing.v'))
        result = subprocess.run(cmd, cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        if result.returncode:
            print(result.stdout)
            return result.returncode
        result = subprocess.run([vvp, str(exe)], cwd=ROOT, text=True, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, timeout=180)
        (args.out / f'{bench}.log').write_text(result.stdout, encoding='utf-8')
        print(result.stdout.strip(), flush=True)
        if result.returncode or f'PASS {bench}' not in result.stdout:
            return result.returncode or 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
