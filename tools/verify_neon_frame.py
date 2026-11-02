#!/usr/bin/env python3
"""Public-renderer checks and actual RTL RGB capture for the tiled neon frame."""
from pathlib import Path
import argparse,subprocess,time,json,hashlib,re
ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'sim/sd/out/neon_frame'
def main():
 global OUT
 ap=argparse.ArgumentParser();ap.add_argument('--mode',type=int,choices=(1,3),action='append');ap.add_argument('--preview-only',action='store_true');ap.add_argument('--out',type=Path,default=OUT);a=ap.parse_args();OUT=a.out.resolve();OUT.mkdir(parents=True,exist_ok=True)
 (ROOT/'sim/sd/out/neon_frame').mkdir(parents=True,exist_ok=True)
 s=(ROOT/'rtl/video/rpg_video.v').read_text(encoding='utf-8');legacy=s[:s.index('\nendmodule')+len('\nendmodule')]
 start=legacy.index('    // Real-spectrum replacement is restricted');end=legacy.index('    //---------------------------------------------------------\n    // 诊断色条',start)
 legacy=legacy[:start]+legacy[end:];legacy=legacy.replace('module rpg_video #(','module rpg_video_legacy #(',1)
 legacy=legacy.replace('    output wire [23:0] rgb_full,\n    // Optional real-spectrum outer frame. Open/X enable retains legacy pixels.\n    input wire spectrum_border_en,\n    input wire [63:0] spectrum_levels // eight unsigned bytes, clamped to 0..120','    output wire [23:0] rgb_full',1)
 legacy=legacy.replace(': spectrum_pix;',': pix;').replace('expand565(spectrum_pix)','expand565(pix)')
 assert 'spectrum_'not in legacy,'Reference extraction left neon logic'
 base=OUT/'rpg_video_legacy.v';base.write_text(legacy,encoding='utf-8')
 sources=[ROOT/'sim/sd/tb_neon_frame.v',ROOT/'rtl/video/rpg_video.v',base,ROOT/'rtl/video/vid_timing.v',ROOT/'rtl/video/mon_layer.v',ROOT/'rtl/gen/ui_rom.v',ROOT/'rtl/gen/anim_rom.v',ROOT/'rtl/gen/mon_rom.v']
 report=[]
 for mode in a.mode or ((1,)if a.preview_only else(1,3)):
  label=f'mode{mode}'+('_preview'if a.preview_only else'');exe=OUT/(label+'.vvp');log=OUT/(label+'.log');start=time.monotonic()
  command=[str(ROOT/'tools/iverilog/bin/iverilog.exe'),'-g2001','-Wall',f'-DNEON_MODE={mode}','-s','tb_neon_frame','-o',str(exe),*map(str,sources)]
  with log.open('w',encoding='utf-8')as f:
   subprocess.run(command,cwd=ROOT,stdout=f,stderr=subprocess.STDOUT,check=True)
   result=subprocess.run([str(ROOT/'tools/iverilog/bin/vvp.exe'),str(exe),*(['+preview_only']if a.preview_only else[])],cwd=ROOT,stdout=f,stderr=subprocess.STDOUT,timeout=1000)
  text=log.read_text(encoding='utf-8');print(text,flush=True);passed=result.returncode==0 and('PASS neon_frame PREVIEW'in text if a.preview_only else'PASS neon_frame COMPLETE'in text)
  report.append({'mode':mode,'passed':passed,'elapsed_seconds':round(time.monotonic()-start,2),'renderer_sha256':hashlib.sha256((ROOT/'rtl/video/rpg_video.v').read_bytes()).hexdigest(),'renderer_normalized_text_sha256':hashlib.sha256(s.encode()).hexdigest(),'method':'Actual production renderer+font+monster ROM; public cell writes and RGB/timing outputs, disabled effect baseline; no force or internal RAM writes.'})
  numbers=re.search(r'COMPLETE MODE(\d+) pixels(\d+) interior(\d+) outer(\d+) changed(\d+) bodychecks(\d+) silenceEnergy(\d+) loudEnergy(\d+)',text)
  if numbers:report[-1]['statistics']=dict(zip(['mode','pixels','interior','outer','changed','bodychecks','silence_energy','loud_energy'],map(int,numbers.groups())))
  (OUT/(label+'.json')).write_text(json.dumps(report[-1],indent=2),encoding='utf-8')
  if not passed:return result.returncode or 1
 if a.preview_only:
  from PIL import Image,ImageDraw
  img=Image.open(ROOT/'sim/sd/out/neon_frame/frame.ppm').convert('RGB');canvas=Image.new('RGB',(img.width,img.height+32),(20,24,31));canvas.paste(img,(0,32));ImageDraw.Draw(canvas).text((8,10),'SOFTWARE RTL PREVIEW / representative RPG fixture / not board capture',fill=(235,235,235));dest=ROOT/'build/neon/frame_preview.png';dest.parent.mkdir(parents=True,exist_ok=True);canvas.save(dest);print('PREVIEW',dest,flush=True)
 return 0
if __name__=='__main__':raise SystemExit(main())
