# -*- coding: utf-8 -*-
import math, sys
sys.path.insert(0,'.')
from design_spec2 import bgm_track, midi_hz, A_HP, C_LP
FS=32000
G=[1.15,1.05,1.0,0.98,0.98,1.0,1.05,1.15]

def tone(freq,n,amp=52):
    ph=0.0; out=[]
    for _ in range(n):
        ph+=2*math.pi*freq/FS
        out.append(amp if math.sin(ph)>=0 else -amp)
    return out

def run(seq, base=10.0, K=7.0, dec=13):
    pre=[0.0]*4; hpv=[0.0]*8; xp=[0.0]*8; lpv=[0.0]*8; fast=[0.0]*8; env=[0.0]*8
    out=[]
    for x in seq:
        for i in range(4): pre[i]+=(x-pre[i])*0.25
        xs=pre[-1]
        for i in range(8):
            t=hpv[i]+xs-xp[i]; y=t*A_HP[i]; hpv[i]=y; xp[i]=xs
            lo=lpv[i]+(y-lpv[i])*C_LP[i]; lpv[i]=lo
            a=abs(lo); fast[i]+=(a-fast[i])/32.0
            if fast[i]>env[i]: env[i]=fast[i]
            else: env[i]=max(0.0,env[i]-(env[i]/(1<<dec)+1.0))
        avg=sum(env)/8.0
        out.append([max(0,min(120,int(base+K*(env[i]*G[i]-avg*0.85)))) for i in range(8)])
    return out

print("=== 单音 (diff 模式) ===")
prev=-1; ok=True
for f in (150,200,260,340,450,600,800,1050,1400):
    b=run(tone(f,14000))[-1]; pk=b.index(max(b))
    if pk<prev: ok=False
    prev=pk
    print("  %5d | %s | seg%d"%(f," ".join("%3d"%v for v in b),pk))
print("  单调:", "通过" if ok else "不通过")

pcm, info = bgm_track(0, 10.0)
hist=run(pcm)
print("\n=== BGM ===")
for k in range(0,len(hist),4000):
    n0=info[k][0]
    lab=("%dhz"%midi_hz(n0)) if n0!=0x7F else "--"
    print("  %5.2fs %7s | %s"%(k/float(FS),lab," ".join("%3d"%v for v in hist[k])))
tail=hist[len(hist)//2:]
same=tot=0
for a,b in zip(tail,tail[1:]):
    dd=[b[i]-a[i] for i in range(8)]; nz=[x for x in dd if x]
    if len(nz)>=4:
        tot+=1; pos=sum(1 for x in nz if x>0)
        if pos>=len(nz)*0.75 or pos<=len(nz)*0.25: same+=1
lo=[(midi_hz(info[k][0]),hist[k].index(max(hist[k]))) for k in range(0,len(hist),500) if info[k][0]!=0x7F]
l=[p[1] for p in lo if p[0]<700]; h=[p[1] for p in lo if p[0]>=700]
vals=[v for r in tail for v in r]
print("\n同步率 %.0f%%  低音段 %.2f  高音段 %.2f  差 %.2f"%(100.0*same/max(1,tot),sum(l)/len(l),sum(h)/len(h),sum(h)/len(h)-sum(l)/len(l)))
print("柱高均值 %.1f 最大 %d 饱和 %.1f%%"%(sum(vals)/len(vals),max(vals),100.0*sum(1 for v in vals if v>=119)/len(vals)))
