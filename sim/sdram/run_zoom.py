"""Full-frame zoom checks using production RTL and independent SDRAM storage.
Usage: python sim/sdram/run_zoom.py [25|5|epoch|legacy|legacy40|control] [--compile-only]
Legacy benches are copied into the output directory and get only new-port stubs.
"""
from pathlib import Path
import sys,subprocess
ROOT=Path(__file__).resolve().parents[2]
OUT=ROOT/'sim/sdram/audit/zoom_results';OUT.mkdir(exist_ok=True)
source=(ROOT/'rtl/common/key_debounce.v').read_text(encoding='utf-8')
start=source.index('// MEDIA_SDRAM_CONTROLLER_BEGIN')
end=source.index('// MEDIA_FRAMEBUFFER_END',start)
rtl=OUT/'production_zoom.v'
rtl.write_text('`timescale 1ns/1ps\n'+source[start:end],encoding='utf-8')
mode=sys.argv[1] if len(sys.argv)>1 else '25'
bench=ROOT/'sim/sdram/tb_framebuffer_zoom.v'
name='tb_framebuffer_zoom'
opts=[]
if mode=='5':opts=['-Ptb_framebuffer_zoom.PIXEL_HALF_NS=100.0']
elif mode in ('legacy','legacy40','control'):
 name={'legacy':'tb_framebuffer_cache','legacy40':'tb_framebuffer','control':'tb_framebuffer_cache_control'}[mode]
 original=(ROOT/f'sim/sdram/{name}.v').read_text(encoding='utf-8')
 stubs="wire [1:0] view_mode=2'bzz; wire [1:0] view_active;\n "
 instance='media_framebuffer dut(.*);'
 if mode=='legacy40':
  # Existing legacy scoreboard already has an integer named write_bank.
  stubs+="wire cache_mode=1'b0,swap_only=1'b0; wire [1:0] swap_bank=0; wire [1:0] s_front_bank;\n "
  instance="media_framebuffer dut(.write_bank(2'bzz),.*);"
 original=original.replace('media_framebuffer dut(.*);',stubs+instance)
 bench=OUT/f'{name}_legacy.v';bench.write_text(original,encoding='utf-8')
elif mode=='epoch':
 name='tb_framebuffer_zoom_epoch';bench=ROOT/f'sim/sdram/{name}.v'
elif mode!='25':raise SystemExit('expected 25, 5, epoch, legacy, legacy40 or control')
binary=OUT/f'zoom_{mode}.vvp'
cmd=[str(ROOT/'tools/iverilog/bin/iverilog.exe'),'-g2012','-s',name,*opts,'-o',str(binary),str(rtl),str(ROOT/'sim/sdram/audit/em638325_pipeline_model.v'),str(bench)]
subprocess.run(cmd,cwd=ROOT,check=True)
if '--compile-only' in sys.argv[2:]:
 print(f'PASS compile {mode}',flush=True)
 raise SystemExit(0)
with (OUT/f'zoom_{mode}.log').open('w',encoding='utf-8') as log:
 result=subprocess.run([str(ROOT/'tools/iverilog/bin/vvp.exe'),str(binary)],cwd=ROOT,stdout=log,stderr=subprocess.STDOUT,timeout=1800)
print((OUT/f'zoom_{mode}.log').read_text(encoding='utf-8'),end='',flush=True)
result.check_returncode()
