"""Independent float DFT checks of real 48 kHz input and streaming behavior.
Run: python sim/spectrum/run_spectrum.py
Only Icarus and the Python standard library are required. No native FPGA build.
"""
from pathlib import Path
import argparse
import cmath
import json
import math
import random
import subprocess
import time
ROOT=Path(__file__).resolve().parents[2]
parser=argparse.ArgumentParser()
parser.add_argument('--rtl',default='rtl/video/hdmi_tx.v')
parser.add_argument('--out',default='sim/spectrum/out')
args=parser.parse_args()
RTL=ROOT/args.rtl
OUT=ROOT/args.out
OUT.mkdir(exist_ok=True)
IVERILOG=ROOT/'tools/iverilog/bin/iverilog.exe'
VVP=ROOT/'tools/iverilog/bin/vvp.exe'
bands=[(1,1),(2,2),(3,4),(5,8),(9,16),(17,32),(33,64),(65,127)]
cases=[]
def add(name,samples,reset=True,period=525,kind=None):
    cases.append(dict(name=name,samples=samples,reset=reset,period=period,kind=kind))
def tone(k,amp=16000):
    return [round(amp*math.sin(2*math.pi*k*n/256)) for n in range(256)]
for b,k in enumerate([1,2,3,6,12,24,48,96]): add(f'band{b}_bin{k}',tone(k),kind=('tone',b))
add('two_tone_low_high',[a+b for a,b in zip(tone(3,10000),tone(96,10000))],kind=('mix',2,7))
add('two_tone_mid',[a+b for a,b in zip(tone(12,12000),tone(48,6000))],kind=('mix',4,6))
for amp in [128,256,512,1024,4096,16384]: add(f'amplitude_{amp}',tone(12,amp),kind=('amp',amp))
add('dc_fullscale',[32767]*256,kind=('dc',))
add('negative_dc',[-32768]*256,kind=('dc',))
add('silence',[0]*256,kind=('silence',))
add('impulse',[32767]+[0]*255,kind=('broad',))
rng=random.Random(148)
add('noise',[rng.randrange(-16000,16001) for _ in range(256)],kind=('noise',))
# Native 32 kHz signed 8-bit PSG samples held on the actual 48 kHz HDMI ticks.
psg=[round(90*math.sin(2*math.pi*24*(n*2//3)/256))*256 for n in range(256)]
add('psg_32k_to_48k_8bit_gain',psg,kind=('psg',))
# Exact consecutive 525-cycle sample ticks across all these frame boundaries.
for i,k in enumerate([1,96,3,48,2,24,6,12]):
    add(f'stream525_{i}_bin{k}',tone(k),reset=i==0,kind=('stream',))
# Reset once, then no discontinuity while checking the legacy cadence as well.
for i,k in enumerate([96,1,24]): add(f'stream833_{i}_bin{k}',tone(k),reset=i==0,period=833,kind=('stream',))
add('mute_start',tone(24,24000),kind=('mute_start',))
for i in range(64): add(f'muted_{i}',[0]*256,reset=False,kind=('muted',i))
add('resume',tone(96,16000),reset=False,kind=('resume',7))
vector_path=OUT/'vectors.txt'
with vector_path.open('w') as f:
    f.write(f'{len(cases)}\n')
    for c in cases:
        f.write(f"{c['period']} {int(c['reset'])}\n")
        f.writelines(f'{v}\n' for v in c['samples'])
binary=OUT/'tb.vvp'
subprocess.run([str(IVERILOG),'-g2001','-s','tb_audio_spectrum_fft','-o',str(binary),str(RTL),str(ROOT/'sim/spectrum/tb_audio_spectrum_fft.v')],check=True,cwd=ROOT)
started=time.monotonic()
with (OUT/'simulation.log').open('w') as log:
    subprocess.run([str(VVP),str(binary),f'+INPUT={vector_path}',f'+RESULT={OUT/"results.txt"}',f'+BINS={OUT/"bins.txt"}'],check=True,cwd=ROOT,stdout=log,stderr=subprocess.STDOUT,timeout=300)
simulation_log=(OUT/'simulation.log').read_text()
print(simulation_log.strip(),flush=True)
assert 'FAIL' not in simulation_log,simulation_log
assert 'PASS frames=' in simulation_log,simulation_log
results=[]
for line in (OUT/'results.txt').read_text().splitlines():
    frame,hex_levels,overflow,cycle=line.split()
    packed=int(hex_levels,16)
    assert int(frame)==len(results)
    assert int(overflow)==0,(frame,'overflow')
    results.append(([packed>>(8*b)&255 for b in range(8)],int(cycle)))
assert len(results)==len(cases),(len(results),len(cases))
bins={}
for line in (OUT/'bins.txt').read_text().splitlines():
    frame,k,re,im=map(int,line.split())
    bins.setdefault(frame,{})[k]=complex(re,im)
def dft(samples):
    return {k:sum(v*cmath.exp(-2j*math.pi*k*n/256) for n,v in enumerate(samples))/256 for k in range(1,128)}
cache={}
max_error=0
amp_levels=[]
summary=[]
for i,c in enumerate(cases):
    key=tuple(c['samples'])
    if key not in cache: cache[key]=dft(key)
    expected=cache[key]
    actual=bins[i]
    assert len(actual)==127,(c['name'],len(actual))
    error=max(max(abs(actual[k].real-expected[k].real),abs(actual[k].imag-expected[k].imag)) for k in expected)
    max_error=max(max_error,error)
    assert error<=10,(c['name'],'DFT component error',error)
    peaks=[max(abs(expected[k].real)+abs(expected[k].imag) for k in range(lo,hi+1)) for lo,hi in bands]
    levels,cycle=results[i]
    assert all(0<=v<=120 for v in levels)
    kind=c['kind']
    if kind[0]=='tone':
        b=kind[1]
        assert levels.index(max(levels))==b,(c['name'],levels)
        assert max(v for j,v in enumerate(levels) if j!=b)<=2,(c['name'],levels)
    elif kind[0]=='mix':
        expected_bands=set(kind[1:])
        top=set(sorted(range(8),key=lambda b:levels[b],reverse=True)[:2])
        assert top==expected_bands,(c['name'],levels)
    elif kind[0]=='amp': amp_levels.append(levels[4])
    elif kind[0] in ('dc','silence'): assert levels==[0]*8,(c['name'],levels)
    elif kind[0]=='broad': assert min(levels)>0 and max(levels)-min(levels)<=1,(c['name'],levels)
    elif kind[0]=='noise': assert min(levels)>0,(c['name'],levels)
    elif kind[0]=='psg': assert levels.index(max(levels))==peaks.index(max(peaks)),(c['name'],levels,peaks)
    elif kind[0]=='stream':
        # Allow the specified gradual decay from the previous unrelated block.
        dominant=peaks.index(max(peaks))
        assert levels[dominant]>=85,(c['name'],levels)
        if not c['reset']:
            assert cycle-results[i-1][1]==256*c['period'],(c['name'],'frame cadence')
    elif kind[0]=='muted':
        previous=results[i-1][0]
        assert all(v==max(0,p-2) for v,p in zip(levels,previous)),(c['name'],levels,previous)
        if kind[1]>=59: assert levels==[0]*8,(c['name'],levels)
    elif kind[0]=='resume': assert levels.index(max(levels))==kind[1] and max(levels)>80
    summary.append(dict(name=c['name'],levels=levels,dft_error=round(error,5),period=c['period']))
assert all(a<b for a,b in zip(amp_levels,amp_levels[1:])),amp_levels
report=dict(frames=len(cases),max_dft_component_error=max_error,amplitude_levels=amp_levels,simulation_seconds=round(time.monotonic()-started,2),cases=summary)
(OUT/'report.json').write_text(json.dumps(report,indent=2))
print(f"PASS independent DFT: {len(cases)} frames, max component error {max_error:.4f}; amplitude levels {amp_levels}")
print(f"PASS 525/833 streaming, 8 bands, mixtures, DC/silence, impulse/noise, 32k PSG gain, mute decay and resume ({report['simulation_seconds']} s)")
overflow_binary=OUT/'overflow.vvp'
subprocess.run([str(IVERILOG),'-g2001','-s','tb_spectrum_overflow','-o',str(overflow_binary),str(RTL),str(ROOT/'sim/spectrum/tb_spectrum_overflow.v')],check=True,cwd=ROOT)
with (OUT/'overflow.log').open('w') as log:
    subprocess.run([str(VVP),str(overflow_binary)],check=True,cwd=ROOT,stdout=log,stderr=subprocess.STDOUT,timeout=30)
overflow_log=(OUT/'overflow.log').read_text()
assert 'FAIL' not in overflow_log and 'PASS impossible cadence' in overflow_log,overflow_log
print(overflow_log.strip())
