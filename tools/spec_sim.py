# -*- coding: utf-8 -*-
"""离线仿真: 16 位音符包络 + 8 段带通, 验证柱高是否真的跳动

跑法: python spec_sim.py
"""
import math
FS = 32000.0
BPM = 120
BTK = int(FS * 60 / (BPM * 4))
rows = [int(l.strip(), 16) for l in open('../rtl/gen/music.hex') if l.strip()]
pitch = [int(l.strip(), 16) for l in open('../rtl/gen/pitch.hex') if l.strip()]


def gen(track, seconds, dec=13, sfx=False):
    seg = rows[track * 64:(track + 1) * 64]
    seq = [((r & 0x7F), (r >> 7) & 0x7F, (r >> 14) & 0x7F, max(1, (r >> 21) & 0x7F)) for r in seg]
    total = int(seconds * FS)
    si = 0
    left = seq[0][3]
    n0, n1, n2 = seq[0][0], seq[0][1], seq[0][2]
    ph0 = ph1 = ph2 = 0
    beat = 0
    out = []
    e0 = e1 = e2 = 65535
    for n in range(total):
        nn = False
        if beat >= BTK:
            beat -= BTK
            left -= 1
            if left <= 0:
                si = (si + 1) % 64
                n0, n1, n2, d = seq[si]
                left = d
                nn = True
        beat += 1
        if nn:
            e0 = e1 = e2 = 65535
        else:
            e0 = e0 - (e0 >> dec)
            e1 = e1 - (e1 >> dec)
            e2 = e2 - (e2 >> dec)
        g0 = e0 >> 8
        g1 = e1 >> 8
        g2 = e2 >> 8
        s0 = (40 * g0) >> 8 if ph0 >= 1 << 23 else -((40 * g0) >> 8)
        s1 = (22 * g1) >> 8 if (ph1 >> 22) == 0 else -((22 * g1) >> 8)
        tv = ((~((ph2 >> 17) & 0x3F)) & 0x3F) if ph2 >= 1 << 23 else ((ph2 >> 17) & 0x3F)
        s2 = ((tv - 32) * g2) >> 8
        ph0 = (ph0 + (0 if n0 == 0x7F else pitch[n0])) % (1 << 24)
        ph1 = (ph1 + (0 if n1 == 0x7F else pitch[n1])) % (1 << 24)
        ph2 = (ph2 + (0 if n2 == 0x7F else pitch[n2])) % (1 << 24)
        mix = max(-120, min(120, s0 + s1 + s2))
        if sfx and (n // 4000) % 3 == 0 and n % 4000 < 800:
            mix = max(-120, min(120, mix + (56 if (n // 8) % 2 else -56)))
        out.append(mix)
    return out


SEG = [(6, 5), (5, 4), (4, 3), (3, 2), (2, 1), (1, None), (0, 1), (0, 0)]


def band2(x, kh, kl):
    y = []
    h1 = h2 = xp = l1 = l2 = 0
    for s in x:
        if kh == 0:
            a = s - xp
        else:
            t = h1 + s - xp
            a = t - (t >> kh)
        t2 = h2 + a - h1
        b = (t2 - (t2 >> kh)) if kh else a
        if kl is None:
            c = d = b
        else:
            c = b if kl == 0 else l1 + ((b - l1) >> kl)
            d = c if kl == 0 else l2 + ((c - l2) >> kl)
        h1, h2, xp, l1, l2 = a, b, s, c, d
        y.append(d)
    return y


def env_of(y, dec=9, gain=6):
    """与 RTL 一致: 内部 16 位定点, 避免小数值右移后卡死"""
    e = []
    cur = 0
    for v in y:
        a = abs(v) << gain
        cur = a if a > cur else cur - (cur >> dec)
        e.append(cur >> gain)
    return e


if __name__ == '__main__':
    for dec in (12, 13, 14):
        x = gen(0, 6.0, dec, True)
        cs = [env_of(band2(x, kh, kl)) for kh, kl in SEG]
        print("=== dec=%d  rms=%.1f (无包络基线 50.9)" % (dec, math.sqrt(sum(v * v for v in x) / len(x))))
        for i, e in enumerate(cs):
            mu = math.sqrt(sum(v * v for v in e) / len(e))
            sd = math.sqrt(sum((v - mu) ** 2 for v in e) / len(e))
            print("   seg%d max=%5.0f avg=%5.1f cv=%.2f" % (i, max(e), mu, sd / max(mu, 1e-9)))
        print("   柱高曲线(每50ms, x1.6 上限127):")
        for t in range(0, 6000, 160):
            print("    %4dms " % (t // 32) + " ".join("%3d" % int(min(127, cs[i][t] * 1.6)) for i in range(8)))
        print()
