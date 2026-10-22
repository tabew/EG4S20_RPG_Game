# -*- coding: utf-8 -*-
"""
check_sim.py —— 把 yosys 仿真重建的屏幕, 和 Python 参考渲染器逐格比对

    python tools/check_sim.py

两者用的是同一套字模和同一条"界面指令", 只是执行器不同:
  * 参考渲染器: tools/build_rom.py 里的 draw_ops(Python)
  * 仿真结果:   rtl/ctrl/rpg_core.v 的指令解释器(Verilog)
对不上就说明 RTL 有 bug。
"""
import os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)

import build_rom as B          # 复用字模/指令表/参考渲染器

COLS, ROWS = 40, 30
VCD = os.path.join(ROOT, "sim", "core.vcd")

# 仿真时寄存器的实际取值(和 tb_core 的复位初值一致)
SIM_VALUES = {
    0: 130, 1: 130, 2: 40, 3: 40, 4: 13, 5: 9, 6: 40,
    7: 1, 8: 0, 9: 24, 10: 2, 11: 0, 12: 0,
    13: 36, 14: 36, 15: 0,
}

# (截屏时间, 界面名, 敌人id, 区域id)
CHECKS = [
    (45000,  "title",  0, 0),
    (140000, "class",  0, 0),
    (240000, "map",    0, 0),
]


def toint(v, default=0):
    if v is None:
        return default
    v = v.replace("x", "0").replace("z", "0").replace("X", "0").replace("Z", "0")
    try:
        return int(v, 2)
    except ValueError:
        return default


def vcd_screens(path):
    """按时间戳批量回放 we/waddr/wdata, 在 CHECKS 时刻截屏"""
    want_names = ["o_we", "o_waddr", "o_wdata", "o_cyc", "o_scene"]
    rev = {}
    cur = {}
    screen = {}
    snaps = []
    checks = [c[0] for c in CHECKS]
    last_cyc = [None]

    def flush():
        cyc = cur.get("o_cyc")
        if cyc == last_cyc[0]:
            return
        last_cyc[0] = cyc
        if cur.get("o_we") == "1":
            a = toint(cur.get("o_waddr"), -1)
            d = toint(cur.get("o_wdata"))
            if 0 <= a < COLS * ROWS:
                screen[a] = d

    with open(path, "r", encoding="utf-8", errors="replace") as f:
        in_def = True
        for line in f:
            line = line.strip()
            if in_def:
                m = re.match(r"\$var\s+\S+\s+(\d+)\s+(\S+)\s+(\S+)", line)
                if m and m.group(3) in want_names:
                    rev[m.group(2)] = m.group(3)     # code -> name
                if "$enddefinitions" in line:
                    in_def = False
                    break
        need = set(rev.keys())                        # VCD 里用的是 code
        t = 0
        for line in f:
            if not line:
                continue
            c0 = line[0]
            if c0 == "#":
                flush()
                while checks and t >= checks[0]:
                    snaps.append((checks.pop(0), dict(screen)))
                t = int(line[1:])
                continue
            if c0 == "b":
                p = line[1:].split()
                if len(p) == 2 and p[1] in need:
                    cur[rev[p[1]]] = p[0]
            elif c0 in "01xzXZ":
                if line[1:] in need:
                    cur[rev[line[1:]]] = line[0]
    flush()
    while checks:
        snaps.append((checks.pop(0), dict(screen)))
    return snaps


def mask_of(grid):
    """整格内容: {bg,fg,glyph} 打包成 16bit, 逐格全比对"""
    out = []
    for y in range(ROWS):
        for x in range(COLS):
            code, fg, bg = grid[y][x]
            out.append(((bg & 0xF) << 12) | ((fg & 0xF) << 8) | (code & 0xFF))
    return out


def main():
    # 参考渲染器用和仿真一致的数值
    B.SAMPLE = dict(SIM_VALUES)
    B.SAMPLE_ID = dict(SIM_VALUES)

    snaps = dict(vcd_screens(VCD))
    print("=" * 70)
    print("RTL 仿真 vs Python 参考渲染器  逐格比对")
    print("=" * 70)

    all_ok = True
    for t, name, eid, aid in CHECKS:
        grid = B.draw_ops(B.SCREENS[name], enemy_id=eid, area_id=aid,
                          dyn_sprite=eid, msg_text="你发起攻击")
        ref = mask_of(grid)
        sim = [snaps[t].get(y * COLS + x, 0) & 0xFFFF
               for y in range(ROWS) for x in range(COLS)]
        diff = [(i % COLS, i // COLS) for i in range(COLS * ROWS) if ref[i] != sim[i]]
        status = "逐格一致" if not diff else "不一致 %d 格" % len(diff)
        nz = sum(1 for v in ref if (v & 0xFF) != 0)
        print("  %-8s @t=%-7d  非空格 %3d   %s" % (name, t, nz, status))
        if diff:
            all_ok = False
            for x, y in diff[:12]:
                print("       差异格 (%d,%d) ref=0x%04X sim=0x%04X" %
                      (x, y, ref[y * COLS + x], sim[y * COLS + x]))
    print("-" * 70)
    print("结果:", "全部一致 ✓" if all_ok else "存在差异 ✗")
    return 0 if all_ok else 1


if __name__ == "__main__":
    sys.exit(main())
