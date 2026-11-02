#!/usr/bin/env python3
"""Render actual gal_layer Verilog to PNG; this is simulation, not a board photo."""
import argparse
from pathlib import Path
from PIL import Image
from verify_sd_rtl import ROOT,SIM,find_tool,execute,reference

def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--image',type=Path,default=ROOT/'tools/out/media_demo/PIC00001.BMP')
    ap.add_argument('--output',type=Path,default=ROOT/'tools/out/media_player_preview.png')
    ap.add_argument('--view',type=int,choices=(0,1,2),default=0)
    args=ap.parse_args();out=SIM/'out'/'preview';out.mkdir(parents=True,exist_ok=True)
    cmap=[int(x,16)for x in (ROOT/'rtl/gen/tf_map.hex').read_text().split()]
    pixels=reference(args.image.read_bytes(),cmap)
    (out/'image.hex').write_text(''.join(f'{x:x}\n'for x in pixels))
    exe=out/'preview.vvp'
    rc,log=execute([find_tool('iverilog'),'-g2012','-s','tb_media_preview','-o',exe,SIM/'tb_media_preview.v',ROOT/'rtl/video/rpg_video.v'])
    if not rc:rc,log=execute([find_tool('vvp'),exe,f'+IMAGE={(out/"image.hex").as_posix()}',f'+OUTPUT={(out/"preview.ppm").as_posix()}',f'+VIEW={args.view}'])
    (out/'render.log').write_text(log,encoding='utf-8')
    if rc:print(log);return rc
    args.output.parent.mkdir(parents=True,exist_ok=True)
    with Image.open(out/'preview.ppm')as im:
        assert im.size==(800,600);im.save(args.output)
    print(log+f'Simulation preview: {args.output}')
    return 0

if __name__=='__main__':raise SystemExit(main())
