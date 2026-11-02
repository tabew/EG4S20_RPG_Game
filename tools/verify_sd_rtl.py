#!/usr/bin/env python3
"""Run actual sd_img RTL with sparse FAT32 sectors and an independent pixel oracle.

No import of verify_sd.py or reproduction of the DUT state machine. Generated files
stay under sim/sd/out. Only public block-interface pins are driven by tb_sd_img.v.
"""
from __future__ import annotations
import argparse
import json
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
SIM = ROOT / 'sim' / 'sd'
OUT = SIM / 'out'


def put(buf, off, val, size=4):
    buf[off:off+size] = int(val).to_bytes(size, 'little', signed=val < 0)


def bmp_bytes(width, height, topdown=False):
    stride = (width * 3 + 3) & ~3
    data = bytearray(54 + stride * height)
    data[:2] = b'BM'
    for off, val, size in [(2,len(data),4),(10,54,4),(14,40,4),
                           (18,width,4),(22,-height if topdown else height,4),
                           (26,1,2),(28,24,2)]:
        put(data,off,val,size)
    # Nonlinear, coordinate-sensitive colors catch shifted rows/columns and wrong files.
    for storage_y in range(height):
        y = storage_y if topdown else height - 1 - storage_y
        for x in range(width):
            r = (x*37 + y*11 + (x*y)%173) & 255
            g = (x*7 + y*59 + (x^y)*3) & 255
            b = (x*19 + y*23 + (x*y)%251) & 255
            off = 54 + storage_y*stride + 3*x
            data[off:off+3] = bytes((b,g,r))
        data[54+storage_y*stride+3*width:54+(storage_y+1)*stride] = b'\xa7'*(stride-3*width)
    return data


def reference(bmp, cmap):
    """Direct inverse-bin sample coordinates; no RTL accumulators or FAT parser."""
    width = int.from_bytes(bmp[18:22],'little')
    signed_h = int.from_bytes(bmp[22:26],'little',signed=True)
    height = abs(signed_h)
    stride = (width*3+3)&~3
    result = []
    for y in range(192):
        bin_y = y if signed_h < 0 else 191-y
        sy = ((bin_y+1)*height+191)//192-1
        for x in range(256):
            sx = ((x+1)*width+255)//256-1
            off = 54 + sy*stride + sx*3
            b,g,r = bmp[off:off+3]
            result.append(cmap[((r>>4)<<8)|((g>>4)<<4)|(b>>4)])
    return result


