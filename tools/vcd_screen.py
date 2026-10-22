# -*- coding: utf-8 -*-
"""
vcd_screen.py —— 解析 yosys sim 导出的 VCD, 重建 FPGA 实际渲染的字符屏

    python tools/vcd_screen.py sim/core.vcd

原理: rpg_core 的 we/waddr/wdata 三根线就是"写格子"的全部信息。
      按时间顺序回放这些写操作, 就得到 40x30 的屏幕内容。
      在指定周期处截屏, 打成文本, 可以和 preview/*.png 直接对照。
"""
import sys, re

COLS, ROWS = 40, 30
CHECKPOINTS = [45000, 140000, 240000]


def parse_vcd(path):
    """按时间戳批量回放: 每个时间戳处理完所有变化后, 若 we==1 记一次写。

    注意 VCD 只记"变化": we 在清屏时一直为高, 只会出现一次 0->1,
    所以不能只在 we 上升沿记写, 必须按周期(时间戳)批量采样。"""
    ids = {}          # code -> name
    names_want = ["o_we", "o_waddr", "o_wdata", "o_scene", "o_hp", "o_maxhp",
                  "o_atk", "o_def", "o_gold", "o_lv", "o_cyc"]
    rev = {}
    cur = {}

    t = 0
    screen = {}
    snaps = []
    writes = 0

    last_cyc = [None]

    def flush_stamp():
        nonlocal writes
        cyc = cur.get("o_cyc")
        if cyc == last_cyc[0]:
            return          # 同一周期的第二个时间戳(时钟边沿), 不重复计
        last_cyc[0] = cyc
        if cur.get("o_we") == "1":
            a = toint(cur.get("o_waddr"), -1)
            d = toint(cur.get("o_wdata"))
            if 0 <= a < COLS * ROWS:
                screen[a] = d
                writes += 1

    with open(path, "r", encoding="utf-8", errors="replace") as f:
        in_def = True
        for line in f:
            line = line.strip()
            if in_def:
                m = re.match(r"\$var\s+\S+\s+(\d+)\s+(\S+)\s+(\S+)", line)
                if m:
                    width, code, name = int(m.group(1)), m.group(2), m.group(3)
                    if name in names_want:
                        ids[code] = name
                        rev[name] = code
                if "$enddefinitions" in line:
                    in_def = False
                    break

        need = set(rev.values())
        for line in f:
            if not line:
                continue
            c0 = line[0]
            if c0 == "#":
                # 上一个时间戳的值已全部处理完 -> 记一次写
                flush_stamp()
                while CHECKPOINTS and t >= CHECKPOINTS[0]:
                    snaps.append((CHECKPOINTS.pop(0), dict(screen), dict(cur), writes))
                t = int(line[1:])
                continue
            if c0 == "b":
                parts = line[1:].split()
                if len(parts) != 2:
                    continue
                val, code = parts
                if code in need:
                    cur[ids[code]] = val
            elif c0 in "01xzXZ":
                code = line[1:]
                if code in need:
                    cur[ids[code]] = line[0]

    flush_stamp()
    while CHECKPOINTS:
        snaps.append((CHECKPOINTS.pop(0), dict(screen), dict(cur), writes))
    return snaps


def toint(v, default=0):
    """VCD 里可能有 x/z, 一律按 0 处理"""
    if v is None:
        return default
    v = v.replace("x", "0").replace("z", "0").replace("X", "0").replace("Z", "0")
    try:
        return int(v, 2)
    except ValueError:
        return default


def show(t, screen, cur, writes=0):
    print("=" * 74)
    print("截屏 @ 时间 %d (累计写 %d 次)   scene=%d  hp=%d/%d  atk=%d def=%d gold=%d lv=%d" % (
        t, writes, toint(cur.get("o_scene")), toint(cur.get("o_hp")), toint(cur.get("o_maxhp")),
        toint(cur.get("o_atk")), toint(cur.get("o_def")), toint(cur.get("o_gold")),
        toint(cur.get("o_lv"))))
    print("=" * 74)
    nz = 0
    for y in range(ROWS):
        row = ""
        for x in range(COLS):
            g = screen.get(y * COLS + x, 0) & 0xFF
            row += "#" if g != 0 else "."
            if g != 0:
                nz += 1
        print(row)
    print("非空格子数: %d\n" % nz)


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else "sim/core.vcd"
    snaps = parse_vcd(path)
    for t, scr, cur, w in snaps:
        show(t, scr, cur, w)


if __name__ == "__main__":
    main()
