"""Independent logical HDMI checks for the 40M custom and 25.2M CEA profiles.
Run: python tools/verify_hdmi_profiles.py
Uses only Python stdlib and the bundled Icarus. No vendor serial timing claim.
BCH uses polynomial division, not the encoder's feedback register algorithm.
TMDS reference tracks disparity by counting transmitted bits, not RTL acc_add.
Normative references: HDMI 1.3a sections 5.2, 5.3, 5.4, 7.2 and CEA-861 AVI.
"""
from pathlib import Path
from tempfile import TemporaryDirectory
from collections import Counter
import subprocess
import math
import sys

ROOT = Path(__file__).resolve().parents[1]
IV = ROOT / 'tools/iverilog/bin/iverilog.exe'
VVP = ROOT / 'tools/iverilog/bin/vvp.exe'
RTL = ROOT / 'rtl/video/hdmi_tx.v'
# HDMI TERC4 (section 5.4.3), indexed by D[3:0]; hexadecimal 10-bit symbols.
TERC = [0x29c,0x263,0x2e4,0x2e2,0x171,0x11e,0x18e,0x13c,
        0x2cc,0x139,0x19c,0x2c6,0x28e,0x271,0x163,0x2c3]
INV = {v:k for k,v in enumerate(TERC)}
CTRL = [0x354,0xab,0x154,0x2ab]
PROFILES = [(800,1056,600,628,840,128,601,4,40000000,0,1),
            (640,800,480,525,656,96,490,2,25200000,1,0)]

def run_sim(directory, name, source, defines=()):
    tb = directory / (name+'.v')
    tb.write_text(source, encoding='utf-8')
    exe = directory / (name+'.vvp')
    subprocess.run([str(IV),'-g2012','-s',name,*defines,'-o',str(exe),str(RTL),str(tb)],
                   cwd=ROOT,check=True)
    trace = directory / (name+'.txt')
    with trace.open('w') as output:
        subprocess.run([str(VVP),str(exe)],cwd=ROOT,stdout=output,check=True)
    return trace

def bch_valid(codeword, width):
    # HDMI g(x)=x^8+x^7+x^6+1. First transmitted bit is highest
    # polynomial coefficient here; all symbols on the wire are LSB first.
    polynomial = int(f'{codeword:0{width}b}'[::-1], 2)
    while polynomial.bit_length() > 8:
        polynomial ^= 0x1c1 << (polynomial.bit_length()-9)
    return polynomial == 0

def tmds_reference(data, disparity):
    use_xnor = data.bit_count() > 4 or (data.bit_count()==4 and not data&1)
    qm = data&1
    previous = data&1
    for bit in range(1,8):
        previous ^= ((data>>bit)&1) ^ int(use_xnor)
        qm |= previous<<bit
    selector = int(not use_xnor)
    balance = 2*qm.bit_count()-8
    if disparity==0 or balance==0:
        invert = not selector
    else:
        invert = (disparity>0) == (balance>0)
    word = (int(invert)<<9) | (selector<<8) | (qm ^ (255 if invert else 0))
    return word, disparity + 2*word.bit_count()-10

CHANNEL_TB = r'''
`timescale 1ns/1ps
module tb_channel;
reg clk=0; always #5 clk=~clk;
reg rst=0; reg [7:0] data=0; reg [2:0] mode=0;
reg [3:0] nib=1; reg [1:0] ctrl=1;
wire [9:0] t;
hdmi_audio_channel dut(.clk_pixel(clk),.rst_n(rst),.video_data(data),
 .data_island_data(nib),.control_data(ctrl),.mode(mode),.tmds(t));
integer i;
initial begin
 repeat(3) @(negedge clk); rst=1; ctrl=0;
 for(i=0;i<20000;i=i+1) begin
  data=(i*73)^(i>>3); mode=(i%263==0)?0:1;
  @(posedge clk); #1; $display("V %0d %0d %03x",mode,data,t);
  @(negedge clk);
 end
 for(i=0;i<16;i=i+1) begin
  mode=3; nib=i; @(posedge clk); #1; $display("T %0d %03x",i,t); @(negedge clk);
 end
 for(i=0;i<4;i=i+1) begin
  mode=0; ctrl=i; @(posedge clk); #1; $display("C %0d %03x",i,t); @(negedge clk);
 end
 $finish;
end
endmodule
'''

