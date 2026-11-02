"""Verify original music/effects and the real top's PSG-to-HDMI PCM transport."""
from pathlib import Path
import argparse,hashlib,json,subprocess,sys
ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'sim/sd/out/hdmi_music_system'

def tool(name):
 p=ROOT/'tools/iverilog/bin'/f'{name}.exe'
 return str(p)if p.exists()else name

def main():
 ap=argparse.ArgumentParser(description=__doc__);ap.add_argument('--case',choices=['effects','top'],action='append');args=ap.parse_args()
 OUT.mkdir(parents=True,exist_ok=True);results=[]
 for case in args.case or ['effects','top']:
  top={'effects':'tb_music_effects','top':'tb_hdmi_music_top'}[case]
  sources=[ROOT/'sim/sd'/f'{top}.v',ROOT/'rtl/common/key_debounce.v'];flags=[]
  if case=='top':
   flags=['-i','-DSIM_BEHAV','-I',str(ROOT/'rtl/gen'),'-I',str(ROOT/'rtl/ctrl')]
   sources +=[ROOT/p for p in ['rtl/rpg_top.v','rtl/clk_gen.v','rtl/common/reset_sync.v','rtl/ctrl/rpg_core.v','rtl/gen/rpg_msgs.v','rtl/gen/ui_rom.v','rtl/gen/anim_rom.v','rtl/gen/mon_rom.v','rtl/video/rpg_video.v','rtl/video/vid_timing.v','rtl/video/mon_layer.v','rtl/video/hdmi_tx.v']]
  binary=OUT/f'{case}.vvp'
  with(OUT/f'{case}.log').open('w',encoding='utf-8')as log:
   compile_result=subprocess.run([tool('iverilog'),'-g2001','-Wall',*flags,'-s',top,'-o',str(binary),*map(str,sources)],cwd=ROOT,stdout=log,stderr=subprocess.STDOUT)
   rc=compile_result.returncode
   if not rc:rc=subprocess.run([tool('vvp'),str(binary)],cwd=ROOT,stdout=log,stderr=subprocess.STDOUT,timeout=480).returncode
  text=(OUT/f'{case}.log').read_text(encoding='utf-8');passed=rc==0 and f'PASS {top[3:]}'in text
  results.append({'case':case,'passed':passed,'returncode':rc,'log':str(OUT/f'{case}.log')})
  print(('PASS 'if passed else'FAIL ')+case,flush=True);print('\n'.join(text.splitlines()[-12:]),flush=True)
 report={'all_passed':all(x['passed']for x in results),'results':results,'limitations':'effects accelerates BPM only; top accelerates key debounce/mode lock, no internal DUT state forced; packet values passively compared; actual board sound not verified','production_source_sha256':{p:hashlib.sha256((ROOT/p).read_bytes()).hexdigest()for p in ['rtl/common/key_debounce.v','rtl/rpg_top.v','rtl/video/hdmi_tx.v']}}
 (OUT/('results_'+('_'.join(args.case)if args.case else'all')+'.json')).write_text(json.dumps(report,indent=2),encoding='utf-8')
 return 0 if report['all_passed']else 1
if __name__=='__main__':raise SystemExit(main())
