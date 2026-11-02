"""Run the existing full-frame integration bench with the isolated controller."""
from pathlib import Path
import subprocess
ROOT=Path(__file__).resolve().parents[3]
AUDIT=Path(__file__).resolve().parent
contents=(ROOT/'rtl/common/key_debounce.v').read_text(encoding='utf-8')
context=AUDIT/'media_framebuffer_context.stage.v'
start=contents.index('// MEDIA_FRAMEBUFFER_BEGIN')
end=contents.index('// MEDIA_FRAMEBUFFER_END',start)
snapshot='`timescale 1ns/1ps\n'+contents[start:end]
if context.exists():
    assert context.read_text(encoding='utf-8')==snapshot, 'Framebuffer snapshot differs; review before updating it'
else:
    context.write_text(snapshot,encoding='utf-8')
binary=AUDIT/'staged_full_frame.vvp'
assert binary.resolve().parent==AUDIT.resolve() and binary.suffix=='.vvp'
subprocess.run([str(ROOT/'tools/iverilog/bin/iverilog.exe'),'-g2012','-s','tb_framebuffer',
                '-o',str(binary),str(AUDIT/'media_sdram_ctrl_negedge.stage.v'),str(context),
                str(AUDIT/'em638325_pipeline_model.v'),str(ROOT/'sim/sdram/tb_framebuffer.v')],cwd=ROOT,check=True)
subprocess.run([str(ROOT/'tools/iverilog/bin/vvp.exe'),str(binary)],cwd=ROOT,check=True,timeout=900)
binary.unlink()
print('PASS existing full-frame integration using staged controller + independent SDRAM pipeline model',flush=True)
