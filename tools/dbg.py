# -*- coding: utf-8 -*-
FS=32000.0; BPM=120; BTK=int(FS*60/(BPM*4))
rows=[int(l.strip(),16) for l in open('../rtl/gen/music.hex') if l.strip()]
pitch=[int(l.strip(),16) for l in open('../rtl/gen/pitch.hex') if l.strip()]
seq=[((r&0x7F),(r>>7)&0x7F,(r>>14)&0x7F,max(1,(r>>21)&0x7F)) for r in rows[0:64]]
si=0; left=seq[0][3]; n0,n1,n2=seq[0][0],seq[0][1],seq[0][2]
ph0=ph1=ph2=0; beat=0; e0=e1=e2=65535
dec=12; g_trace=[]; amp_trace=[]
for n in range(9000):
    nn=False
    if beat>=BTK:
        beat-=BTK; left-=1
        if left<=0:
            si=(si+1)%64; n0,n1,n2,d=seq[si]; left=d; nn=True
    beat+=1
    if nn: e0=e1=e2=65535
    else:
        e0=e0-(e0>>dec); e1=e1-(e1>>dec); e2=e2-(e2>>dec)
    g0=e0>>8
    ph0=(ph0+(0 if n0==0x7F else pitch[n0]))%(1<<24)
    ph1=(ph1+(0 if n1==0x7F else pitch[n1]))%(1<<24)
    ph2=(ph2+(0 if n2==0x7F else pitch[n2]))%(1<<24)
    if n%500==0:
        print("n=%5d (%5.1fms) e0=%6d g0=%3d  nn=%s"%(n,n/32.0,e0,g0,nn))
