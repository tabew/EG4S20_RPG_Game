"""Verify external held mono PCM from public parallel TMDS symbols.
Run: python tools/verify_hdmi_pcm.py [--decode-only]
Standalone decoder: TERC4 table, polynomial BCH division, IEC60958 status/parity,
signed24 payload, FIFO order through mute/resume, exact ACR and video/scanning.
No protected serializer timing or hardware behavior is claimed.
"""
from pathlib import Path
from collections import Counter
import json
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'sim/hdmi_audio/pcm_results'
IV = ROOT / 'tools/iverilog/bin/iverilog.exe'
VVP = ROOT / 'tools/iverilog/bin/vvp.exe'
RTL = ROOT / 'rtl/video/hdmi_tx.v'
TERC = [0x29c,0x263,0x2e4,0x2e2,0x171,0x11e,0x18e,0x13c,
        0x2cc,0x139,0x19c,0x2c6,0x28e,0x271,0x163,0x2c3]
INV = {word:n for n,word in enumerate(TERC)}
CTRL = [0x354,0xab,0x154,0x2ab]
PROFILES = [(640,800,480,525,656,96,490,2,25200000,1,0),
            (800,1056,600,628,840,128,601,4,40000000,0,1)]


def bch_valid(word, width):
    # Divide the transmitted LSB-first polynomial by x^8+x^7+x^6+1.
    polynomial = int(f'{word:0{width}b}'[::-1], 2)
    while polynomial.bit_length() > 8:
        polynomial ^= 0x1c1 << (polynomial.bit_length()-9)
    return polynomial == 0


def video_decode(word):
    qm = (word & 255) ^ (255 if word & 512 else 0)
    byte = qm & 1
    for bit in range(1, 8):
        value = ((qm >> bit) ^ (qm >> (bit-1))) & 1
        byte |= (value ^ int(not word & 256)) << bit
    return byte


def source_value(index):
    edges = [0,-32768,32767,-1,1,-7,256,-256]
    if index < len(edges):
        return edges[index]
    dac = ((index*73) ^ (index >> 2) ^ 0xb6) & 255
    return (dac-128)*64


def expected_capture(hz, end, mute_on, mute_off):
    # Independent external source model; NBA source update occurs AFTER capture.
    accumulator = index = pcm = 0
    result = []
    for cycle in range(end):
        if ((cycle+1)*48000)//hz != (cycle*48000)//hz:
            muted = int(mute_on <= cycle < mute_off)
            result.append((cycle, pcm, muted))
        rate = 22050 if end//2 <= cycle < 3*end//4 else 32000
        accumulator += rate
        if accumulator >= hz:
            accumulator -= hz
            index += 1
            pcm = source_value(index)
    return result


