#!/usr/bin/env python3
"""Verify merged message arbitration and the two fixed display edge cases.

Synthetic HP/area/kill setup is confined to simulation benches; purchases,
healing and scene transitions use the production game input and renderer.
"""
from pathlib import Path
import hashlib
import json
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'sim/sd/out/message_regression'

def main():
    OUT.mkdir(parents=True, exist_ok=True)
    iv = ROOT / 'tools/iverilog/bin/iverilog.exe'
    vvp = ROOT / 'tools/iverilog/bin/vvp.exe'
    shared = [ROOT/'rtl/ctrl/rpg_core.v', ROOT/'rtl/gen/ui_rom.v', ROOT/'rtl/gen/rpg_msgs.v']
    reports = []
    for name in ('tb_msg_arb', 'tb_message_edges', 'tb_gameplay_regression'):
        exe, log = OUT/(name+'.vvp'), OUT/(name+'.log')
        bench = ROOT/'sim/iverilog'/(name+'.v')
        command = [str(iv), '-g2001', '-Wall', '-DSIM_FAST', '-DEXPECT_FIXED',
                   '-I', str(ROOT/'rtl/ctrl'), '-I', str(ROOT/'rtl/gen'),
                   '-s', name, '-o', str(exe), *map(str, shared), str(bench)]
        started = time.monotonic()
        with log.open('w', encoding='utf-8') as out:
            result = subprocess.run(command, cwd=ROOT, stdout=out, stderr=subprocess.STDOUT)
            if result.returncode:
                print(log.read_text(encoding='utf-8'))
                return result.returncode
            result = subprocess.run([str(vvp), str(exe)], cwd=ROOT, stdout=out,
                                    stderr=subprocess.STDOUT, timeout=180)
        text = log.read_text(encoding='utf-8')
        print(text, end='')
        passed = result.returncode == 0 and 'PASS' in text and 'FAIL' not in text and 'ERROR:' not in text
        reports.append({'name':name, 'passed':passed, 'seconds':round(time.monotonic()-started,3), 'log':str(log)})
        if not passed:
            return result.returncode or 1
    checked = shared + [ROOT/'rtl/gen/cmd.hex', ROOT/'rtl/gen/font.hex', ROOT/'rtl/gen/str.hex',
                        ROOT/'rtl/ctrl/rpg_defs.vh', ROOT/'rtl/gen/rpg_defs.vh']
    report = {'passed':True, 'cases':reports,
              'scope':'isolated synthetic display/game-state setup plus real input transitions and public cell writes; not board proof',
              'sha256':{p.relative_to(ROOT).as_posix():hashlib.sha256(p.read_bytes()).hexdigest() for p in checked}}
    (OUT/'report.json').write_text(json.dumps(report, ensure_ascii=False, indent=2),encoding='utf-8')
    return 0

if __name__ == '__main__':
    raise SystemExit(main())
