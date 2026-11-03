#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
design_spec2.py —— 最终方案验证: 前置低通 + 8 段带通 + 快速平均 + 峰值保持

结构 (每段只占 1 个 12 位乘法器, 8 段共 8 个, 前置低通不用乘法器):
    PCM -> 前置低通 x4 (c=906/4096, fc=1273Hz) 把方波磨成正弦
        -> seg i: 一阶 HP(f_lo) -> 一阶 LP(f_hi)          [带通]
        -> fast = fast + (|y|-fast)>>5                     [1ms 平均, 吃掉方波边沿]
        -> env  = max(fast, env - ((env>>13)+1))           [峰值保持 + 慢落]
        -> bar  = sat(env * gain_i * 2, 120)

用法: python design_spec2.py
"""

import math
import os

FS = 32000
EDGES = [150, 198, 262, 346, 457, 603, 797, 1053, 1391]
PRE_FC = 1273.0
PRE_ST = 4
Q = 4096

HERE = os.path.dirname(os.path.abspath(__file__))
GEN = os.path.join(os.path.dirname(HERE), 'rtl', 'gen')


def lp_c(fc):
    return 1.0 - math.exp(-2 * math.pi * fc / FS)


def hp_a(fc):
    return math.exp(-2 * math.pi * fc / FS)


C_PRE = round(lp_c(PRE_FC) * Q) / Q
A_HP = [round(hp_a(f) * Q) / Q for f in EDGES[:-1]]
C_LP = [round(lp_c(f) * Q) / Q for f in EDGES[1:]]
FAST_C = 1.0 / 32
DEC_SH = 13


class Spec:
    def __init__(self, gain=None, scale=1.0):
        self.pre = [0.0] * PRE_ST
        self.hpv = [0.0] * 8
        self.xp = [0.0] * 8
        self.lpv = [0.0] * 8
        self.fast = [0.0] * 8
        self.env = [0.0] * 8
        self.gain = gain or [1.0] * 8
        self.scale = scale
        self.energy = [0.0] * 8

    def step(self, x):
        for i in range(PRE_ST):
            self.pre[i] += (x - self.pre[i]) * C_PRE
        xs = self.pre[-1]

        for i in range(8):
            t = self.hpv[i] + xs - self.xp[i]
            y = t * A_HP[i]
            self.hpv[i] = y
            self.xp[i] = xs
            lo = self.lpv[i] + (y - self.lpv[i]) * C_LP[i]
            self.lpv[i] = lo

            a = abs(lo)
            f = self.fast[i] + (a - self.fast[i]) * FAST_C
            self.fast[i] = f
            self.energy[i] += (a - self.energy[i]) * 1e-4
            if f > self.env[i]:
                self.env[i] = f
            else:
                d = (self.env[i] / (1 << DEC_SH)) + 1.0
                self.env[i] = max(0.0, self.env[i] - d)

        return [min(120, int(self.env[i] * self.gain[i] * self.scale)) for i in range(8)]


def tone(freq, n, wave='sq', amp=52):
    ph = 0.0
    out = []
    for _ in range(n):
        ph += 2 * math.pi * freq / FS
        out.append(int(round(amp * math.sin(ph))) if wave == 'sin'
                   else (amp if math.sin(ph) >= 0 else -amp))
    return out


def load_rom():
    with open(os.path.join(GEN, 'pitch.hex')) as f:
        pitch = [int(l.strip(), 16) for l in f if l.strip()]
    with open(os.path.join(GEN, 'music.hex')) as f:
        mus = [int(l.strip(), 16) for l in f if l.strip()]
    return pitch, mus


def bgm_track(track, seconds):
    pitch, mus = load_rom()
    base = track * 64
    btk = 4000
    si = base
    row = mus[si]
    n0, n1, n2 = row & 0x7F, (row >> 7) & 0x7F, (row >> 14) & 0x7F
    mdur = max(1, (row >> 21) & 0x7F)
    ph0 = ph1 = ph2 = 0
    e0 = e1 = e2 = 0
    dprev = 128
    acc = 0
    pcm, info = [], []
    for k in range(int(FS * seconds)):
        newnote = False
        if k > 0 and acc >= btk:
            acc -= btk
            mdur -= 1
            if mdur <= 0:
                si = base if (si - base) >= 63 else si + 1
                row = mus[si]
                n0, n1, n2 = row & 0x7F, (row >> 7) & 0x7F, (row >> 14) & 0x7F
                mdur = max(1, (row >> 21) & 0x7F)
                newnote = True
        acc += 1
        if k == 0 or newnote:
            e0 = e1 = e2 = 0x3FFFF
        else:
            e0 -= (e0 >> 14) + 1
            e1 -= (e1 >> 14) + 1
            e2 -= (e2 >> 14) + 1
        s0 = 52 if ph0 >= (1 << 23) else -52
        s1 = 28 if (ph1 >> 22) == 0 else -28
        tri = (~(ph2 >> 17) & 0x3F) if ph2 >= (1 << 23) else ((ph2 >> 17) & 0x3F)
        s2 = tri - 32
        v = (((s0 * ((e0 >> 10) & 0xFF)) >> 8) +
             ((s1 * ((e1 >> 10) & 0xFF)) >> 8) +
             ((s2 * ((e2 >> 10) & 0xFF)) >> 8))
        v = max(-120, min(120, v))
        dout = (v + 128) & 0xFF
        dac = (dout + dprev) >> 1
        dprev = dout
        pcm.append(dac - 128)
        info.append((n0, n1, n2))
        ph0 = (ph0 + (pitch[n0] if n0 != 0x7F else 0)) & 0xFFFFFF
        ph1 = (ph1 + (pitch[n1] if n1 != 0x7F else 0)) & 0xFFFFFF
        ph2 = (ph2 + (pitch[n2] if n2 != 0x7F else 0)) & 0xFFFFFF
    return pcm, info


def midi_hz(n):
    return 0 if n == 0x7F else 440.0 * (2.0 ** ((n - 69) / 12.0))


def main():
    print('=' * 76)
    print('系数 (12 位定点)')
    print('=' * 76)
    print('  前置低通 x%d: c = %d / 4096' % (PRE_ST, round(C_PRE * Q)))
    print('  seg |  HP a_q |  LP c_q')
    for i in range(8):
        print('   %d  | %6d | %6d   (%.0f~%.0f Hz)'
              % (i, round(A_HP[i] * Q), round(C_LP[i] * Q), EDGES[i], EDGES[i + 1]))

    # ---- 第一遍: 测各段平均能量, 定增益 ----
    pcm, info = bgm_track(0, 10.0)
    sp = Spec()
    for s in pcm:
        sp.step(s)
    e = sp.energy
    tgt = 42.0
    gain = [tgt / max(v, 1e-6) for v in e]
    gmax = max(gain)
    gain = [g / gmax for g in gain]
    print('\n  各段平均幅度: ' + ' '.join('%.1f' % v for v in e))
    print('  归一化增益  : ' + ' '.join('%.2f' % v for v in gain))

    # ---- 单音扫描 ----
    print()
    print('=' * 76)
    print('A. 单音扫描 (方波): 峰值段必须随频率单调右移')
    print('=' * 76)
    print('   %6s |' % 'freq', end='')
    for i in range(8):
        print('%4d' % i, end='')
    print('  | 峰值')
    print('   ' + '-' * 52)
    ok = True
    prev = -1
    for f in (150, 200, 260, 340, 450, 600, 800, 1050, 1400):
        sp = Spec(gain, scale=6.0)
        for s in tone(f, 12000, 'sq'):
            b = sp.step(s)
        pk = b.index(max(b))
        if pk < prev:
            ok = False
        prev = pk
        print('   %6d |' % f, end='')
        for h in b:
            print('%4d' % h, end='')
        print('  | seg%d' % pk)
    print('   单调性: %s' % ('通过' if ok else '不通过'))

    # ---- 真实 BGM ----
    print()
    print('=' * 76)
    print('B. 真实 BGM (轨 0): 每 0.25s 柱高 / 当拍旋律')
    print('=' * 76)
    sp = Spec(gain, scale=6.0)
    hist = []
    for s in pcm:
        hist.append(sp.step(s))
    print('   %6s %7s |' % ('时间', '旋律'), end='')
    for i in range(8):
        print('%4d' % i, end='')
    print('  | 峰值')
    print('   ' + '-' * 58)
    for k in range(0, len(hist), 4000):
        n0 = info[k][0]
        lab = '%dhz' % midi_hz(n0) if n0 != 0x7F else '--'
        print('   %5.2fs %7s |' % (k / float(FS), lab), end='')
        for h in hist[k]:
            print('%4d' % h, end='')
        print('  | seg%d' % hist[k].index(max(hist[k])))

    # ---- 同步性 ----
    print()
    print('=' * 76)
    print('C. 同步性 (改造前 91%)')
    print('=' * 76)
    tail = hist[len(hist) // 2:]
    for i in range(8):
        col = [r[i] for r in tail]
        print('   seg%d  最小 %3d  最大 %3d  平均 %5.1f' % (i, min(col), max(col), sum(col) / float(len(col))))
    same = tot = 0
    for a, b in zip(tail, tail[1:]):
        dd = [b[i] - a[i] for i in range(8)]
        nz = [x for x in dd if x != 0]
        if len(nz) >= 4:
            tot += 1
            pos = sum(1 for x in nz if x > 0)
            if pos >= len(nz) * 0.75 or pos <= len(nz) * 0.25:
                same += 1
    print('\n   同方向摆动占比: %.0f%%' % (100.0 * same / max(1, tot)))

    lo = [(midi_hz(info[k][0]), hist[k].index(max(hist[k])))
          for k in range(0, len(hist), 2000) if info[k][0] != 0x7F]
    l = [p[1] for p in lo if p[0] < 700]
    h = [p[1] for p in lo if p[0] >= 700]
    if l and h:
        print('   低音(<700Hz) 平均峰值段 %.2f   高音(>=700Hz) 平均峰值段 %.2f'
              % (sum(l) / float(len(l)), sum(h) / float(len(h))))


if __name__ == '__main__':
    main()
