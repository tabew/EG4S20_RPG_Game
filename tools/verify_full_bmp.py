#!/usr/bin/env python3
"""Verify all307200 unquantized RGB888 pixels emitted from actual BMP decoder."""
from pathlib import Path
from verify_sd_rtl import ROOT,SIM,fixture,find_tool,execute
OUT=SIM/'out/full_bmp'
def main():
 OUT.mkdir(parents=True,exist_ok=True);exe=OUT/'full.vvp'
 rc,log=execute([find_tool('iverilog'),'-g2012','-s','tb_full_bmp','-o',exe,SIM/'../sdram/tb_full_bmp.v',ROOT/'rtl/common/key_debounce.v'])
 if rc:print(log);return rc
 cases=[fixture('bottom_up',width=640,height=480,spc=32),fixture('top_down',width=640,height=480,topdown=True,spc=64),fixture('bad_bpp',width=640,height=480,malformed='bpp'),fixture('wrong_size',width=641,height=480,spc=32)]
 okay=True
 for c in cases:
  if c['name']=='wrong_size':c['error']=3
  d=OUT/c['name'];d.mkdir(exist_ok=True);entries=sorted(c['sectors'].items())
  (d/'lba.hex').write_text(''.join(f'{a:08x}\n'for a,_ in entries));(d/'data.hex').write_text(''.join(bytes(s).hex(' ').replace(' ','\n')+'\n'for _,s in entries));(d/'expected.hex').write_text(''.join(f'{x:x}\n'for x in c['expected']))
  # Fixture includes its raw BMP for direct format-based independent oracle.
  bmp=c['bmp'] if 'bmp'in c else None
  if bmp is None:
   from verify_sd_rtl import bmp_bytes
   bmp=bmp_bytes(641 if c['name']=='wrong_size' else 640,480,c['name']=='top_down')
  width=int.from_bytes(bmp[18:22],'little');sh=int.from_bytes(bmp[22:26],'little',signed=True);stride=(width*3+3)&~3;off=int.from_bytes(bmp[10:14],'little')
  values=[]
  for y in range(480):
   sy=y if sh<0 else 479-y
   for x in range(640):
    b,g,r=bmp[off+sy*stride+x*3:off+sy*stride+x*3+3];values.append((r<<16)|(g<<8)|b)
  (d/'full.hex').write_text(''.join(f'{x:06x}\n'for x in values))
  rc,log=execute([find_tool('vvp'),exe,f'+NSECTORS={len(entries)}',f'+ERROR={c["error"]}',f'+LBA={(d/"lba.hex").as_posix()}',f'+DATA={(d/"data.hex").as_posix()}',f'+EXPECTED={(d/"expected.hex").as_posix()}',f'+FULL={(d/"full.hex").as_posix()}'],timeout=300)
  (d/'simulation.log').write_text(log,encoding='utf-8');passed=rc==0 and'PASS full_bmp'in log;okay&=passed;print(('PASS 'if passed else'FAIL ')+c['name']+'\n'+log,flush=True)
 return 0 if okay else 1
if __name__=='__main__':raise SystemExit(main())
