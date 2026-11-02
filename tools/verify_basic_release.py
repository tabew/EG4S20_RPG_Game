#!/usr/bin/env python3
"""Verify native TD resource/timing/source evidence for the complete basic build."""
import argparse
import hashlib
import json
from pathlib import Path
import re
ROOT=Path(__file__).resolve().parents[1]

def main():
 ap=argparse.ArgumentParser(description=__doc__)
 ap.add_argument('--build',type=Path,default=ROOT/'sim/sd/out/td_media_sdram_audio_final')
 ap.add_argument('--require-bit',action='store_true')
 ap.add_argument('--cea',action='store_true',help='require25.2/126MHz standard640x480 profile')
 ap.add_argument('--zoom',action='store_true',help='require the extra held zoom-mode CDC payload bound')
 ap.add_argument('--firmware-stem',default='eg4s20_basic')
 ap.add_argument('--outputs',type=Path,help='actual nativeGUI project output directory')
 ap.add_argument('--report-prefix',default='base')
 args=ap.parse_args();build=args.build.resolve();outputs=args.outputs.resolve() if args.outputs else build
 manifest=json.loads((build/'source_sha256.json').read_text(encoding='utf-8'))
 checked=[]
 for rel,digest in manifest.items():
  live=ROOT/rel
  if not live.exists():live=Path('D:/jingsai')/rel
  assert live.is_file() and hashlib.sha256(live.read_bytes()).hexdigest()==digest, f'Changed source: {rel}'
  assert hashlib.sha256((build/'source_snapshot'/rel).read_bytes()).hexdigest()==digest,rel
  checked.append(rel)
 assert (outputs/(args.report_prefix+'_pr.db')).is_file(),'No routed database'
 text=(outputs/(args.report_prefix+'_phy.timing')).read_text(encoding='utf-8')
 groups=[]
 for block in re.split(r'Timing constraint:\s*',text)[1:]:
  heading=block.splitlines()[0].strip()
  match=re.search(r'(\d+) endpoints analyzed totally, and (?:more than )?(\d+) paths analyzed',block)
  if not match:continue
  err=re.search(r'(\d+) errors detected\s*:\s*(\d+) setup errors.*?(\d+) hold errors',block)
  assert err and int(err[1])==0,heading
  g=dict(group=heading,endpoints=int(match[1]),paths=int(match[2]),errors=0)
  period=re.search(r'Minimum period is ([\d.]+)ns',block)
  if period:g['minimum_period_ns']=float(period[1])
  nominal=re.search(r'Clock = \S+, period ([\d.]+)ns',block)
  if nominal:g['constraint_period_ns']=float(nominal[1])
  delay=re.search(r'Path delay: ([\d.]+)ns max, and ([\d.]+)ns min',block)
  if delay:
   g['max_delay_ns']=float(delay[1]);g['min_delay_ns']=float(delay[2]);g['slowest_path_ns']=float(re.search(r'Slowest path delay ([\d.]+)ns',block)[1])
  if 'u_framebuffer/mode_payload_p' in block:g['payload']='framebuffer_zoom_mode'
  groups.append(g)
 targets=[('clk50',20),('clk_pix',39.682540 if args.cea else 25),('clk_p5x',7.936508 if args.cea else 5)]
 for clock,target in targets:
  g=next(x for x in groups if x['group']=='clock: '+clock)
  assert g['endpoints']>0 and g['minimum_period_ns']<=target,g
  assert abs(g['constraint_period_ns']-target)<0.002,(clock,g)
 delays=[g for g in groups if 'max_delay_ns'in g]
 expected=[20,20,30,30,30] if args.zoom else [20,20,30,30]
 assert len(delays)==len(expected) and sorted(g['max_delay_ns']for g in delays)==expected,delays
 if args.zoom:
  zoom=next(g for g in delays if g.get('payload')=='framebuffer_zoom_mode')
  assert zoom['endpoints']==2 and zoom['max_delay_ns']==30,zoom
 assert all(g['endpoints']>0 for g in delays)
 assert sorted(g['endpoints']for g in delays if g['max_delay_ns']==20)==[12,12],delays
 area=(outputs/(args.report_prefix+'_phy.area')).read_text(encoding='utf-8');resources={}
 for field in ('lut','reg','bram','bram32k','dsp','pll'):
  m=re.search(r'#'+field+r'\s+(\d+)\s+out of\s+(\d+)',area);assert m,field
  used,total=map(int,m.groups());assert used<=total;resources[field]=dict(used=used,available=total)
 result=dict(all_source_inputs_match=True,source_input_count=len(checked),timing_checks=groups,resources=resources,
  analysis_scope='Three internal logic clocks, two handshake payload bounds and two FIFO Gray bounds checked. Reference and forwarded SDRAM clock have no register endpoints. SDRAM external-die IO is verified by manufacturer timing and storage-model simulations, not independent external IO-delay STA; board validation still required.',
  board_verified=False,flash_programmed=False)
 if args.cea:
  assert resources['pll']['used']==2,resources['pll']
 result['video_profile']='CEA640x480p60_VIC1_25200000' if args.cea else 'VESA800x600_40000000'
 result['full_rgb888_zoom_modes']=[1,2,4] if args.zoom else []
 if args.zoom:result['analysis_scope']+=' Extra two-bit zoom payload bound is checked at30ns/max0ns/min; bank and view apply on frame epochs.'
 bit=outputs/(args.firmware_stem+'.bit');raw=outputs/(args.firmware_stem+'.bin')
 result['native_output_directory']=str(outputs)
 if args.require_bit:
  assert bit.is_file() and 100000<bit.stat().st_size<2*1024*1024
  result['bitstream']=dict(file=bit.name,bytes=bit.stat().st_size,sha256=hashlib.sha256(bit.read_bytes()).hexdigest())
  if raw.exists():result['flash_binary']=dict(file=raw.name,bytes=raw.stat().st_size,sha256=hashlib.sha256(raw.read_bytes()).hexdigest())
 out=build/('basic_validation.json'if args.require_bit else'basic_validation_before_bit.json')
 out.write_text(json.dumps(result,indent=2),encoding='utf-8')
 print(json.dumps(result,indent=2));return 0
if __name__=='__main__':raise SystemExit(main())