def fixture(name, spc=1, superfloppy=False, width=257, height=193,
            topdown=False, high=False, fragmented=False, two_files=False,
            malformed=None, truncated=False, root_chain=False, fat_high=False, short_chain=False,
            bmp_source=None):
    disk = {}
    def sector(lba):
        return disk.setdefault(lba,bytearray(512))
    part = 0 if superfloppy else 2048
    rsvd, nfats, fatsz = 32,2,1024
    fat = part+rsvd
    base = fat+nfats*fatsz
    def clba(c): return base+(c-2)*spc
    def fatent(c,nxt): put(sector(fat+c//128),(c%128)*4,nxt)
    b=sector(part)
    b[:3]=b'\xeb\x58\x90'; b[3:11]=b'SDRTL   '
    for off,val,size in [(11,512,2),(13,spc,1),(14,rsvd,2),(16,nfats,1),
                         (32,16777216,4),(36,fatsz,4),(44,2,4)]: put(b,off,val,size)
    b[82:90]=b'FAT32   '; b[510:512]=b'\x55\xaa'
    if not superfloppy:
        m=sector(0); m[450]=0x0c; put(m,454,part); put(m,458,16777216); m[510:512]=b'\x55\xaa'
    fatent(0,0x0ffffff8); fatent(1,0x0fffffff); fatent(2,0x0fffffff)
    bmp=bytearray(Path(bmp_source).read_bytes()) if bmp_source else bmp_bytes(width,height,topdown)
    original=bytes(bmp)
    if malformed=='compression': put(bmp,30,1)
    elif malformed=='planes': put(bmp,26,2,2)
    elif malformed=='signature': bmp[:2]=b'XX'
    elif malformed=='offset': put(bmp,10,30)
    elif malformed=='dib': put(bmp,14,12)
    elif malformed=='bpp': put(bmp,28,16,2)
    elif malformed=='short_header': bmp=bmp[:30]
    if truncated: bmp=bmp[:len(bmp)//2]
    start=65543 if high else 6
    def store_file(blob,first):
        count=(len(blob)+spc*512-1)//(spc*512)
        chain=[first+i*(7 if fragmented else 1) for i in range(count)]
        for i,c in enumerate(chain):
            fatent(c,chain[i+1] if i+1<count else 0x0fffffff)
            chunk=blob[i*spc*512:(i+1)*spc*512]
            for s in range((len(chunk)+511)//512):
                seg=chunk[s*512:(s+1)*512]; sector(clba(c)+s)[:len(seg)]=seg
        return chain
    chain=store_file(bmp,start)
    if fat_high:
        for c in chain:
            off=(c%128)*4
            disk[fat+c//128][off+3] |= 0xa0
    if short_chain: fatent(start,0x0fffffff)
    root=sector(clba(2))
    if root_chain:
        for s in range(spc):
            sec=sector(clba(2)+s)
            for j in range(16): sec[j*32]=0xe5
        fatent(2,500); fatent(500,0x0fffffff); root=sector(clba(500))
    def entry(sec,off,first,size,label):
        sec[off:off+11]=label; sec[off+11]=0x20
        put(sec,off+20,first>>16,2); put(sec,off+26,first&65535,2); put(sec,off+28,size)
    entry(root,0,start,len(bmp),b'FIRST   BMP')
    if two_files:
        other=bmp_bytes(width,height,not topdown)
        # Different colors and orientation make "last matching directory entry wins" fail.
        for k in range(54,len(other)): other[k]^=0xff
        store_file(other,1000)
        entry(root,32,1000,len(other),b'SECOND  BMP')
    cmap=[int(t,16) for t in (ROOT/'rtl/gen/tf_map.hex').read_text().split()]
    expected=reference(original,cmap)
    error=3 if malformed or truncated or short_chain or width<256 or height<192 else 0
    return dict(name=name,sectors=disk,expected=expected,error=error,chain=chain)


def cases():
    out=[]
    for superfloppy in (False,True):
        for spc in (1,2,4,8,16,32,64,128):
            out.append(fixture(f'{"super" if superfloppy else "mbr"}_spc{spc}',spc=spc,
                superfloppy=superfloppy,width=513 if spc==128 else 257,
                height=385 if spc==128 else 193,fragmented=True))
    out += [fixture('vga_640x480',spc=4,width=640,height=480,fragmented=True),
            fixture('exact_256x192',width=256,height=192),
            fixture('rejected_128x96',width=128,height=96),
            fixture('fat_reserved_nibble',fat_high=True,fragmented=True),
            fixture('short_fat_chain',short_chain=True),
            fixture('topdown_padding',spc=4,topdown=True),
            fixture('high_cluster_fragmented',high=True,fragmented=True),
            fixture('directory_first_image',two_files=True),
            fixture('directory_cluster_chain',root_chain=True),
            fixture('truncated_pixels',truncated=True),
            fixture('smaller_width',width=255),fixture('smaller_height',height=191)]
    real_bmp=ROOT/'tools/out/sd_test.bmp'
    if real_bmp.exists():
        out.append(fixture('existing_sd_test_bmp',spc=4,width=640,height=480,bmp_source=real_bmp))
    for bad in ('compression','planes','signature','offset','dib','bpp','short_header'):
        out.append(fixture('bad_'+bad,malformed=bad))
    return out


def find_tool(name, explicit=None):
    if explicit: return str(Path(explicit).resolve())
    found=shutil.which(name)
    if found: return found
    for base in (ROOT/'tools/iverilog',ROOT/'tools/iverilog/mingw64',ROOT/'tools/oss-cad-suite'):
        for rel in (f'bin/{name}.exe',f'{name}.exe'):
            p=base/rel
            if p.is_file(): return str(p)
    raise SystemExit(f'{name} not found; pass --{name} PATH or install portable Icarus under tools/iverilog')


def execute(cmd, cwd=ROOT, timeout=120):
    p=subprocess.run([str(c) for c in cmd],cwd=cwd,text=True,encoding='utf-8',errors='replace',stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=timeout)
    return p.returncode,p.stdout


def main():
    global OUT
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--iverilog'); ap.add_argument('--vvp'); ap.add_argument('--rtl',type=Path,default=ROOT/'rtl/common/key_debounce.v')
    ap.add_argument('--case',action='append',help='substring selection, repeatable')
    ap.add_argument('--list',action='store_true'); ap.add_argument('--spi',action='store_true',help='also run wire-level SPI bench')
    ap.add_argument('--diag',action='store_true',help='also run gallery diagnostic output bench')
    ap.add_argument('--display',action='store_true',help='also run real RAM and 2x2 gallery mapping/RGB bench')
    ap.add_argument('--out',type=Path,default=OUT,help='generated output directory')
    args=ap.parse_args()
    OUT=args.out.resolve()
    all_cases=cases()
    selected=[c for c in all_cases if not args.case or any(s in c['name'] for s in args.case)]
    if args.list:
        print('\n'.join(c['name'] for c in selected)); return 0
    if not selected: raise SystemExit('No matching cases')
    iv=find_tool('iverilog',args.iverilog); vvp=find_tool('vvp',args.vvp)
    OUT.mkdir(parents=True,exist_ok=True)
    exe=OUT/'sd_img.vvp'
    rc,log=execute([iv,'-g2012','-s','tb_sd_img','-o',exe,SIM/'tb_sd_img.v',args.rtl.resolve()])
    if rc: print(log); return rc
    (OUT/'compile.log').write_text(log,encoding='utf-8')
    results=[]
    for case in selected:
        dest=OUT/case['name']; dest.mkdir(exist_ok=True)
        entries=sorted(case['sectors'].items())
        (dest/'lba.hex').write_text(''.join(f'{a:08x}\n' for a,_ in entries))
        (dest/'data.hex').write_text(''.join(bytes(s).hex(' ').replace(' ','\n')+'\n' for _,s in entries))
        (dest/'expected.hex').write_text(''.join(f'{v:x}\n' for v in case['expected']))
        cmd=[vvp,exe,f'+NSECTORS={len(entries)}',f'+ERROR={case["error"]}',
             f'+LBA={(dest/"lba.hex").as_posix()}',f'+DATA={(dest/"data.hex").as_posix()}',
             f'+EXPECTED={(dest/"expected.hex").as_posix()}']
        try: rc,log=execute(cmd)
        except subprocess.TimeoutExpired: rc,log=1,'Host simulation timeout\n'
        (dest/'simulation.log').write_text(log,encoding='utf-8')
        passed=rc==0 and 'PASS sd_img' in log
        print(f'{"PASS" if passed else "FAIL"} {case["name"]}: {log.strip().splitlines()[-1] if log.strip() else "no output"}',flush=True)
        results.append(dict(case=case['name'],passed=passed,returncode=rc,log=str(dest/'simulation.log')))
    if args.spi:
        spi_exe=OUT/'sd_spi.vvp'
        rc,log=execute([iv,'-g2012','-s','tb_sd_spi','-o',spi_exe,SIM/'tb_sd_spi.v',args.rtl.resolve()])
        if not rc: rc,log=execute([vvp,spi_exe],timeout=180)
        (OUT/'spi.log').write_text(log,encoding='utf-8')
        passed=rc==0 and 'PASS sd_spi' in log
        print(('PASS' if passed else 'FAIL')+' spi: '+log.strip().splitlines()[-1],flush=True)
        results.append(dict(case='spi',passed=passed,returncode=rc,log=str(OUT/'spi.log')))
    if args.diag:
        diag_exe=OUT/'sd_diag.vvp'
        rc,log=execute([iv,'-g2012','-s','tb_sd_diag','-o',diag_exe,SIM/'tb_sd_diag.v',ROOT/'rtl/video/rpg_video.v'])
        if not rc: rc,log=execute([vvp,diag_exe])
        (OUT/'diag.log').write_text(log,encoding='utf-8')
        passed=rc==0 and 'PASS sd_diag' in log
        print(('PASS' if passed else 'FAIL')+' diag: '+log.strip().splitlines()[-1],flush=True)
        results.append(dict(case='diag',passed=passed,returncode=rc,log=str(OUT/'diag.log')))
    if args.display:
        display_exe=OUT/'sd_display.vvp'
        rc,log=execute([iv,'-g2012','-s','tb_sd_display','-o',display_exe,SIM/'tb_sd_display.v',ROOT/'rtl/video/rpg_video.v'])
        if not rc: rc,log=execute([vvp,display_exe])
        (OUT/'display.log').write_text(log,encoding='utf-8')
        passed=rc==0 and 'PASS sd_display' in log
        print(('PASS' if passed else 'FAIL')+' display: '+log.strip().splitlines()[-1],flush=True)
        results.append(dict(case='display',passed=passed,returncode=rc,log=str(OUT/'display.log')))
    (OUT/'results.json').write_text(json.dumps(results,indent=2),encoding='utf-8')
    print(f'{sum(r["passed"] for r in results)}/{len(results)} RTL regressions passed')
    return 0 if all(r['passed'] for r in results) else 1

if __name__=='__main__': sys.exit(main())
