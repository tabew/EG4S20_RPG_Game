"""Compile HDMI logical encoder and independently decode transmitted TMDS packets.
No vendor encrypted serializer model is involved; this proves parallel symbols only.
Usage: python tools/verify_hdmi_audio.py [--decode-only]
"""
from pathlib import Path
import collections
import math
import subprocess
import sys

ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'sim/hdmi_audio'
TERC=[0b1010011100,0b1001100011,0b1011100100,0b1011100010,
      0b0101110001,0b0100011110,0b0110001110,0b0100111100,
      0b1011001100,0b0100111001,0b0110011100,0b1011000110,
      0b1010001110,0b1001110001,0b0101100011,0b1011000011]
INV={v:k for k,v in enumerate(TERC)}
CTRL=[0b1101010100,0b0010101011,0b0101010100,0b1010101011]

def bch(data,bits):
    # Polynomial long division in the transmitted, least-significant-bit order.
    state=0
    for i in range(bits):
        feedback=(state^(data>>i))&1
        state >>= 1
        if feedback: state ^= 0x83
    return state

def video_decode(word):
    qm=(word&255) ^ (255 if word&512 else 0)
    data=qm&1
    for bit in range(1,8):
        b=((qm>>bit)^(qm>>(bit-1)))&1
        if not word&256: b^=1
        data|=b<<bit
    return data

