"""Run passive real-rpg_top PSG -> HDMI/FFT integration with physical K3 controls."""
from pathlib import Path
import argparse
import hashlib
import json
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'sim/sd/out/audio_spectrum_top'
SOURCES = ['rtl/common/key_debounce.v', 'rtl/rpg_top.v', 'rtl/clk_gen.v',
           'rtl/common/reset_sync.v', 'rtl/ctrl/rpg_core.v', 'rtl/gen/rpg_msgs.v',
           'rtl/gen/ui_rom.v', 'rtl/gen/anim_rom.v', 'rtl/gen/mon_rom.v',
           'rtl/video/rpg_video.v', 'rtl/video/vid_timing.v',
           'rtl/video/mon_layer.v', 'rtl/video/hdmi_tx.v']


def tool(name):
    candidate = ROOT / 'tools/iverilog/bin' / (name + '.exe')
    return str(candidate) if candidate.exists() else name


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bench', action='store_true', help='Stop after first fully silent block to estimate full-run cost')
    parser.add_argument('--timeout', type=int, default=3600)
    parser.add_argument('--label', choices=['bench', 'full', 'adopted_bench'], help='Preserve reports from distinct compiled RTL revisions')
    args = parser.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    label = args.label or ('bench' if args.bench else 'full')
    log_path = OUT / (label + '.log')
    binary = OUT / (label + '.vvp')
    hashes = {p: hashlib.sha256((ROOT / p).read_bytes()).hexdigest() for p in SOURCES}
    command = [tool('iverilog'), '-g2001', '-Wall', '-i', '-DSIM_BEHAV',
               '-I', str(ROOT / 'rtl/gen'), '-I', str(ROOT / 'rtl/ctrl'),
               '-s', 'tb_audio_spectrum_top', '-o', str(binary),
               str(ROOT / 'sim/sd/tb_audio_spectrum_top.v'),
               *[str(ROOT / p) for p in SOURCES]]
    started = time.monotonic()
    timed_out = False
    with log_path.open('w', encoding='utf-8') as log:
        rc = subprocess.run(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT).returncode
        if not rc:
            try:
                rc = subprocess.run([tool('vvp'), str(binary), *(['+BENCH'] if args.bench else [])],
                                    cwd=ROOT, stdout=log, stderr=subprocess.STDOUT,
                                    timeout=args.timeout).returncode
            except subprocess.TimeoutExpired:
                rc = 1
                timed_out = True
                log.write('\nHost simulation timeout\n')
    elapsed = time.monotonic() - started
    text = log_path.read_text(encoding='utf-8')
    marker = 'PASS audio_spectrum_top_bench' if args.bench else 'PASS audio_spectrum_top real_'
    stats = next((json.loads(line[6:]) for line in text.splitlines() if line.startswith('STATS ')), {})
    changed = [p for p in SOURCES if hashlib.sha256((ROOT / p).read_bytes()).hexdigest() != hashes[p]]
    report = {
        'passed': rc == 0 and marker in text, 'returncode': rc, 'bench': args.bench,
        'elapsed_seconds': round(elapsed, 3), 'timed_out': timed_out,
        'log': str(log_path), 'statistics': stats,
        'clock': {'sim_behav_passes_reference': True, 'input_named_clk50_actual_period_ns': 39.682,
                  'actual_pixel_hz': 1e9 / 39.682, 'nominal_pixel_hz': 25200000,
                  'sample_interval_pixel_cycles': 525, 'fft_block_sample_count': 256,
                  'fft_publication_interval_pixel_cycles': 134400},
        'method': 'Unmodified production rpg_top; public reset/raw key_n[1] drive only; passive hierarchical capture checks each real encoder tick; only u_k2 CLK_KHZ=20 DEB_MS=1 HOLD_MS=8 accelerated; sd_miso=1/no card; reference classifies zero blocks from actual PCM; exact decay checked per band and observation-derived bound; no force or hierarchical writes.',
        'scope': 'PSG -> HDMI FIFO and FFT capture/mute/decay/resume; production HDMI packet/video logic runs; border rendering and board physical output are outside this test.',
        'production_source_sha256': hashes, 'sources_changed_during_run': changed,
    }
    (OUT / (label + '.json')).write_text(json.dumps(report, indent=2), encoding='utf-8')
    print(('PASS' if report['passed'] else 'FAIL') + ' audio_spectrum_top ' + label, flush=True)
    print('\n'.join(text.splitlines()[-16:]), flush=True)
    print('elapsed_seconds=' + str(report['elapsed_seconds']), flush=True)
    return 0 if report['passed'] else 1


if __name__ == '__main__':
    sys.exit(main())