PROFILE_TB = r'''
`timescale 1ns/1ps
module tb_profile;
localparam HA=@HA@,HT=@HT@,VA=@VA@,VT=@VT@,HS=@HS@,HW=@HW@,VS=@VS@,VW=@VW@,PH=@PH@,VIC=@VIC@,POL=@POL@;
reg clk=0; always #5 clk=~clk;
reg rst=0; integer x=0,y=0,c=0,j;
wire hs=POL ? (x>=HS && x<HS+HW) : !(x>=HS && x<HS+HW);
wire vs=POL ? (y>=VS && y<VS+VW) : !(y>=VS && y<VS+VW);
wire de=x<HA && y<VA;
reg [5:0] delayed_de=0; reg [23:0] delayed_rgb[0:5];
wire [23:0] rgb={x[7:0],y[7:0],(x[7:0]^y[7:0])};
wire [9:0] a,b,d; wire tick,overflow,oh,ov,od; wire [2:0] mode; wire [23:0] orgb;
hdmi_audio_encoder #(.H_ACTIVE(HA),.H_TOTAL(HT),.PIXEL_HZ(PH),.VIDEO_ID(VIC)) dut(
 .clk_pix(clk),.rst_n(rst),.rgb(delayed_rgb[5]),.hs(hs),.vs(vs),.de(delayed_de[5]),.mute(c>=HT*VT),
 .tmds0(a),.tmds1(b),.tmds2(d),.sample_tick(tick),.overflow(overflow),
 .mode_out(mode),.hs_out(oh),.vs_out(ov),.de_out(od),.rgb_out(orgb));
reg [2:0] pm=0; reg ph=0,pv=0,pd=0; reg [9:0] pb=0,pe=0;
initial begin
 for(j=0;j<6;j=j+1) delayed_rgb[j]=0;
 repeat(4) @(negedge clk); rst=1;
end
always @(posedge clk) if(rst) begin
 delayed_de<={delayed_de[4:0],de}; delayed_rgb[0]<=rgb;
 for(j=1;j<6;j=j+1) delayed_rgb[j]<=delayed_rgb[j-1];
 if(tick) $display("S %0d",c);
 if(x==HT-1) begin x<=0; y<=y==VT-1?0:y+1; end else x<=x+1;
 #1;
 if(overflow) $fatal(1,"audio FIFO overflow");
 if(mode==3 || mode!=pm || oh!=ph || ov!=pv || od!=pd ||
    (mode==0 && (b!=pb || d!=pe)) || c<HT*3)
  $display("P %0d %0d %0d %0d %0d %06x %03x %03x %03x",c,mode,oh,ov,od,orgb,a,b,d);
 pm=mode; ph=oh; pv=ov; pd=od; pb=b; pe=d;
 c=c+1;
 if(c==2*HT*VT+32) $finish;
end
endmodule
'''

