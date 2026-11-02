"""Validate only the isolated falling-edge candidate; never edit shared RTL."""
from pathlib import Path
import subprocess
ROOT=Path(__file__).resolve().parents[3]
AUDIT=Path(__file__).resolve().parent
IVERILOG=ROOT/'tools/iverilog/bin/iverilog.exe'
VVP=ROOT/'tools/iverilog/bin/vvp.exe'
stage=AUDIT/'media_sdram_ctrl_negedge.stage.v'
monitor=AUDIT/'staged_pin_monitor.v'
boundary=AUDIT/'tb_pipeline_boundaries.v'
original=ROOT/'sim/sdram/tb_media_sdram.v'
independent=AUDIT/'em638325_pipeline_model.v'
oldmodel=ROOT/'sim/sdram/eg_sdram_model.v'
cases=[('boundaries5.4','tb_staged_boundaries','5.4',independent,boundary),
       ('boundaries9','tb_staged_boundaries','9.0',independent,boundary),
       ('original_independent6','tb_staged_original','6',independent,original),
       ('original_oldmodel6','tb_staged_original','6',oldmodel,original),
       ('original_oldmodel9','tb_staged_original','9',oldmodel,original)]
for label,top,access,model,testbench in cases:
    print(f'CHECK {label}',flush=True)
    binary=AUDIT/f'{label}.vvp'
    assert binary.resolve().parent==AUDIT.resolve() and binary.suffix=='.vvp'
    subprocess.run([str(IVERILOG),'-g2012','-s',top,f'-P{top}.ACCESS_NS={access}',
                    '-o',str(binary),str(stage),str(model),str(testbench),str(monitor)],
                   cwd=ROOT,check=True)
    subprocess.run([str(VVP),str(binary)],cwd=ROOT,check=True,timeout=60)
    binary.unlink()
print('PASS staged falling-edge controller: independent boundary/strobe corners, original controller suites, pin setup/startup/write recovery',flush=True)
