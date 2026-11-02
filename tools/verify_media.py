#!/usr/bin/env python3
"""Controller/CDC/real-loader integration; --full also executes all SD/video suites."""
from pathlib import Path
import argparse
import json
import subprocess
import sys
from verify_sd_rtl import ROOT,SIM,find_tool,execute
from verify_sd_catalog import make_case

OUT=SIM/'out'/'media_system'

def main():
    ap=argparse.ArgumentParser(description=__doc__);ap.add_argument('--full',action='store_true')
    ap.add_argument('--case',action='append',choices=('media_ctrl','media_navigation','media_pause','media_pause_key','media_zoom_key','media_cdc','media_system','media_audio','media_hdmi'))
    args=ap.parse_args()
    OUT.mkdir(parents=True,exist_ok=True)
    iv,vvp=find_tool('iverilog'),find_tool('vvp')
    results=[]
    for name in (args.case or ('media_ctrl','media_navigation','media_pause','media_pause_key','media_zoom_key','media_cdc','media_system','media_audio','media_hdmi')):
        exe=OUT/(name+'.vvp')
        sources=[SIM/('tb_'+name+'.v'),ROOT/'rtl/common/key_debounce.v']
        if name=='media_system': sources.append(ROOT/'rtl/video/rpg_video.v')
        flags=[]
        if name in ('media_audio','media_hdmi','media_pause_key'):
            flags=['-i','-DSIM_BEHAV','-I',ROOT/'rtl/gen','-I',ROOT/'rtl/ctrl']
            sources += [ROOT/x for x in ('rtl/rpg_top.v','rtl/clk_gen.v','rtl/common/reset_sync.v','rtl/ctrl/rpg_core.v','rtl/gen/rpg_msgs.v','rtl/gen/ui_rom.v','rtl/gen/anim_rom.v','rtl/gen/mon_rom.v','rtl/video/rpg_video.v','rtl/video/vid_timing.v','rtl/video/mon_layer.v','rtl/video/hdmi_tx.v')]
        rc,compile_log=execute([iv,('-g2001' if name=='media_zoom_key' else '-g2012'),'-Wall',*flags,'-s','tb_'+name,'-o',exe,*sources])
        log=compile_log
        if not rc:
            cmd=[vvp,exe]
            if name=='media_system':
                c=make_case();entries=sorted(c['disk'].items())
                (OUT/'lba.hex').write_text(''.join(f'{a:08x}\n'for a,_ in entries))
                (OUT/'data.hex').write_text(''.join(bytes(s).hex(' ').replace(' ','\n')+'\n'for _,s in entries))
                (OUT/'expected.hex').write_text(''.join(f'{x:x}\n'for x in c['expected'][:98304]))
                cmd += [f'+NSECTORS={len(entries)}',f'+LBA={(OUT/"lba.hex").as_posix()}',f'+DATA={(OUT/"data.hex").as_posix()}',f'+EXPECTED={(OUT/"expected.hex").as_posix()}']
            try:rc,run_log=execute(cmd,timeout=240);log+=run_log
            except subprocess.TimeoutExpired:rc=1;log+='Host simulation timeout\n'
        (OUT/(name+'.log')).write_text(log,encoding='utf-8')
        passed=rc==0 and 'PASS '+name in log
        results.append(dict(case=name,passed=passed,returncode=rc,log=str(OUT/(name+'.log'))))
        print(('PASS 'if passed else'FAIL ')+name+'\n'+log,flush=True)
    if args.full:
        for label,command in [('SD algorithms',[sys.executable,'-B','tools/verify_sd.py']),('SD RTL',[sys.executable,'-B','tools/verify_sd_rtl.py','--spi','--diag','--display']),('catalog',[sys.executable,'-B','tools/verify_sd_catalog.py']),('media video',[sys.executable,'-B','tools/verify_media_video.py'])]:
            try:rc,log=execute(command,timeout=600)
            except subprocess.TimeoutExpired:rc=1;log='Host regression timeout\n'
            (OUT/(label.replace(' ','_')+'.log')).write_text(log,encoding='utf-8')
            print(('PASS 'if rc==0 else'FAIL ')+label+'\n'+log,flush=True)
            results.append(dict(case=label,passed=rc==0,returncode=rc))
    report=OUT/(('results_'+'_'.join(args.case)+'.json') if args.case else 'results.json')
    report.write_text(json.dumps(results,indent=2),encoding='utf-8')
    return 0 if all(x['passed']for x in results)else 1

if __name__=='__main__':raise SystemExit(main())
