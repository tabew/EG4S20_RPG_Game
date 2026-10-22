# -*- coding: utf-8 -*-
"""从 VCD 还原一帧, 和参考渲染器逐像素比对, 并搜索最佳偏移"""
import re, sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
VCD = "sim/video.vcd"; W, H = 640, 480

def toint(v, d=0):
    if v is None: return d
    v = v.replace("x","0").replace("z","0").replace("X","0").replace("Z","0")
    try: return int(v, 2)
    except ValueError: return d

want={"o_de","o_rgb","o_cyc","clk"}; ids={}; cur={}; last=[None]
px=py=0; sim=bytearray(W*H); done=[False]
clk_prev=[None]
def flush():
    """只在时钟上升沿采样: 每个周期正好一个像素, 不会多采/漏采"""
    global px,py
    if done[0]: return
    ck = cur.get("clk")
    rising = (clk_prev[0] == "0" and ck == "1")
    clk_prev[0] = ck
    if not rising: return
    if cur.get("o_de") != "1": return
    sim[py*W+px] = 1 if toint(cur.get("o_rgb")) else 0
    px+=1
    if px==W:
        px=0; py+=1
        if py==H: done[0]=True
with open(VCD, encoding="utf-8", errors="replace") as f:
    d=True
    for line in f:
        line=line.strip()
        if d:
            m=re.match(r"\$var\s+\S+\s+(\d+)\s+(\S+)\s+(\S+)", line)
            if m and m.group(3) in want: ids[m.group(2)]=m.group(3)
            if "$enddefinitions" in line: d=False; break
    need=set(ids)
    for line in f:
        if not line: continue
        if line[0]=="#":
            flush()
            if done[0]: break
        elif line[0]=="b":
            p=line[1:].split()
            if len(p)==2 and p[1] in need: cur[ids[p[1]]]=p[0]
print("仿真帧点亮:", sum(sim), " 完成:", done[0])

import build_rom as B
B.SAMPLE = {0:130,1:130,2:40,3:40,4:13,5:9,6:40,7:1,8:0,9:24,10:2,11:0,12:0,13:36,14:36,15:0}
B.SAMPLE_ID = dict(B.SAMPLE)
grid = B.draw_ops(B.SCREENS['title'])
ref = bytearray(W*H)
for cy in range(30):
    for cx in range(40):
        code, fg, bg = grid[cy][cx]
        bits = B.ROWS_OF[B.CODES[code]]
        for ry in range(16):
            r = bits[ry]
            if r:
                for rx in range(16):
                    if (r >> (15-rx)) & 1:
                        ref[(cy*16+ry)*W + cx*16+rx] = 1
print("参考帧点亮:", sum(ref))

best=None
for dy in range(-4,5):
    for dx in range(-4,5):
        err=0
        for y in range(0,H,2):
            yy=y+dy
            if yy<0 or yy>=H: continue
            base=yy*W; rbase=y*W
            for x in range(0,W,2):
                xx=x+dx
                if 0<=xx<W and sim[base+xx]!=ref[rbase+x]: err+=1
        if best is None or err<best[0]: best=(err,dy,dx)
print("最佳对齐 误差=%d dy=%d dx=%d (误差 0 即完全一致)"%best)

# 打印最佳偏移下的差异位置前 10 个
err,dy,dx=best
bad=[]
for y in range(H):
    yy=y+dy
    if yy<0 or yy>=H: continue
    for x in range(W):
        xx=x+dx
        if 0<=xx<W and sim[yy*W+xx]!=ref[y*W+x]:
            bad.append((x,y))
print("差异像素数:", len(bad), " 前 10:", bad[:10])
