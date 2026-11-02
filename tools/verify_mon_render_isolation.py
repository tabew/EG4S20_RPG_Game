"""Compare public CEA pixels of identity versus transformed monster layers."""
from pathlib import Path
import subprocess,json
ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'sim/sd/out/mon_transform';OUT.mkdir(parents=True,exist_ok=True)
def main():
 sources=['rtl/video/rpg_video.v','rtl/video/vid_timing.v','rtl/video/mon_layer.v','rtl/gen/mon_rom.v','rtl/gen/anim_rom.v','rtl/gen/ui_rom.v','sim/sd/tb_mon_render_isolation.v']
 exe=OUT/'render_isolation.vvp'
 with (OUT/'render_isolation.log').open('w',encoding='utf-8')as log:
  comp=subprocess.run([str(ROOT/'tools/iverilog/bin/iverilog.exe'),'-g2001','-Wall','-s','tb_mon_render_isolation','-o',str(exe),*[str(ROOT/s)for s in sources]],cwd=ROOT,stdout=log,stderr=subprocess.STDOUT)
  rc=comp.returncode
  if not rc:rc=subprocess.run([str(ROOT/'tools/iverilog/bin/vvp.exe'),str(exe)],cwd=ROOT,stdout=log,stderr=subprocess.STDOUT,timeout=900).returncode
 text=(OUT/'render_isolation.log').read_text(encoding='utf-8',errors='replace')
 passed=rc==0 and'PASS mon_render_isolation'in text
 (OUT/'render_isolation.json').write_text(json.dumps({'passed':passed,'returncode':rc,'verilog':'2001','public_pixel_and_sync_only':True,'pixel_clock_profile':'CEA640x480p60','frames':8,'pixels_per_frame':307200,'checks':'outside144x144 equality, independent font oracle inside window, all8 rotation/mirror combinations','dut_internal_writes':False},indent=2),encoding='utf-8')
 print(text,end='');return 0 if passed else 1
if __name__=='__main__':raise SystemExit(main())
