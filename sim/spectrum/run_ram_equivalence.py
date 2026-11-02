"""Check staged single-read RAM candidate without touching production RTL."""
from pathlib import Path
import subprocess
import time
ROOT=Path(__file__).resolve().parents[2]
OUT=ROOT/'sim/spectrum/out'
OUT.mkdir(exist_ok=True)
candidate=ROOT/'sim/spectrum/audio_spectrum_fft_singleport_candidate.v'
text=candidate.read_text(encoding='utf-8')
assert text.count('module audio_spectrum_fft (')==1
renamed=OUT/'audio_spectrum_fft_candidate.v'
renamed.write_text(text.replace('module audio_spectrum_fft (','module audio_spectrum_fft_candidate ('),encoding='utf-8')
binary=OUT/'ram_equivalence.vvp'
subprocess.run([str(ROOT/'tools/iverilog/bin/iverilog.exe'),'-g2001','-s','tb_spectrum_ram_equivalence','-o',str(binary),str(ROOT/'rtl/video/hdmi_tx.v'),str(renamed),str(ROOT/'sim/spectrum/tb_spectrum_ram_equivalence.v')],cwd=ROOT,check=True)
started=time.monotonic()
log_path=OUT/'ram_equivalence.log'
with log_path.open('w') as log:
    subprocess.run([str(ROOT/'tools/iverilog/bin/vvp.exe'),str(binary)],stdout=log,stderr=subprocess.STDOUT,check=True,cwd=ROOT,timeout=120)
result=log_path.read_text()
print(result.strip())
assert 'FAIL' not in result and 'PASS cycle-exact RAM equivalence' in result,result
print(f'PASS candidate READY for native synthesis check ({time.monotonic()-started:.2f}s); production untouched.')
