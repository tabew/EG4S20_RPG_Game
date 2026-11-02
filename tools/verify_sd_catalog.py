#!/usr/bin/env python3
"""Exercise sorted FAT32 catalog and repeated public sd_img load requests."""
from pathlib import Path
import json
import sys
from verify_sd_rtl import ROOT, SIM, put, bmp_bytes, reference, find_tool, execute

OUT = SIM / 'out' / 'catalog'


def make_case(cap=False, io=False, fast=False):
    disk = {}
    def sector(lba): return disk.setdefault(lba, bytearray(512))
    fat, base = 32, 1056
    def clba(c): return base + c - 2
    def link(c,n): put(sector(fat+c//128),(c%128)*4,n)
    boot=sector(0)
    for off,val,size in [(11,512,2),(13,1,1),(14,32,2),(16,1,1),(36,1024,4),(44,2,4)]: put(boot,off,val,size)
    boot[82:87]=b'FAT32'
    link(0,0xffffff8); link(1,0xfffffff)
    good0=bmp_bytes(256,192)
    good1=bmp_bytes(256,192,True)
    for i in range(54,len(good1)): good1[i] ^= 0xff
    bad=bytearray(good0); bad[:2]=b'XX'
    for blob,first in [(good0,6),(good1,1000),(bad,2000)]:
        n=(len(blob)+511)//512
        for i in range(n):
            c=first+i
            link(c,c+1 if i+1<n else 0xfffffff)
            data=blob[i*512:(i+1)*512]
            sector(clba(c))[:len(data)]=data
    if cap:
        entries=[(f'FILE{35-i:04d}'.encode(),6 if i%2==0 else 1000,0x20) for i in range(36)]
    else:
        entries=[(b'ZETA    ',1000,0x20),(b'ANIM0003',1000,0x20),
                 (b'DELETED ',6,0x20),(b'BROKEN  ',2000,0x20),(b'ANIM0001',6,0x20),
                 (b'ANIM1   ',1000,0x20),(b'ANIM123X',6,0x20),(b'ALPHA   ',6,0x20),
                 (b'VOLUME  ',6,0x08),(b'DIR     ',6,0x10),(b'LFN     ',6,0x0f)]
    roots=[2,500,501] if cap else [2,500]
    for i,c in enumerate(roots):
        link(c,roots[i+1] if i+1<len(roots) else 0xfffffff)
        for j in range(16): sector(clba(c))[j*32]=0xe5
    # Mixed case deliberately crosses a non-contiguous root FAT link before finding ANIM0001.
    locations=list(range(len(entries))) if cap else [0,1,2,3,16,17,18,19,20,21,22]
    kept=[]
    for (name,first,attr),loc in zip(entries,locations):
        sec=sector(clba(roots[loc//16])); off=32*(loc%16)
        sec[off:off+11]=name+b'BMP'; sec[off+11]=attr
        put(sec,off+26,first,2); put(sec,off+28,len(good0))
        if name==b'DELETED ': sec[off]=0xe5
        elif attr==0x20 and len(kept)<32: kept.append((name,first))
    # Normal cases reach root EOC; the fast mixed case exercises an explicit
    # end marker after scanning the noncontiguous second root cluster.
    if fast and not cap: sector(clba(roots[-1]))[7*32]=0
    kept.sort(key=lambda e:(not(e[0][:4]==b'ANIM' and e[0][4:].isdigit()),e[0]))
    seq=sum(n[:4]==b'ANIM' and n[4:].isdigit() for n,_ in kept)
    indexes=[0,1,0,1] if io else [0,31,0,15,32,1] if cap else [0,1,0,5,6,7,2]
    cmap=[int(t,16) for t in (ROOT/'rtl/gen/tf_map.hex').read_text().split()]
    refs={6:reference(good0,cmap),1000:reference(good1,cmap)}
    plans=[]; expected=[]
    for op,idx in enumerate(indexes):
        name,first=kept[idx] if idx<len(kept) else (b'        ',0)
        err=1 if io and op==1 else 0 if first in refs else 3
        plans.append((int.from_bytes(name,'big')<<16)|(idx<<8)|err)
        expected.extend(refs.get(first,[0]*49152))
    return dict(name=('cap32_fast_bytes' if cap else 'sorted_fast_end_marker') if fast else 'io_failure_remount' if io else 'cap32_retains_first32' if cap else 'sorted_chain_recovery',disk=disk,
                plans=plans,expected=expected,count=len(kept),seq=seq,io=int(io),fast=int(fast),
                forbid=clba(501) if cap else -1)


def main():
    OUT.mkdir(parents=True,exist_ok=True)
    iv,vvp=find_tool('iverilog'),find_tool('vvp')
    exe=OUT/'sd_catalog.vvp'
    rc,log=execute([iv,'-g2012','-s','tb_sd_catalog','-o',exe,SIM/'tb_sd_catalog.v',ROOT/'rtl/common/key_debounce.v'])
    (OUT/'compile.log').write_text(log,encoding='utf-8')
    if rc: print(log); return rc
    results=[]
    for case in (make_case(),make_case(True),make_case(io=True),
                 make_case(cap=True,fast=True),make_case(fast=True)):
        dest=OUT/case['name']; dest.mkdir(exist_ok=True)
        entries=sorted(case['disk'].items())
        (dest/'lba.hex').write_text(''.join(f'{a:08x}\n' for a,_ in entries))
        (dest/'data.hex').write_text(''.join(bytes(s).hex(' ').replace(' ','\n')+'\n' for _,s in entries))
        (dest/'expected.hex').write_text(''.join(f'{x:x}\n' for x in case['expected']))
        (dest/'plans.hex').write_text(''.join(f'{x:020x}\n' for x in case['plans']))
        rc,log=execute([vvp,exe,f'+NSECTORS={len(entries)}',f'+NOPS={len(case["plans"])}',
            f'+COUNT={case["count"]}',f'+SEQ={case["seq"]}',f'+FORBID={case["forbid"]}',f'+IO={case["io"]}',
            f'+FAST={case["fast"]}',f'+LBA={(dest/"lba.hex").as_posix()}',
            f'+DATA={(dest/"data.hex").as_posix()}',f'+EXPECTED={(dest/"expected.hex").as_posix()}',
            f'+PLAN={(dest/"plans.hex").as_posix()}'],timeout=180)
        (dest/'simulation.log').write_text(log,encoding='utf-8')
        passed=rc==0 and 'PASS sd_catalog' in log
        print(f'{"PASS" if passed else "FAIL"} {case["name"]}:\n{log}',flush=True)
        results.append(dict(case=case['name'],passed=passed,returncode=rc))
    (OUT/'results.json').write_text(json.dumps(results,indent=2))
    return 0 if all(x['passed'] for x in results) else 1

if __name__=='__main__': sys.exit(main())
