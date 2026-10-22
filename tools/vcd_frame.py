# -*- coding: utf-8 -*-
"""
vcd_frame.py —— 从视频仿真导出的 VCD 里还原一整帧 640x480, 存成 PNG

    python tools/vcd_frame.py

做法: 视频时序里 de(数据有效) 为高的时钟就是有效像素。
      按 de 逐点采样 o_rgb, 数满 640x480 就得到一帧。
      RGB565 转 RGB888 后写 PNG(用 zlib 手写, 不依赖 PIL)。
"""
import os, re, struct, sys, zlib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
VCD = os.path.join(ROOT, "sim", "video.vcd")
OUT = os.path.join(ROOT, "preview", "sim_frame.png")
W, H = 640, 480


def toint(v, default=0):
    if v is None:
        return default
    v = v.replace("x", "0").replace("z", "0").replace("X", "0").replace("Z", "0")
    try:
        return int(v, 2)
    except ValueError:
        return default


def main():
    if not os.path.exists(VCD):
        print("找不到", VCD, "\n先跑: yosys -s sim/run_video.ys")
        return 1

    want = {"o_de", "o_rgb", "clk"}
    ids = {}
    px = py = 0
    frame = bytearray(W * H * 3)
    cur = {}
    last_cyc = [None]
    got = 0
    done = False

    def flush():
        """只在时钟上升沿采样: 每周期正好一个像素, 不多采不漏采"""
        nonlocal px, py, got, done
        if done:
            return
        ck = cur.get("clk")
        rising = (last_cyc[0] == "0" and ck == "1")
        last_cyc[0] = ck
        if not rising:
            return
        if cur.get("o_de") != "1":
            return
        v = toint(cur.get("o_rgb"))
        r = ((v >> 11) & 0x1F) * 255 // 31
        g = ((v >> 5) & 0x3F) * 255 // 63
        b = (v & 0x1F) * 255 // 31
        o = (py * W + px) * 3
        frame[o] = r
        frame[o + 1] = g
        frame[o + 2] = b
        got += 1
        px += 1
        if px == W:
            px = 0
            py += 1
            if py == H:
                done = True

    with open(VCD, "r", encoding="utf-8", errors="replace") as f:
        in_def = True
        for line in f:
            line = line.strip()
            if in_def:
                m = re.match(r"\$var\s+\S+\s+(\d+)\s+(\S+)\s+(\S+)", line)
                if m and m.group(3) in want:
                    ids[m.group(2)] = m.group(3)
                if "$enddefinitions" in line:
                    in_def = False
                    break
        need = set(ids.keys())
        for line in f:
            if not line:
                continue
            c0 = line[0]
            if c0 == "#":
                flush()                      # 上一周期结束, 采一个点
                if done:
                    break
                continue
            if c0 == "b":
                p = line[1:].split()
                if len(p) == 2 and p[1] in need:
                    cur[ids[p[1]]] = p[0]
            elif c0 in "01xzXZ":
                if line[1:] in need:
                    cur[ids[line[1:]]] = line[0]

    if not done:
        print("只采到 %d/%d 个像素, 仿真周期不够(把 run_video.ys 的 -n 调大)" % (got, W * H))
        return 1

    # 统计
    nz = sum(1 for i in range(0, len(frame), 3)
             if frame[i] or frame[i + 1] or frame[i + 2])
    colors = len({bytes(frame[i:i + 3]) for i in range(0, len(frame), 3)})
    print("采到 %d 像素, 非黑 %d, 颜色数 %d" % (got, nz, colors))

    # 写 PNG
    raw = bytearray()
    for y in range(H):
        raw.append(0)
        raw += frame[y * W * 3:(y + 1) * W * 3]

    def chunk(tag, data):
        c = tag + data
        return struct.pack(">I", len(data)) + c + struct.pack(">I", zlib.crc32(c) & 0xFFFFFFFF)

    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", W, H, 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(bytes(raw), 6))
    png += chunk(b"IEND", b"")
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "wb") as fp:
        fp.write(png)
    print("已写出:", OUT)
    return 0


if __name__ == "__main__":
    sys.exit(main())
