# -*- coding: utf-8 -*-
"""解析百度网盘分享页, 尝试拿到 uk / dlink / 直链"""
import re, json, subprocess, sys

BASE = r'D:\EG4S20_RPG_Game-main\docs'
h = open(BASE + r'\page.html', encoding='utf-8', errors='replace').read()

# 1) 宽松找 uk
pats = [r'"uk"\s*:\s*"?(\d{5,})', r"'uk'\s*[:=]\s*(\d{5,})", r'\buk\s*[:=]\s*[\d"]{5,}',
        r'uk=(\d{5,})', r'"pu"\s*:\s*"?(\d{5,})']
found = set()
for p in pats:
    for m in re.finditer(p, h):
        found.add(m.group(1))
print('uk candidates:', list(found)[:10])

# 2) 找 dlink / pcs 直链
print('pcs urls:', re.findall(r'pcs\.data\.baidu\.com[^"\x27\s\\]+', h)[:3])
print('dlink field:', re.findall(r'dlink', h)[:3])

# 3) 找其它可用的接口线索: sekey/BDCLND 已有; 再看 page 里 shareid 上下文
m = re.search(r'.{60}shareid.{60}', h)
if m: print('shareid ctx:', m.group(0)[:140])