def run():
    if '--decode-only' not in sys.argv:
        iv=ROOT/'tools/iverilog/bin/iverilog.exe'
        vvp=ROOT/'tools/iverilog/bin/vvp.exe'
        source=ROOT/'rtl/video/hdmi_tx.v'
        subprocess.run([str(iv),'-g2012','-s','tb_hdmi_wrapper','-o',str(OUT/'wrapper.vvp'),str(source),str(OUT/'tb_hdmi_wrapper.v')],cwd=ROOT,check=True)
        subprocess.run([str(vvp),str(OUT/'wrapper.vvp')],cwd=ROOT,check=True)
        subprocess.run([str(iv),'-g2012','-s','tb_hdmi_audio','-o',str(OUT/'encoder.vvp'),str(source),str(OUT/'tb_hdmi_audio.v')],cwd=ROOT,check=True)
        subprocess.run([str(vvp),str(OUT/'encoder.vvp')],cwd=ROOT,check=True)
    packets=[]; group=[]; ticks=[]; events=[]; video_count=0
    for line in (OUT/'trace.txt').open():
        p=line.split()
        if p[0]=='S': ticks.append(int(p[1])); continue
        c,m,h,v,d=map(int,p[1:6]); rgb,a,b,e=(int(t,16) for t in p[6:])
        events.append((c,m,h,v,d,a,b,e))
        if m==0: assert a==CTRL[(v<<1)|h],(c,'control sync')
        elif m==2: assert (a,b,e)==(0b1011001100,0b0100110011,0b1011001100)
        elif m==4: assert (a,b,e)==(TERC[12+((v<<1)|h)],0b0100110011,0b0100110011)
        if m==1:
            assert d==1
            got=(video_decode(e)<<16)|(video_decode(b)<<8)|video_decode(a)
            assert got==rgb,(c,hex(got),hex(rgb))
            # The undelayed input coordinate is exactly ten clock indices older.
            pos=(c-10)%(1056*628); x=pos%1056; y=pos//1056
            assert x<800 and y<600,(c,x,y)
            expected=((x&255)<<16)|((y&255)<<8)|((x^y)&255)
            assert rgb==expected,(c,hex(rgb),hex(expected))
            video_count+=1
        if m==3:
            na,nb,nc=INV[a],INV[b],INV[e]
            assert na&3==((v<<1)|h),(c,'sync inside data island')
            assert na&8
            group.append((c,(na>>2)&1,nb,nc))
            if len(group)==32:
                hdr=sum(q[1]<<i for i,q in enumerate(group))
                subs=[sum((((q[2]>>k)&1)<<(2*i))|(((q[3]>>k)&1)<<(2*i+1)) for i,q in enumerate(group)) for k in range(4)]
                assert hdr>>24==bch(hdr&0xffffff,24),(c,'header ECC')
                for sub in subs: assert sub>>56==bch(sub&((1<<56)-1),56),(c,'subpacket ECC')
                packets.append((group[0][0],hdr&0xffffff,[s&((1<<56)-1) for s in subs]))
                group=[]
        else: assert not group,'partial packet'
    assert video_count>800
    intervals=collections.Counter(b-a for a,b in zip(ticks,ticks[1:]))
    assert set(intervals)=={833,834},intervals
    assert abs(len(ticks)-1326350*48000/40000000)<1
    types=collections.Counter(); samples=[]; status_l=[]; status_r=[]; fi=0
    sample_packet_times=[]
    for cycle,hdr,subs in packets:
        typ=hdr&255; types[typ]+=1
        if typ in (0x82,0x84):
            data=b''.join(s.to_bytes(7,'little') for s in subs)
            length=hdr>>16
            assert ((hdr&255)+((hdr>>8)&255)+length+sum(data[:length+1]))%256==0,'InfoFrame checksum'
            if typ==0x82: assert data[1]==0 and data[3]==8 and data[4]==0,'RGB full-range VIC=0'
            else: assert data[1]==1 and data[2]==0 and data[4]==0,'stereo audio layout'
        elif typ==1:
            assert len(set(subs))==1
            data=subs[0].to_bytes(7,'little')
            cts=(data[1]<<16)|(data[2]<<8)|data[3]
            n=(data[4]<<16)|(data[5]<<8)|data[6]
            assert (n,cts)==(6144,40000)
            assert 40000000*n/(128*cts)==48000
        elif typ==2:
            sample_packet_times.append(cycle)
            present=(hdr>>8)&15
            for i,s in enumerate(subs):
                if not (present>>i)&1: assert s==0; continue
                assert ((hdr>>(20+i))&1)==int(fi==0),'IEC block start'
                left=s&0xffffff; right=(s>>24)&0xffffff; flags=s>>48
                assert left==right
                assert (flags&3)==0 and ((flags>>4)&3)==0,'valid/user flags'
                cl=(flags>>2)&1; cr=(flags>>6)&1
                assert (left.bit_count()+cl+((flags>>3)&1))%2==0
                assert (right.bit_count()+cr+((flags>>7)&1))%2==0
                expected=(round(8192*math.sin(2*math.pi*(len(samples)%48)/48))<<8)&0xffffff
                assert left==expected,(len(samples),hex(left),hex(expected))
                cs_l=(0xb<<32)|(2<<24)|(1<<20)|4
                cs_r=(0xb<<32)|(2<<24)|(2<<20)|4
                assert cl==((cs_l>>fi)&1) and cr==((cs_r>>fi)&1),'IEC60958 48kHz/24-bit channel status'
                status_l.append(cl); status_r.append(cr); samples.append(left)
                fi=(fi+1)%192
        else: raise AssertionError(('unexpected packet type',typ))
    assert all(types[t]>1000 for t in (1,2,0x82,0x84)),types
    assert 0<=len(ticks)-len(samples)<=4
    assert len(samples)>1500
    # Reconstruct HS, VS, DE widths and packet/preamble/guard durations from events.
    last={}; widths=collections.defaultdict(list)
    previous=None
    for ev in events:
        c,m,h,v,d,a,b,e=ev
        for key,value in [('h',h),('v',v),('d',d)]:
            if key not in last: last[key]=(c,value)
            elif value!=last[key][1]:
                oldc,oldv=last[key]
                if oldc>20: widths[(key,oldv)].append(c-oldc)
                last[key]=(c,value)
        if previous and previous[1]==4 and m!=4:
            assert c-previous[0]==2,'island guard length'
        if previous and previous[1]==2 and m!=2:
            assert c-previous[0]==2,'video guard length'
        if m==4 and (not previous or previous[1]!=4):
            if previous and previous[1]==0:
                assert previous[6:8]==(CTRL[1],CTRL[1])
                assert c-previous[0]==8,'data island preamble length'
        if m==2 and (not previous or previous[1]!=2):
            assert previous[1]==0 and previous[6:8]==(CTRL[1],CTRL[0])
            assert c-previous[0]==8,'video preamble length'
        # For long guard states the trace records only the beginning.
        if previous is None or ev[1]!=previous[1] or (m==0 and ev[6:8]!=previous[6:8]): previous=ev
    assert set(widths[('h',1)])=={128},widths[('h',1)][:10]
    assert set(widths[('h',0)])=={928}
    assert set(widths[('v',1)])=={4*1056}
    assert set(widths[('v',0)])=={624*1056}
    assert set(widths[('d',1)])=={800}
    assert set(widths[('d',0)])=={256,28*1056+256}
    result=f'PASS: {len(packets)} packets; {len(samples)} stereo samples; generated {len(ticks)} samples; video pixels decoded {video_count}; sample intervals {dict(intervals)}; HS=128/1056, VS=4/628, DE=800; BCH/InfoFrames/ACR/IEC60958/preambles/guards verified.'
    print(result)
    (OUT/'verification.txt').write_text(result+'\n',encoding='utf-8')

if __name__=='__main__': run()
