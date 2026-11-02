#!/usr/bin/env python3
"""Prepare ordinary 24-bit BMP assets for the FPGA player; never opens a TF device.

Examples:
  python tools/prepare_media.py --demo --output tools/out/media_demo
  python tools/prepare_media.py --sequence frames --gallery pictures --output tools/out/media_pack

FPGA still performs FAT32 scanning, BMP parsing, sampling, palette conversion and
playback. This offline tool only encodes source artwork as supported BMP files.
Its optional aspect-preserving asset resize is not a claimed FPGA fit algorithm.
"""
from __future__ import annotations
import argparse
import json
from pathlib import Path
import struct
from PIL import Image, ImageDraw, ImageFont, ImageOps

EXTENSIONS={'.bmp','.png','.jpg','.jpeg','.webp'}

def image_files(folder):
    if not folder: return []
    if not folder.is_dir(): raise ValueError(f'Image directory does not exist: {folder}')
    return sorted((p for p in folder.iterdir() if p.is_file() and p.suffix.lower() in EXTENSIONS),key=lambda p:p.name.casefold())

def font(size):
    for path in ('C:/Windows/Fonts/arialbd.ttf','/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf'):
        if Path(path).is_file(): return ImageFont.truetype(path,size)
    return ImageFont.load_default()

def demo_frames():
    result=[]
    for n in range(8):
        im=Image.new('RGB',(256,192),(12,12,16)); d=ImageDraw.Draw(im)
        d.text((10,6),'ASCII QUEST',font=font(22),fill='white')
        d.text((12,38),'LEVEL UP!' if n==6 else 'REWARDS' if n==7 else 'SLIME ENCOUNTER',font=font(15),fill=(255,192,0))
        d.rectangle((12,67,243,75),fill=(64,64,64))
        hp=max(0,36-n*7)
        d.rectangle((12,67,12+max(1,hp*231//36),75),fill=(255,48,32))
        # Simple original geometric creature. Every frame visibly differs.
        x=92+(n%3-1)*8
        d.ellipse((x,88,x+70,140),fill=(192,0,0),outline='white',width=2)
        d.rectangle((x+17,104,x+23,112),fill='white');d.rectangle((x+47,104,x+53,112),fill='white')
        d.text((12,151),'LEVEL 02' if n==6 else 'EXP +10  GOLD +08' if n==7 else f'HP {hp:02d} / 36   FRAME {n+1}',font=font(16),fill='white')
        result.append((f'ANIM{n+1:04d}.BMP',im,f'generated demo frame {n+1}'))
    for n,text in enumerate(('GALLERY MODE','FPGA MULTIMEDIA'),1):
        im=Image.new('RGB',(256,192),(24,24,24));d=ImageDraw.Draw(im)
        d.rectangle((4,4,251,187),outline=(255,192,0),width=3)
        d.text((12,30),text,font=font(20),fill='white')
        for k,line in enumerate(('TF CARD -> BMP','256 x 192 CACHE','KEYS: PREV / NEXT','PWM AUDIO + OSD')):
            d.text((14,80+k*22),line,font=font(15),fill=(255,192,0) if k%2 else 'white')
        result.append((f'PIC{n:05d}.BMP',im,f'generated demo poster {n}'))
    return result

def main():
    ap=argparse.ArgumentParser(description=__doc__,formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--sequence',type=Path);ap.add_argument('--gallery',type=Path)
    ap.add_argument('--output',type=Path,required=True)
    ap.add_argument('--size',default='640x480',help='encoded dimensions; SDRAM basic build requires640x480; legacy thumbnail builds may use256x192')
    ap.add_argument('--fit',choices=('contain','stretch'),default='contain')
    ap.add_argument('--demo',action='store_true');ap.add_argument('--overwrite',action='store_true')
    args=ap.parse_args()
    try:
        w,h=map(int,args.size.lower().split('x'))
        if not (256<=w<=65535 and 192<=h<=65535): raise ValueError('BMP dimensions must be at least256x192 and at most65535x65535')
        seq=image_files(args.sequence);gallery=image_files(args.gallery)
        if args.demo and (seq or gallery): raise ValueError('--demo cannot be combined with source folders')
        entries=demo_frames() if args.demo else [(f'ANIM{i:04d}.BMP',p,str(p.resolve())) for i,p in enumerate(seq,1)]+[(f'PIC{i:05d}.BMP',p,str(p.resolve())) for i,p in enumerate(gallery,1)]
        if not entries: raise ValueError('Provide --demo or a nonempty --sequence/--gallery folder')
        if len(entries)>32: raise ValueError(f'{len(entries)} images exceeds FPGA catalog limit32; split the collection')
        out=args.output.resolve()
        if out.exists() and any(out.iterdir()) and not args.overwrite:
            raise ValueError(f'Output is not empty: {out}; use a fresh folder or explicit --overwrite')
        out.mkdir(parents=True,exist_ok=True)
        manifest=[]
        for name,source,label in entries:
            if isinstance(source,Path):
                with Image.open(source) as im: image=ImageOps.exif_transpose(im).convert('RGB')
            else: image=source.convert('RGB')
            image=ImageOps.pad(image,(w,h),method=Image.Resampling.LANCZOS,color=(0,0,0)) if args.fit=='contain' else image.resize((w,h),Image.Resampling.LANCZOS)
            target=out/name;image.save(target,format='BMP')
            with target.open('rb') as f: header=f.read(54)
            assert header[:2]==b'BM' and struct.unpack_from('<H',header,28)[0]==24 and struct.unpack_from('<I',header,30)[0]==0
            manifest.append(dict(file=name,source=label,width=w,height=h,bytes=target.stat().st_size))
        (out/'manifest.json').write_text(json.dumps(dict(format='24-bit BI_RGB',fit=args.fit,sequence_count=sum(n.startswith('ANIM') for n,_,_ in entries),files=manifest),ensure_ascii=False,indent=2),encoding='utf-8')
        print(f'Prepared {len(entries)} BMP files in {out}; copy BMP files only to FAT32 root. No card was modified.')
        return 0
    except (ValueError,OSError) as exc: ap.error(str(exc))

if __name__=='__main__': raise SystemExit(main())
