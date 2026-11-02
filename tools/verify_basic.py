#!/usr/bin/env python3
"""Regression entry point for the full640x480 SDRAM + HDMI48kHz basic build."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys
from verify_sd_rtl import ROOT,SIM,execute,find_tool
OUT=SIM/'out/basic_regression'

def main():
 ap=argparse.ArgumentParser(description=__doc__);ap.add_argument('--full',action='store_true');ap.add_argument('--release',action='store_true');args=ap.parse_args()
 OUT.mkdir(parents=True,exist_ok=True);jobs=[('interfaces',[sys.executable,'-B','tools/verify_sd.py']),('publication',[sys.executable,'-B','tools/verify_frame_publication.py'])]
 exe=OUT/'buffered_ctrl.vvp';rc,log=execute([find_tool('iverilog'),'-g2012','-s','tb_buffered_media','-o',exe,ROOT/'sim/sdram/tb_buffered_media.v',ROOT/'rtl/common/key_debounce.v'])
 if not rc:rc,runlog=execute([find_tool('vvp'),exe]);log+=runlog
 (OUT/'buffered_control.log').write_text(log,encoding='utf-8');results=[dict(case='buffered_control',passed=rc==0,returncode=rc)]
 print(('PASS 'if not rc else'FAIL ')+'buffered_control\n'+log,flush=True)
 if args.full:
  jobs += [(name,[sys.executable,'-B',script])for name,script in [('full_bmp','tools/verify_full_bmp.py'),('sdram','tools/verify_sdram.py'),('framebuffer','tools/verify_framebuffer.py'),('hdmi_audio','tools/verify_hdmi_audio.py'),('video','tools/verify_media_video.py')]]
 if args.release:jobs.append(('native_release',[sys.executable,'-B','tools/verify_basic_release.py','--require-bit']))
 for name,cmd in jobs:
  try:rc,log=execute(cmd,timeout=900)
  except subprocess.TimeoutExpired:rc,log=1,'Host regression timeout\n'
  (OUT/(name+'.log')).write_text(log,encoding='utf-8');results.append(dict(case=name,passed=rc==0,returncode=rc))
  print(('PASS 'if not rc else'FAIL ')+name+'\n'+'\n'.join(log.splitlines()[-10:]),flush=True)
 hashes={p:hashlib.sha256((ROOT/p).read_bytes()).hexdigest()for p in ['rtl/rpg_top.v','rtl/common/key_debounce.v','rtl/clk_gen.v','rtl/video/rpg_video.v','rtl/video/hdmi_tx.v','constraints/timing.sdc']}
 report=dict(source_sha256=hashes,results=results,all_passed=all(x['passed']for x in results),full=args.full,native_release=args.release)
 (OUT/'results.json').write_text(json.dumps(report,indent=2),encoding='utf-8')
 return 0 if report['all_passed']else 1
if __name__=='__main__':raise SystemExit(main())
