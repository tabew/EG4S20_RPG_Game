#!/usr/bin/env python3
"""Verify buffered controller cancellation, acknowledged CDC commands, and FAT/BMP draining."""
import argparse
import json
import subprocess
from verify_sd_rtl import ROOT, SIM, find_tool, execute
from verify_sd_catalog import make_case

OUT = SIM / 'out' / 'media_cancel'
CASES = ('media_cancel_ctrl', 'media_cancel_cdc', 'media_cancel_loader')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--case', action='append', choices=CASES)
    args = parser.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    iv, vvp = find_tool('iverilog'), find_tool('vvp')
    results = []
    for name in args.case or CASES:
        exe = OUT / (name + '.vvp')
        # All production modules and the new benches compile as Verilog 2001.
        rc, log = execute([iv, '-g2001', '-Wall', '-s', 'tb_' + name, '-o', exe,
                           SIM / ('tb_' + name + '.v'), ROOT / 'rtl/common/key_debounce.v'])
        if not rc:
            cmd = [vvp, exe]
            if name == 'media_cancel_loader':
                entries = sorted(make_case()['disk'].items())
                lp, dp = OUT / 'lba.hex', OUT / 'data.hex'
                lp.write_text(''.join(f'{lba:08x}\n' for lba, _ in entries))
                dp.write_text(''.join(bytes(data).hex('\n') + '\n' for _, data in entries))
                cmd += [f'+NSECTORS={len(entries)}', f'+LBA={lp.as_posix()}', f'+DATA={dp.as_posix()}']
            try:
                rc, output = execute(cmd, timeout=120)
                log += output
            except subprocess.TimeoutExpired:
                rc = 1
                log += 'Host simulation timeout\n'
        (OUT / (name + '.log')).write_text(log, encoding='utf-8')
        passed = rc == 0 and 'PASS ' + name in log
        results.append(dict(case=name, passed=passed, returncode=rc))
        print(('PASS ' if passed else 'FAIL ') + name + '\n' + log, flush=True)
    (OUT / 'results.json').write_text(json.dumps(results, indent=2))
    return 0 if all(result['passed'] for result in results) else 1


if __name__ == '__main__':
    raise SystemExit(main())