def check_profile(trace, p):
    ha,ht,va,vt,hs,hw,vs,vw,hz,vic,pol = p
    ticks=[]; group=[]; packets=[]; video=0; last_video=-2; rd=[0,0,0]
    frame=0; samples=0; muted=0; kinds=Counter(); events=[]
    def de_at(c):
        pos=(c-16)%(ht*vt)
        return pos%ht<ha and pos//ht<va
    for line in trace.open():
        v=line.split()
        if not v or v[0] not in ('P','S'): continue
        if v[0]=='S': ticks.append(int(v[1])); continue
        c,m,h,s,d=map(int,v[1:6]); rgb,a,b,e=(int(x,16) for x in v[6:])
        words=[a,b,e]
        if c>2*ht:
            xpos=(c-16)%ht
            source=(c-10)%(ht*vt); sx=source%ht; sy=source//ht
            assert h==int((hs<=sx<hs+hw)==bool(pol)),('HS polarity/width',c)
            assert s==int((vs<=sy<vs+vw)==bool(pol)),('VS polarity/width',c)
            assert d==int(de_at(c)),('DE width/production delay',c)
            vg=not d and any(de_at(c+k) for k in (1,2))
            vp=not d and not vg and any(de_at(c+k) for k in range(3,11))
            ip=ha+4<=xpos<ha+12
            ig=ha+12<=xpos<ha+14 or ha+142<=xpos<ha+144
            it=ha+14<=xpos<ha+142
            expected=1 if d else 2 if vg else 4 if ig else 3 if it else 0
            assert m==expected,('period placement',c,xpos,m,expected)
            if m==0: assert words==[CTRL[2*s+h],CTRL[int(vp or ip)],CTRL[int(ip)]],('preamble/control',c)
            if m==2: assert words==[0x2cc,0x133,0x2cc],('video guard',c)
            if m==4: assert words==[TERC[12+2*s+h],0x133,0x133],('island guard',c)
        if m==1:
            if c!=last_video+1: rd=[0,0,0]
            for channel,byte in enumerate((rgb&255,(rgb>>8)&255,rgb>>16)):
                expected,rd[channel]=tmds_reference(byte,rd[channel])
                assert words[channel]==expected,('TMDS video/running disparity',c,channel)
                assert abs(rd[channel])<=8
            last_video=c; video+=1
            pos=(c-16)%(ht*vt); x=pos%ht; y=pos//ht
            assert rgb==((x&255)<<16)|((y&255)<<8)|((x^y)&255)
        if m==3:
            nibs=[INV[w] for w in words]
            assert nibs[0]&3==2*s+h
            assert nibs[0]&8
            group.append(nibs)
            if len(group)==32:
                head=sum(((n[0]>>2)&1)<<i for i,n in enumerate(group))
                subs=[sum((((n[1]>>k)&1)<<(2*i))|(((n[2]>>k)&1)<<(2*i+1)) for i,n in enumerate(group)) for k in range(4)]
                assert bch_valid(head,32),('header BCH',c)
                assert all(bch_valid(sub,64) for sub in subs),('subpacket BCH',c)
                packets.append((c-31,head&0xffffff,[sub&((1<<56)-1) for sub in subs]))
                group=[]
        else: assert not group,'truncated packet'
        events.append((c,m))
    assert video>ha*2
    assert set(b-a for a,b in zip(ticks,ticks[1:]))=={hz//48000,(hz+47999)//48000}
    assert abs(len(ticks)-(2*ht*vt+32)*48000/hz)<1
    for c,header,subs in packets:
        kind=header&255; kinds[kind]+=1
        data=b''.join(sub.to_bytes(7,'little') for sub in subs)
        if kind==1:
            assert len(set(subs))==1
            cts=int.from_bytes(data[1:4],'big'); n=int.from_bytes(data[4:7],'big')
            assert (n,cts)==(6144,hz//1000)
            assert hz*n==48000*128*cts
        elif kind in (0x82,0x84):
            length=header>>16
            assert ((header&255)+((header>>8)&255)+length+sum(data[:length+1]))%256==0
            if kind==0x82:
                assert header==0x0d0282 and data[1:6]==bytes([0,8,8,vic,0])
                assert data[6:]==bytes(22)
            else:
                assert header==0x0a0184 and data[1:]==bytes([1]+[0]*26)
        elif kind==2:
            present=(header>>8)&15
            assert header&0x0ff000==0,'layout0/reserved bits'
            for k,sub in enumerate(subs):
                if not(present>>k)&1: assert sub==0; continue
                assert (header>>(20+k))&1==int(frame==0)
                left=sub&0xffffff; right=(sub>>24)&0xffffff; flags=sub>>48
                assert left==right and not flags&0x33
                for side,channel in [(0,1),(1,2)]:
                    status=(flags>>(4*side+2))&1
                    # Decode IEC fields using byte offsets, independent of the RTL constants.
                    status_bytes=bytes([4,0,channel<<4,2,11])+bytes(19)
                    assert status==(status_bytes[frame//8]>>(frame%8))&1
                    assert (left.bit_count()+status+((flags>>(4*side+3))&1))%2==0
                normal=(round(8192*math.sin(2*math.pi*(samples%48)/48))<<8)&0xffffff
                if c<ht*vt: assert left==normal,('tone before mute',samples)
                elif c>ht*vt+4*ht: assert left==0,('mute drains FIFO',c); muted+=1
                frame=(frame+1)%192; samples+=1
        else: raise AssertionError(('packet type',kind))
    assert all(kinds[k]>1000 for k in (1,2,0x82,0x84)),kinds
    assert 0<=len(ticks)-samples<=4 and muted>500
    print(f'PASS {ha}x{va} VIC={vic} f_pixel={hz}: {sum(kinds.values())} packets, {samples} stereo samples; 6-cycle production delay; HS={hw}/{ht} VS={vw}/{vt} polarity={pol}; exact 48k ACR; polynomial BCH; metadata/status/mute; guards/preambles; TMDS disparity')

def main():
    with TemporaryDirectory(prefix='hdmi-profile-audit-') as temporary:
        out=Path(temporary)
        rd=0; total=0
        for line in run_sim(out,'tb_channel',CHANNEL_TB).open():
            v=line.split()
            if not v or v[0] not in ('V','T','C'): continue
            if v[0]=='V':
                mode,data=int(v[1]),int(v[2]); word=int(v[3],16)
                if mode==1:
                    expected,rd=tmds_reference(data,rd)
                    assert word==expected,(total,data,word,expected,rd)
                    assert abs(rd)<=8
                else: assert word==CTRL[0]; rd=0
                total+=1
            else: assert int(v[2],16)==(TERC if v[0]=='T' else CTRL)[int(v[1])]
        assert total==20000
        print('PASS 20000 independent TMDS vectors/disparity resets; all TERC4/control symbols', flush=True)
        # Reuse the existing port stubs solely as interface models. Compare the
        # actual TD metadata clock connections, then check generic forwarding.
        metadata=(ROOT/'sim/hardware_reference_probe/DVI_serializer_public_pins.txt').read_text(encoding='utf-8')
        for bit in range(10):
            expected_net='_al_n1' if bit<5 else '_al_n0'
            assert f'Inst_clk_serializer_10_1.DP_I[{bit}] dir=0 is_mpin=0 net={expected_net} ' in metadata
        wrapper=(ROOT/'sim/hdmi_audio/tb_hdmi_wrapper.v').read_text(encoding='utf-8')
        wrapper=wrapper.replace('module tb_hdmi_wrapper;', 'module tb_profile_wrapper;')
        wrapper=wrapper.replace('#(.AUDIO_DI_EN(1)) audio', '#(.AUDIO_DI_EN(1),.H_ACTIVE(640),.H_TOTAL(800),.PIXEL_HZ(25200000),.VIDEO_ID(1)) audio')
        wrapper=wrapper.replace('  initial begin', '''  initial begin
   if(audio.g_hdmi_audio.u_encoder.PIXEL_HZ!=25200000 ||
      audio.g_hdmi_audio.u_encoder.VIDEO_ID!=1 ||
      audio.g_hdmi_audio.u_encoder.H_ACTIVE!=640 ||
      audio.g_hdmi_audio.u_encoder.H_TOTAL!=800) $fatal(1,"profile parameter forwarding");''')
        wrapper_trace=run_sim(out,'tb_profile_wrapper',wrapper).read_text()
        assert 'PASS wrapper routing' in wrapper_trace
        print('PASS wrapper profile forwarding, RGB888/RGB565/mute/legacy route; clock word agrees with original TD metadata', flush=True)
        if '--wrapper-only' in sys.argv:
            return
        for p in PROFILES:
            source=PROFILE_TB
            for key,value in zip(('HA','HT','VA','VT','HS','HW','VS','VW','PH','VIC','POL'),p):
                source=source.replace('@'+key+'@',str(value))
            check_profile(run_sim(out,'tb_profile',source),p)

if __name__=='__main__': main()