def decode(trace, profile):
    ha,ht,va,vt,hs,hw,vs,vw,hz,vic,pol = profile
    ticks = []; packets = []; group = []; video = 0
    config = None; simulation_pass = False
    for line in trace.open():
        fields = line.split()
        if not fields:
            continue
        if fields[0] == 'CONFIG':
            config = tuple(map(int, fields[1:])); continue
        if fields[0] == 'PASS':
            simulation_pass = True; continue
        if fields[0] == 'S':
            ticks.append(tuple(map(int, fields[1:]))); continue
        if fields[0] != 'P':
            continue
        c,m,h,v,d = map(int, fields[1:6])
        rgb,a,b,e = (int(value,16) for value in fields[6:])
        if c > 2*ht:
            sync_pos = (c-10) % (ht*vt)
            sx,sy = sync_pos % ht, sync_pos // ht
            assert h == int((hs <= sx < hs+hw) == bool(pol)), ('HS',c)
            assert v == int((vs <= sy < vs+vw) == bool(pol)), ('VS',c)
            def de_at(time):
                pos = (time-16) % (ht*vt)
                return pos % ht < ha and pos // ht < va
            assert d == int(de_at(c)), ('DE',c)
            xpos = (c-16) % ht
            guard = not d and any(de_at(c+k) for k in (1,2))
            preamble = not d and not guard and any(de_at(c+k) for k in range(3,11))
            ip = ha+4 <= xpos < ha+12
            ig = ha+12 <= xpos < ha+14 or ha+142 <= xpos < ha+144
            island = ha+14 <= xpos < ha+142
            expected_mode = 1 if d else 2 if guard else 4 if ig else 3 if island else 0
            assert m == expected_mode, ('period timing',c,m,expected_mode)
            if m == 0:
                assert [a,b,e] == [CTRL[2*v+h],CTRL[int(preamble or ip)],CTRL[int(ip)]], ('control/preamble',c)
            elif m == 2:
                assert [a,b,e] == [0x2cc,0x133,0x2cc], ('video guard',c)
            elif m == 4:
                assert [a,b,e] == [TERC[12+2*v+h],0x133,0x133], ('island guard',c)
        if m == 1:
            pos = (c-16) % (ht*vt); x,y = pos % ht,pos // ht
            expected_rgb = ((x&255)<<16) | ((y&255)<<8) | ((x^y)&255)
            decoded_rgb = (video_decode(e)<<16) | (video_decode(b)<<8) | video_decode(a)
            assert decoded_rgb == rgb == expected_rgb, ('RGB',c)
            video += 1
        if m == 3:
            n0,n1,n2 = (INV[word] for word in (a,b,e))
            assert n0 & 3 == 2*v+h and n0 & 8, ('island sync',c)
            group.append((n0,n1,n2))
            if len(group) == 32:
                header = sum(((n[0]>>2)&1)<<i for i,n in enumerate(group))
                subs = [sum((((n[1]>>k)&1)<<(2*i)) | (((n[2]>>k)&1)<<(2*i+1)) for i,n in enumerate(group)) for k in range(4)]
                assert bch_valid(header,32), ('header BCH',c)
                assert all(bch_valid(sub,64) for sub in subs), ('subpacket BCH',c)
                packets.append((c-31,header&0xffffff,[sub&((1<<56)-1) for sub in subs]))
                group = []
        else:
            assert not group, 'truncated packet'
    assert simulation_pass and config and not group
    assert config[0] == hz
    _,end,mute_on,mute_off = config
    assert ticks == expected_capture(hz,end,mute_on,mute_off), 'pre-edge external PCM/rate model'
    intervals = Counter(b[0]-a[0] for a,b in zip(ticks,ticks[1:]))
    assert set(intervals) == {hz//48000,(hz+47999)//48000}
    assert abs(len(ticks)-end*48000/hz) < 1
    expected = [0 if mute else pcm*256 for _,pcm,mute in ticks]
    count = frame = 0; kinds = Counter(); muted = resumed = queued_after_mute = 0
    signs = set(); signed_values = []; sample_cycles = []
    for c,header,subs in packets:
        kind = header & 255; kinds[kind] += 1
        data = b''.join(sub.to_bytes(7,'little') for sub in subs)
        if kind == 1:
            assert header == 1 and len(set(subs)) == 1
            cts = int.from_bytes(data[1:4],'big'); n = int.from_bytes(data[4:7],'big')
            assert (n,cts) == (6144,hz//1000) and hz*n == 48000*128*cts
        elif kind in (0x82,0x84):
            length = header >> 16
            assert ((header&255)+((header>>8)&255)+length+sum(data[:length+1])) % 256 == 0
            if kind == 0x82:
                assert header == 0x0d0282 and data[1:6] == bytes([0,8,8,vic,0]) and data[6:] == bytes(22)
            else:
                assert header == 0x0a0184 and data[1:] == bytes([1]+[0]*26)
        elif kind == 2:
            present = (header >> 8) & 15
            assert header & 0x0ff000 == 0
            for k,sub in enumerate(subs):
                if not (present >> k) & 1:
                    assert sub == 0; continue
                assert ((header >> (20+k)) & 1) == int(frame == 0)
                left = sub & 0xffffff; right = (sub >> 24) & 0xffffff; flags = sub >> 48
                assert left == right and left & 255 == 0 and flags & 0x33 == 0
                signed = left-(1<<24) if left & (1<<23) else left
                assert signed == expected[count], ('PCM FIFO order',count,c,signed,expected[count],ticks[count])
                for side,channel in ((0,1),(1,2)):
                    status = (flags >> (4*side+2)) & 1
                    status_bytes = bytes([4,0,channel<<4,2,11]) + bytes(19)
                    assert status == (status_bytes[frame//8] >> (frame%8)) & 1
                    parity = (flags >> (4*side+3)) & 1
                    assert (left.bit_count()+status+parity) % 2 == 0, ('IEC parity',count,channel)
                source_cycle,pcm,is_muted = ticks[count]
                if is_muted:
                    assert signed == 0; muted += 1
                elif source_cycle >= mute_off:
                    resumed += 1
                if c >= mute_on and source_cycle < mute_on:
                    queued_after_mute += 1
                signed_values.append(signed); sample_cycles.append(c)
                signs.add((signed > 0)-(signed < 0))
                count += 1; frame = (frame+1) % 192
        else:
            raise AssertionError(('unexpected packet',kind))
    assert all(kinds[k] > 1000 for k in (1,2,0x82,0x84)), kinds
    assert 0 <= len(ticks)-count <= 4
    assert video > 2*ha and muted > 300 and resumed > 300 and signs == {-1,0,1}
    assert queued_after_mute > 0, 'exercise PCM queued before mute and delivered afterward'
    assert {value*256 for value in (0,-32768,32767,-1,1,-7,256,-256)} <= set(signed_values)
    assert any(a[1] == b[1] and not a[2] for a,b in zip(ticks,ticks[1:])), 'held source samples'
    assert any(signed_values[i] != signed_values[i+48] for i in range(count-48) if ticks[i][0] >= mute_off), 'resumed external PCM is not 1kHz tone'
    result = dict(pixel_hz=hz,video_id=vic,packets=sum(kinds.values()),stereo_samples=count,
                  captures=len(ticks),intervals=dict(intervals),muted_samples=muted,resumed_samples=resumed,
                  queued_before_mute_delivered_after=queued_after_mute,decoded_video_pixels=video,
                  overflow=0,every_cycle_video_and_scan_equal=True)
    print('PASS PCM',json.dumps(result),flush=True)
    return result


def simulate(name, top, benches, defines=()):
    exe = OUT / (name+'.vvp')
    subprocess.run([str(IV),'-g2012','-s',top,*defines,'-o',str(exe),str(RTL),
                    *(str(ROOT / bench) for bench in benches)],cwd=ROOT,check=True)
    trace = OUT / (name+'.txt')
    with trace.open('w',encoding='utf-8') as stream:
        subprocess.run([str(VVP),str(exe)],cwd=ROOT,stdout=stream,check=True)
    return trace


def main():
    OUT.mkdir(exist_ok=True)
    if '--decode-only' not in sys.argv:
        wrapper = simulate('wrapper','tb_hdmi_pcm_wrapper',[
            'sim/hdmi_audio/tb_hdmi_wrapper.v','sim/hdmi_audio/tb_hdmi_pcm_wrapper.v'])
        assert 'PASS PCM wrapper' in wrapper.read_text()
        print(wrapper.read_text().strip(),flush=True)
    results = []
    for profile in PROFILES:
        name = f'pcm_{profile[8]}'
        trace = OUT / (name+'.txt')
        if '--decode-only' not in sys.argv:
            trace = simulate(name,'tb_hdmi_pcm',['sim/hdmi_audio/tb_hdmi_pcm.v'],
                             ['-DPROFILE40'] if profile[8] == 40000000 else [])
        results.append(decode(trace,profile))
    (OUT / 'verification.json').write_text(json.dumps(results,indent=2)+'\n',encoding='utf-8')
    print('PASS external PCM signed24/BCH/TERC4/IEC60958/parity/ACR/metadata/FIFO mute-resume/video at both profiles',flush=True)


if __name__ == '__main__':
    main()
