# -*- coding: utf-8 -*-
"""
rgb2png.py —— 把 iverilog 测试台输出的原始像素切成 PNG

    python tools/rgb2png.py                 # 全部帧转 PNG
    python tools/rgb2png.py --last          # 只转最后一帧
    python tools/rgb2png.py --scale 2       # 放大 2 倍

输入: sim/iverilog/frames.rgb   每帧 640*480*3 字节(RGB888), 连续排列
输出: preview/sim/frame_01.png ...
"""
import argparse, os, struct, sys, zlib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "sim", "iverilog", "frames.rgb")
OUT = os.path.join(ROOT, "preview", "sim")
W, H = 640, 480
FRAME = W * H * 3


def write_png(path, rgb, w, h, scale=1):
    if scale > 1:
        rows = []
        for y in range(h):
            line = rgb[y * w * 3:(y + 1) * w * 3]
            big = bytearray()
            for x in range(w):
                px = line[x * 3:x * 3 + 3]
                big += px * scale
            rows.append(bytes(big))
        w2, h2 = w * scale, h * scale
        raw = bytearray()
        for r in rows:
            for _ in range(scale):
                raw.append(0)
                raw += r
    else:
        w2, h2 = w, h
        raw = bytearray()
        for y in range(h):
            raw.append(0)
            raw += rgb[y * w * 3:(y + 1) * w * 3]

    def chunk(tag, data):
        c = tag + data
        return struct.pack(">I", len(data)) + c + struct.pack(">I", zlib.crc32(c) & 0xFFFFFFFF)

    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", w2, h2, 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(bytes(raw), 6))
    png += chunk(b"IEND", b"")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        f.write(png)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--last", action="store_true", help="只转最后一帧")
    ap.add_argument("--scale", type=int, default=1, help="放大倍数")
    args = ap.parse_args()

    if not os.path.exists(SRC):
        print("找不到", SRC)
        print("先在工程根目录跑一次仿真:  sim\\iverilog\\run.bat   (或 ./sim/iverilog/run.sh)")
        return 1

    size = os.path.getsize(SRC)
    n, rest = divmod(size, FRAME)
    if rest:
        print("[警告] 文件大小 %d 不是整帧(%d), 最后残缺的 %d 字节会被忽略" % (size, FRAME, rest))
    if n == 0:
        print("没有完整帧")
        return 1

    print("共 %d 帧, 每帧 %dx%d" % (n, W, H))
    todo = [(n, )] if args.last else [(i + 1,) for i in range(n)]

    data = open(SRC, "rb").read()
    for (i,) in todo:
        rgb = data[(i - 1) * FRAME: i * FRAME]
        out = os.path.join(OUT, "frame_%02d.png" % i)
        write_png(out, rgb, W, H, args.scale)
        nz = sum(1 for k in range(0, len(rgb), 3) if rgb[k] or rgb[k + 1] or rgb[k + 2])
        print("  %-28s 点亮像素 %d" % (os.path.basename(out), nz))

    print("\n打开 preview/sim/ 里的 PNG 就能看到仿真画面。")
    print("帧的先后顺序 = keys.txt 里按键的顺序, 最后一张是最终画面。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
