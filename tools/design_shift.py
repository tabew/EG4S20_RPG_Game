# -*- coding: utf-8 -*-
"""为 9 个滤波系数寻找"移位相加"表示, 并验证精度

  高通: hp = t - t*k       k = 1 - exp(-2*pi*fc/fs)   都是小量, 好近似
  低通: l  = l + (x-l)*c   c = k
  只要能写成 sum(±2^-i) 就只用移位和加减, 不占 DSP。
"""
import math
import itertools

FS = 32000
EDGES = [150, 198, 262, 346, 457, 603, 797, 1053, 1391]
K = [1.0 - math.exp(-2 * math.pi * f / FS) for f in EDGES]


def best_approx(target, max_terms=3, lo=1, hi=13):
    """在所有 ±2^-i 组合里找最接近 target 的"""
    cands = [(i, math.ldexp(1.0, -i)) for i in range(lo, hi + 1)]
    best = None
    for n in range(1, max_terms + 1):
        for combo in itertools.combinations(cands, n):
            for signs in itertools.product((1, -1), repeat=n):
                v = sum(0.0 for _ in ())
                v = sum(s * w for s, (i, w) in zip(signs, combo))
                if v <= 0:
                    continue
                err = abs(v / target - 1.0)
                if best is None or err < best[0]:
                    best = (err, v, [(s, i) for s, (i, w) in zip(signs, combo)])
        if best and best[0] < 0.02:
            break
    return best


print("%6s %10s  %-42s %8s %8s" % ("fc", "目标 k", "移位表示", "近似值", "误差"))
print("-" * 84)
terms_all = []
for f, k in zip(EDGES, K):
    err, val, terms = best_approx(k, max_terms=3)
    expr = " ".join("%s2^-%d" % ("+" if s > 0 else "-", i) for s, i in terms)
    print("%6d %10.5f  %-42s %8.5f %7.2f%%" % (f, k, expr, val, 100 * err))
    terms_all.append(terms)

# 验证: 用近似系数重算滤波器的实际 -3dB 点偏移
print("\n=== 实际截止频率偏移 (近似 vs 精确) ===")


def hz_from_k(k):
    return -math.log(1.0 - k) * FS / (2 * math.pi)


for f, k, terms in zip(EDGES, K, terms_all):
    ka = sum(s * math.ldexp(1.0, -i) for s, i in terms)
    print("  标称 %4dHz -> 实际 %6.1fHz  (偏 %+.2f%%)"
          % (f, hz_from_k(ka), 100 * (hz_from_k(ka) / f - 1)))
