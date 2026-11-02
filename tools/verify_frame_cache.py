#!/usr/bin/env python3
"""Verify the production cache broker through decoder/framebuffer public events.

No SDRAM model or hierarchical DUT access: bank acknowledgements follow observed
write_bank/swap_bank selections. Compile the extracted production module as 2001.
"""
import argparse
import json
import re
import subprocess
from verify_sd_rtl import ROOT, SIM, find_tool, execute

OUT = SIM / 'out' / 'frame_cache'
CASES = ('cold_hits', 'ack_guard', 'lru', 'cancel_before', 'cancel_partial',
         'cancel_hit', 'cancel_after_raw', 'failures', 'card_epoch', 'cancel_reset')


def production_source():
    text = (ROOT / 'rtl/rpg_top.v').read_text(encoding='utf-8')
    begin = text.index('// MEDIA_FRAME_CACHE_BEGIN')
    end = text.index('// MEDIA_FRAME_CACHE_END', begin)
    # Extract by markers directly; comments before the module are harmless.
    source = text[begin + len('// MEDIA_FRAME_CACHE_BEGIN'):end].strip() + '\n'
    stage = (SIM / 'media_frame_cache.stage.v.txt').read_text(encoding='utf-8')
    if source.strip() != stage.strip():
        raise ValueError('staged broker differs from production marker block')
    compact = re.sub(r'\s+', '', text[:begin])
    connections = (
        'media_framebufferu_framebuffer(', '.cache_mode(1\'b1)',
        '.write_bank(cache_write_bank)', '.swap_only(cache_swap_only)',
        '.swap_bank(cache_swap_bank)', '.s_front_bank(fb_front_bank)',
        '.load_go(sd_decode_go)', '.load_index(cache_decode_index)',
        '.request_go(sd_load_go)', '.request_index(sd_load_index)',
        '.front_bank(fb_front_bank)', '.decode_go(sd_decode_go)',
        '.decode_index(cache_decode_index)', '.transaction_busy(cache_transaction_busy)',
        '.s_busy(sd_image_busy||publication_pending||cache_transaction_busy)',
    )
    for connection in connections:
        if connection not in compact:
            raise ValueError('production wiring contract missing: ' + connection)
    if not re.search(r'parameter\s+integer\s+ENABLE_CACHE\s*=\s*1\b', source):
        raise ValueError('production broker must default ENABLE_CACHE=1')
    return source


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--case', action='append', choices=CASES)
    args = parser.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    try:
        source = production_source()
    except (ValueError, OSError) as exc:
        print('FAIL frame_cache source contract:', exc)
        return 1
    dut = OUT / 'media_frame_cache.v'
    dut.write_text('`timescale 1ns/1ps\n' + source, encoding='utf-8')
    exe = OUT / 'frame_cache.vvp'
    rc, compile_log = execute([find_tool('iverilog'), '-g2001', '-Wall', '-s',
                               'tb_frame_cache', '-o', exe, SIM / 'tb_frame_cache.v', dut])
    (OUT / 'compile.log').write_text(compile_log, encoding='utf-8')
    if rc:
        print(compile_log)
        return rc
    results = []
    for case in args.case or CASES:
        try:
            rc, log = execute([find_tool('vvp'), exe, '+CASE=' + case], timeout=30)
        except subprocess.TimeoutExpired:
            rc, log = 1, 'Host simulation timeout\n'
        (OUT / (case + '.log')).write_text(log, encoding='utf-8')
        passed = rc == 0 and 'PASS frame_cache ' + case in log
        results.append(dict(case=case, passed=passed, returncode=rc))
        print(('PASS ' if passed else 'FAIL ') + case + '\n' + log, flush=True)
    (OUT / 'results.json').write_text(json.dumps(results, indent=2), encoding='utf-8')
    return 0 if all(result['passed'] for result in results) else 1


if __name__ == '__main__':
    raise SystemExit(main())
