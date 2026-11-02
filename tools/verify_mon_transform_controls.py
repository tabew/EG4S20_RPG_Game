"""Verify public monster transform controller and real physical key debounce."""
from pathlib import Path
import subprocess,json
ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'sim/sd/out/mon_transform';OUT.mkdir(parents=True,exist_ok=True)
def main():
 exe=OUT/'controls.vvp'
 cmd=[str(ROOT/'tools/iverilog/bin/iverilog.exe'),'-g2001','-Wall','-s','tb_mon_transform_ctrl','-o',str(exe),str(ROOT/'rtl/common/key_debounce.v'),str(ROOT/'rtl/rpg_top.v'),str(ROOT/'sim/sd/tb_mon_transform_ctrl.v')]
 comp=subprocess.run(cmd,cwd=ROOT,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,encoding='utf-8',errors='replace')
 text=comp.stdout;rc=comp.returncode
 if not rc:
  run=subprocess.run([str(ROOT/'tools/iverilog/bin/vvp.exe'),str(exe)],cwd=ROOT,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,encoding='utf-8',errors='replace',timeout=30)
  text+=run.stdout;rc=run.returncode
 (OUT/'controls.log').write_text(text,encoding='utf-8')
 passed=rc==0 and'PASS mon_transform_ctrl'in text
 (OUT/'controls.json').write_text(json.dumps({'passed':passed,'returncode':rc,'verilog':'2001','raw_key_mapping':'logical K1..K4 = key_n[3]..key_n[0]','dut_internal_writes':False},indent=2),encoding='utf-8')
 print(text,end='');return 0 if passed else 1
if __name__=='__main__':raise SystemExit(main())
