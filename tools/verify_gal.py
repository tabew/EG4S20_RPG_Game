# -*- coding: utf-8 -*-
"""
verify_gal.py —— 逐像素复刻 gal_layer/photo_rom 的 RTL 行为

1. 渲染 gal_on=1, fade=8 时的整屏 (逻辑 640x480), 输出 PNG 供肉眼检查
2. 静态 lint: module/endmodule、begin/end 配平, 实例化端口 vs 模块定义比对
"""
import os, re, sys, zlib, struct

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# ---- 与 RTL 相同的常量 ----
PAL = [0x0000,0x0841,0x10A2,0x18E3,0x3186,0x4208,0x8000,0xC000,
       0xE800,0xFD20,0xFE60,0xFFE0,0xFFFF,0x7BEF,0x39E7,0x0220]
GX0, GY0, GW, GH = 64, 44, 512, 384

def rgb565(c):
    r = (c >> 11) & 0x1F; g = (c >> 5) & 0x3F; b = c & 0x1F
    return (r*255//31, g*255//63, b*255//31)

def load_photo():
    mem = []
    with open(os.path.join(ROOT, "rtl", "gen", "photo.hex"), encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line:
                mem.append(int(line, 16))
    assert len(mem) == 24576, "photo.hex 行数=%d" % len(mem)
    return mem

DGT = {1:0b010110010010111, 2:0b111001111100111, 3:0b111001011001111, 4:0b101101111001001}

def pixel(x, y, img, mem):
    """复刻 gal_layer 输出组合逻辑 (S2 地址公式 + S3 合成)"""
    # S2: 地址 (x2 == x3, 同一像素坐标)
    in2 = GX0 <= x < GX0+GW and GY0 <= y < GY0+GH
    ax, ay = x - GX0, y - GY0
    px, py = (ax >> 2) & 0x7F, (ay >> 2) & 0x7F
    paddr = img*6144 + ((py << 6) | (px >> 1))
    sel_hi = ((ax >> 2) & 1) == 0
    byte = mem[paddr] if in2 else 0
    nib = (byte >> 4) if sel_hi else (byte & 0xF)
    pcol = PAL[nib]

    # S3 合成
    in_p3 = GX0 <= x < GX0+GW and GY0 <= y < GY0+GH
    in_frm = 58 <= x < 582 and 38 <= y < 434
    ring = in_frm and not in_p3
    dxo = x - 286
    di = 0 if dxo < 20 else 1 if dxo < 40 else 2 if dxo < 60 else 3
    din = dxo - di*20
    in_dot = dxo < 68 and 434 <= y < 442 and din < 8
    dnum = img + 1
    ddx, ddy = x - 596, y - 434
    drow = 0 if ddy < 3 else 1 if ddy < 6 else 2 if ddy < 9 else 3 if ddy < 12 else 4
    dcol = 0 if ddx < 3 else 1 if ddx < 6 else 2
    dbit = (DGT[dnum] >> (14 - drow*3 - dcol)) & 1
    in_dig = 596 <= x < 605 and 434 <= y < 449 and dbit

    if in_p3:  return rgb565(pcol)
    if ring:   return rgb565(0x39E7)
    if in_dot: return rgb565(0xFFE0 if di == img else 0x39E7)
    if in_dig: return (255, 255, 255)
    return (0, 0, 0)

def write_png(rows, path):
    h, w = len(rows), len(rows[0])
    raw = bytearray()
    for row in rows:
        raw += b"\x00" + b"".join(bytes(c) for c in row)
    def chunk(tag, data):
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(bytes(raw), 9))
    png += chunk(b"IEND", b"")
    with open(path, "wb") as f:
        f.write(png)

def render_all(mem, out):
    os.makedirs(out, exist_ok=True)
    for img in range(4):
        rows = [[pixel(x, y, img, mem) for x in range(640)] for y in range(480)]
        write_png(rows, os.path.join(out, "gal_img%d.png" % img))
        print("render img%d ok" % img)

# ---- 静态 lint ----
def lint(path):
    src = open(path, encoding="utf-8").read()
    # 去掉注释和字符串, 防止干扰配平
    src2 = re.sub(r"//[^\n]*", "", src)
    src2 = re.sub(r"\$\w+\([^;]*\);", "INIT;", src2, flags=re.S)
    n_mod = len(re.findall(r"(?m)^module\b", src2))
    n_end = len(re.findall(r"(?m)^endmodule\b", src2))
    n_beg = len(re.findall(r"\bbegin\b", src2)); n_e = len(re.findall(r"\bend\b", src2))
    n_case = len(re.findall(r"\bcase[zx]?\b", src2)); n_ec = len(re.findall(r"\bendcase\b", src2))
    n_fn = len(re.findall(r"\bfunction\b", src2)); n_ef = len(re.findall(r"\bendfunction\b", src2))
    print("%s: module %d/%d begin %d/%d case %d/%d func %d/%d" %
          (os.path.basename(path), n_mod, n_end, n_beg, n_e, n_case, n_ec, n_fn, n_ef))
    assert n_mod == n_end and n_beg == n_e and n_case == n_ec and n_fn == n_ef, "配平失败!"
    # 括号配平
    assert src2.count("(") == src2.count(")"), "括号不配平"
    assert src2.count("{") == src2.count("}"), "花括号不配平"
    # 函数声明参数个数 vs 调用点实参个数 (TD 会报 'xxx' requires N arguments)
    # 兼容两种风格: function f(input a, input b); 和 function f; input a; input b;
    fn_arity = {}
    for m in re.finditer(r"(?ms)\bfunction\b.*?\bendfunction\b", src2):
        body = m.group(0)
        hm = re.match(r"\s*function\s+(?:\[[^\]]*\]\s*)?(\w+)", body)
        if hm:
            fn_arity[hm.group(1)] = len(re.findall(r"\binput\b", body))
    for name, arity in fn_arity.items():
        for cm in re.finditer(re.escape(name) + r"\s*\(", src2):
            start = cm.end() - 1
            depth, i = 0, start
            while i < len(src2):
                if src2[i] == "(":
                    depth += 1
                elif src2[i] == ")":
                    depth -= 1
                    if depth == 0:
                        break
                i += 1
            args = src2[start + 1:i]
            # 拼接 { } 与空格不算实参分隔符, 只按顶层逗号计数
            nargs = 1
            d2 = 0
            for ch in args:
                if ch in "({[":
                    d2 += 1
                elif ch in ")}]":
                    d2 -= 1
                elif ch == "," and d2 == 0:
                    nargs += 1
            assert nargs == arity, \
                "函数 %s 声明 %d 参, 调用点只给 %d 参: %s" % (name, arity, nargs, args.strip()[:60])
    if fn_arity:
        print("  函数参数配平: " + ", ".join("%s/%d" % kv for kv in sorted(fn_arity.items())))

def lint_ports(files):
    """实例化端口 vs 模块定义"""
    defs = {}
    for path in files:
        src = re.sub(r"//[^\n]*", "", open(path, encoding="utf-8").read())
        for m in re.finditer(r"(?ms)^module\s+(\w+)\s*#\?\s*\((.*?)\)\s*;", src):
            pass
        for m in re.finditer(r"(?ms)^module\s+(\w+)\s*(?:#\s*\((.*?)\))?\s*\((.*?)\)\s*;", src):
            name, params, ports = m.group(1), m.group(2) or "", m.group(3)
            plist = set(re.findall(r"\.(\w+)\b", ports)) | set(re.findall(r"\b(?:input|output|inout)\s+(?:wire|reg)?\s*(?:\[[^\]]*\]\s*)?(\w+)", ports))
            defs[name] = plist
        for m in re.finditer(r"(?ms)^\s*(\w+)\s+(?:#\s*\((.*?)\)\s*)?(\w+)\s*\((.*?)\)\s*;", src):
            mod, conns = m.group(1), m.group(4) or ""
            if mod in ("module", "if", "always", "case", "function") or mod not in defs:
                continue
            used = set(re.findall(r"\.(\w+)\s*\(", conns))
            missing = used - defs[mod]
            unused = defs[mod] - used - {"clk", "rst_n"} if False else defs[mod] - used
            status = "OK" if not missing else "缺失端口 %s" % missing
            print("  实例 %-12s -> %-12s %s (未接: %s)" % (m.group(3), mod, status, sorted(unused) if unused else "-"))
            assert not missing

if __name__ == "__main__":
    kd = os.path.join(ROOT, "rtl", "common", "key_debounce.v")
    rv = os.path.join(ROOT, "rtl", "video", "rpg_video.v")
    rt = os.path.join(ROOT, "rtl", "rpg_top.v")
    for f in (kd, rv, rt):
        lint(f)
    lint_ports([kd, rv, rt, os.path.join(ROOT, "rtl", "video", "mon_layer.v")])
    mem = load_photo()
    render_all(mem, os.path.join(ROOT, "tools", "out"))
    print("ALL CHECKS PASSED")
