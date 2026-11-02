#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
verify_sd.py —— TF 卡读取链路 (sd_spi + sd_img) 的离线算法验证

1. 在内存里构建一张真实结构的 FAT32 卡镜像 (MBR + BPB + FAT + 根目录 + 640x480 24bpp BMP)
2. 用 Python 逐状态复刻 sd_img.v 的算法 (字段偏移/小端序/抽点/调色板映射/行填充)
3. 用独立的"参考实现"直接从 BMP 像素算出期望缩略图
4. 两者逐像素比对 + 渲染 tools/out/tf_thumb.png 供肉眼检查
5. 顺带静态检查 sd_spi.v / sd_img.v 的 begin/end/case 配平与端口配对

本脚本的 Python 模型是抽样算法检查，不运行 Verilog，也不能证明 SPI 或
FAT32 状态机正确。实际 RTL、完整像素覆盖和异常文件测试请运行：
    python tools/verify_sd_rtl.py --spi
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, "..")

# ---------------- 调色板 (与 gal_layer.ppal 一致) ----------------
PAL565 = [0x0000, 0x0841, 0x10A2, 0x18E3, 0x3186, 0x4208, 0x8000, 0xC000,
          0xE800, 0xFD20, 0xFE60, 0xFFE0, 0xFFFF, 0x7BEF, 0x39E7, 0x0220]


def rgb565_to_rgb888(c):
    r, g, b = (c >> 11) & 0x1F, (c >> 5) & 0x3F, c & 0x1F
    return ((r << 3) | (r >> 2), (g << 2) | (g >> 4), (b << 3) | (b >> 2))


PAL888 = [rgb565_to_rgb888(c) for c in PAL565]


def load_tfmap():
    path = os.path.join(ROOT, "rtl", "gen", "tf_map.hex")
    vals = []
    with open(path, encoding="utf-8") as f:
        for line in f.read().split():
            vals.append(int(line, 16))
    assert len(vals) == 4096, "tf_map.hex 应为 4096 项"
    return vals


TFMAP = load_tfmap()


def map_color(r8, g8, b8):
    """复刻 RTL: RGB888 高 4 位查 ROM"""
    return TFMAP[((r8 >> 4) << 8) | ((g8 >> 4) << 4) | (b8 >> 4)]


# ================= 1. 构建 FAT32 卡镜像 =================
def build_disk():
    SEC = 512
    nsec = 4096
    disk = [bytearray(SEC) for _ in range(nsec)]
    PART_LBA = 2048
    SPSC = 4          # 每簇扇区数
    RSVD = 32
    NFATS = 2
    FATSZ = 64
    ROOTCLUS = 2
    fat0 = PART_LBA + RSVD
    data0 = fat0 + NFATS * FATSZ

    # ---- MBR ----
    m = disk[0]
    m[510], m[511] = 0x55, 0xAA
    m[446 + 4] = 0x0C                       # FAT32 LBA
    for i in range(4):                      # 分区起始 LBA (小端)
        m[446 + 8 + i] = (PART_LBA >> (8 * i)) & 0xFF

    # ---- BPB ----
    b = disk[PART_LBA]
    b[11:13] = (SEC).to_bytes(2, "little")  # 每扇区字节
    b[13] = SPSC
    b[14:16] = (RSVD).to_bytes(2, "little")
    b[16] = NFATS
    b[17:19] = (128).to_bytes(2, "little")  # 根目录项数(FAT32 无视)
    b[19:21] = (0).to_bytes(2, "little")    # 总扇区16(用32)
    b[21] = 0xF8                            # 介质
    b[22:24] = (0).to_bytes(2, "little")    # fatsz16=0 -> FAT32
    b[24:26] = (63).to_bytes(2, "little")   # 每道扇区
    b[26:28] = (255).to_bytes(2, "little")  # 磁头
    b[28:32] = (2048).to_bytes(4, "little")  # 隐藏扇区
    b[32:36] = (nsec - PART_LBA).to_bytes(4, "little")
    b[36:40] = (FATSZ).to_bytes(4, "little")  # fatsz32
    b[40:42] = 0x00.to_bytes(2, "little")   # 扩展标志
    b[42:44] = 0x00.to_bytes(2, "little")
    b[44:48] = (ROOTCLUS).to_bytes(4, "little")  # 根目录簇
    b[48:50] = (1).to_bytes(2, "little")    # FSInfo
    b[50:52] = (6).to_bytes(2, "little")
    b[82:87] = b"FAT32 "
    b[510:512] = b"\x55\xAA"

    # ---- BMP 文件: 640x480 24bpp, 底向上 ----
    W, H = 640, 480
    rowsize = (W * 3 + 3) & ~3
    fsize = 54 + rowsize * H
    bmp = bytearray(fsize)
    bmp[0:2] = b"BM"
    bmp[2:6] = fsize.to_bytes(4, "little")
    bmp[10:14] = (54).to_bytes(4, "little")
    bmp[14:18] = (40).to_bytes(4, "little")
    bmp[18:22] = W.to_bytes(4, "little")
    bmp[22:26] = H.to_bytes(4, "little")
    bmp[26:28] = (1).to_bytes(2, "little")
    bmp[28:30] = (24).to_bytes(2, "little")
    bmp[30:34] = (0).to_bytes(4, "little")
    for y in range(H):                       # 文件第 0 行 = 图像最底行
        yimg = H - 1 - y
        for x in range(W):
            r = (x * 255) // (W - 1)
            g = (yimg * 255) // (H - 1)
            bl = ((x + yimg) * 255) // (W + H - 2)
            o = 54 + y * rowsize + x * 3
            bmp[o] = bl                      # B
            bmp[o + 1] = g                   # G
            bmp[o + 2] = r                   # R

    # ---- 分配簇链并写入 ----
    nclus = (fsize + SPSC * SEC - 1) // (SPSC * SEC)
    first = 6                                # 根目录占簇 2..5 (4 扇区/簇, 1 簇够, 留空隙)
    for k in range(nclus):
        c = first + k
        nxt = (c + 1) if k < nclus - 1 else 0x0FFFFFFF
        fo = fat0 + (c * 4) // SEC
        fb = (c * 4) % SEC
        disk[fo][fb:fb + 4] = nxt.to_bytes(4, "little")
    for k in range(nclus):
        c = first + k
        chunk = bmp[k * SPSC * SEC:(k + 1) * SPSC * SEC]
        base = data0 + (c - 2) * SPSC
        for s in range(SPSC):
            seg = chunk[s * SEC:(s + 1) * SEC]
            disk[base + s][0:len(seg)] = seg
    disk[fat0][(first * 4) % SEC:(first * 4) % SEC + 4] = (first + 1).to_bytes(4, "little")

    # ---- 根目录项 (短名 8.3) ----
    e = disk[data0]                          # 根目录第一扇区
    name = b"TEST    BMP"
    e[0:11] = name
    e[11] = 0x20                             # 存档属性
    e[26:28] = (first).to_bytes(2, "little")
    e[28:32] = fsize.to_bytes(4, "little")

    return disk, dict(W=W, H=H, rowsize=rowsize, fsize=fsize,
                      PART_LBA=PART_LBA, SPSC=SPSC, RSVD=RSVD, NFATS=NFATS,
                      FATSZ=FATSZ, ROOTCLUS=ROOTCLUS, first=first, nclus=nclus,
                      fat0=fat0, data0=data0, bmp=bmp)


# ================= 2. 复刻 RTL 算法 =================
def model_rtl(disk, info):
    """用Python模拟读取/抽样算法，返回256x192索引图；实际RTL行为由verify_sd_rtl.py验证。"""
    W, H = info["W"], info["H"]
    rowsize = info["rowsize"]
    bmp = info["bmp"]

    # --- MBR (S_MBRW/S_MBRE) ---
    m = disk[0]
    assert m[510:512] == b"\x55\xAA"
    mbr_type = m[450]
    mbr_lba = int.from_bytes(m[454:458], "little")
    assert mbr_type in (0x0B, 0x0C), "分区类型非 FAT32"

    # --- BPB (S_BPBW/S_BPBE) ---
    b = disk[mbr_lba]
    bps = int.from_bytes(b[11:13], "little")
    spc = b[13]
    rsvd = int.from_bytes(b[14:16], "little")
    nfats = b[16]
    fatsz = int.from_bytes(b[36:40], "little")
    rootclus = int.from_bytes(b[44:48], "little")
    assert bps == 512 and spc in (1, 2, 4, 8, 16, 32, 64, 128) and nfats > 0
    fat_lba = mbr_lba + rsvd
    data_lba = fat_lba + nfats * fatsz

    def sec_bytes(lba):
        return disk[lba]

    def fat_entry(c):
        fo = fat_lba + (c * 4) // 512
        fb = (c * 4) % 512
        s = sec_bytes(fo)
        return int.from_bytes(s[fb:fb + 4], "little")

    # --- 根目录簇链扫描 (S_DWAIT CH_ROOT) ---
    is_bmp = False
    dir_end = False
    e0 = ext = eattr = None
    eclus = esize = 0
    bmp_fnd = False
    fcl = fsz = 0
    cur = rootclus
    scanning = True
    while scanning:
        for s in range(spc):
            data = sec_bytes(data_lba + (cur - 2) * spc + s)
            for cnt in range(512):
                eoff = cnt & 31
                if eoff == 0:
                    e0 = data[cnt]
                    is_bmp = False
                    dir_end = (e0 == 0x00)
                elif eoff == 8:
                    ext = data[cnt] << 16            # 与 RTL 一致: 'B' 在 [23:16]
                elif eoff == 9:
                    ext |= data[cnt] << 8
                elif eoff == 10:
                    ext |= data[cnt]
                elif eoff == 11:
                    eattr = data[cnt]
                    if (ext == 0x424D50 and (eattr >> 3) & 3 == 0 and
                            e0 not in (0xE5, 0x00)):
                        is_bmp = True
                elif eoff == 26:
                    eclus = data[cnt]
                elif eoff == 27:
                    eclus |= data[cnt] << 8
                    if is_bmp:
                        fcl = eclus
                elif eoff == 28:
                    esize = data[cnt]
                elif eoff == 29:
                    esize |= data[cnt] << 8
                elif eoff == 30:
                    esize |= data[cnt] << 16
                elif eoff == 31:
                    esize |= data[cnt] << 24
                    if is_bmp:
                        fsz = esize
                        bmp_fnd = True
        if bmp_fnd:
            break
        if dir_end:
            raise AssertionError("根目录到头没有 BMP")
        nxt = fat_entry(cur)
        if nxt < 2 or nxt >= 0x0FFFFFF8:
            raise AssertionError("根目录簇链结束仍无 BMP")
        cur = nxt
    assert bmp_fnd

    # --- 文件读取 (S_DWAIT CH_FILE) ---
    pixoff = int.from_bytes(bmp[10:14], "little")
    wpx = int.from_bytes(bmp[18:22], "little")
    hpx = int.from_bytes(bmp[22:26], "little", signed=False)
    bpp = int.from_bytes(bmp[28:30], "little")
    sig_ok = bmp[0] == 0x42 and bmp[1] == 0x4D
    hneg = hpx >> 31
    habs = (0 - hpx) & 0xFFFFFFFF if hneg else hpx
    assert sig_ok and bpp == 24 and 0 < wpx <= 65535 and 0 < habs <= 65535, "BMP 头校验失败"
    rowsize_c = ((wpx * 2 + wpx + 3) & ~3)
    assert rowsize_c == rowsize

    # 像素抽取状态 (与 RTL 寄存器一一对应)
    x = accx = accy = 0
    tx = ty = 0
    rowty = 0 if hneg else 191
    p = 0
    breg = greg = 0
    padcnt = 0
    row_cnt = 0
    done_pend = False
    thumb = [[0] * 256 for _ in range(192)]

    fbc = 0
    while fbc < fsz and not done_pend:
        off = fbc                # 当前字节在文件内的偏移 (RTL 用自增前的 fbc 判断)
        byte = bmp[off]
        fbc += 1
        if off >= pixoff and padcnt == 0:
            if p == 0:
                breg = byte
                p = 1
            elif p == 1:
                greg = byte
                p = 2
            else:
                p = 0
                thumb[rowty][tx] = map_color(byte, greg, breg)
                accx += 256
                if accx >= wpx:
                    accx -= wpx
                    if tx != 255:
                        tx += 1
                if x == wpx - 1:
                    x = 0
                    tx = 0
                    accx = 0
                    padcnt = (rowsize_c - wpx * 3) & 3
                    accy += 192
                    crossed = accy >= habs
                    if crossed:
                        accy -= habs
                        ty_next = 191 if ty == 191 else ty + 1
                        ty = ty_next
                    else:
                        ty_next = ty
                    rowty = (ty_next if hneg else (0 if ty_next == 191 else 191 - ty_next)) \
                        if crossed else (ty_next if hneg else 191 - ty_next)
                    row_cnt += 1
                    if row_cnt >= habs:
                        done_pend = True
                else:
                    x += 1
        elif padcnt != 0:
            padcnt -= 1
    return thumb


# ================= 3. 独立参考实现 =================
def reference(disk, info):
    """直接从 BMP 像素计算期望缩略图。

    语义与 RTL 严格一致: 源像素 x 写入 tx=floor(x*256/W) (写后 tx 才推进),
    多个源像素映射到同一格时后写覆盖。因此直接全量迭代即可复现。
    """
    bmp = info["bmp"]
    W, H = info["W"], info["H"]
    rowsize = info["rowsize"]
    pixoff = int.from_bytes(bmp[10:14], "little")
    hneg = int.from_bytes(bmp[22:26], "little") >> 31

    thumb = [[0] * 256 for _ in range(192)]
    for y in range(H):                        # 文件行号 (0 = BMP 第一存储行)
        ty = (y * 192) // H                    # 写入前 ty = floor(y*192/H)
        ry = ty if hneg else (191 - ty)
        yimg = (H - 1 - y) if not hneg else y
        for x in range(W):
            tx = (x * 256) // W
            o = pixoff + y * rowsize + x * 3   # ★ 字节偏移用存储行号 y
            b8, g8, r8 = bmp[o], bmp[o + 1], bmp[o + 2]
            thumb[ry][tx] = map_color(r8, g8, b8)
    return thumb


# ================= 4. 渲染 PNG =================
def write_png(rows, path, scale=1):
    h, w = len(rows), len(rows[0])
    raw = b""
    for row in rows:
        line = b"\x00"
        for c in row:
            line += bytes(c) * scale
        for _ in range(scale):
            raw += line

    def chunk(t, d):
        c = t + d
        return len(d).to_bytes(4, "big") + c + (zlib.crc32(c) & 0xFFFFFFFF).to_bytes(4, "big")

    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", (w * scale).to_bytes(4, "big") + (h * scale).to_bytes(4, "big") +
                 bytes([8, 2, 0, 0, 0]))
    png += chunk(b"IDAT", zlib.compress(raw, 9))
    png += chunk(b"IEND", b"")
    with open(path, "wb") as f:
        f.write(png)


# ================= 5. 静态检查 =================
def lint():
    ok = True
    for fn, mods in (("rtl/common/key_debounce.v", None),
                     ("rtl/video/rpg_video.v", None),
                     ("rtl/rpg_top.v", None)):
        path = os.path.join(ROOT, fn)
        src = open(path, encoding="utf-8").read()
        src2 = re.sub(r"//[^\n]*", "", src)
        src2 = re.sub(r"/\*.*?\*/", "", src2, flags=re.S)
        for a, b in (("(", ")"), ("begin", "end"), ("case", "endcase")):
            if a == "(":
                ca, cb = src2.count(a), src2.count(b)
            else:
                ca = len(re.findall(r"\b%s\b" % a, src2))
                cb = len(re.findall(r"\b%s\b" % b, src2))
            if ca != cb:
                print("  [LINT] %s: %s/%s 不配平 (%d vs %d)" % (fn, a, b, ca, cb))
                ok = False
        nm = re.findall(r"^module\s+(\w+)", src, re.M)
        em = src2.count("endmodule")
        if len(nm) != em:
            print("  [LINT] %s: module(%d) != endmodule(%d)" % (fn, len(nm), em))
            ok = False
        print("  [LINT] %s: modules=%s ok=%s" % (os.path.basename(fn), nm, ok))
    # sd_spi / sd_img / tf_ram 被上层实例化的端口核对
    def strip_cmt(s):
        s = re.sub(r"//[^\n]*", "", s)
        return re.sub(r"/\*.*?\*/", "", s, flags=re.S)

    def decl_ports(hay, mod):
        """从 ANSI 风格模块声明提取端口名集合"""
        hay = strip_cmt(hay)
        m = re.search(r"\bmodule\s+%s\s*(?:#\s*\([^;]*?\))?\s*\((.*?)\n\s*\);" % mod, hay, re.S)
        assert m, "找不到模块 %s 的端口声明" % mod
        body = m.group(1)
        # ANSI declarations may share a type across comma-separated names.
        # Remove declarations/ranges, then retain each explicit port identifier.
        names = set()
        for part in body.split(','):
            part = re.sub(r"\b(?:input|output|inout|wire|reg|logic|signed)\b|\[[^\]]*\]", '', part).strip()
            if re.fullmatch(r"\\?\w+", part): names.add(part.lstrip('\\'))
        return names

    # 跨 always 块多驱动检查 (TD Error 8007: xxx is constantly driven from multiple places)
    names = re.findall(r"\bmodule\s+(\w+)", src_kb := open(os.path.join(ROOT, "rtl/common/key_debounce.v"), encoding="utf-8").read())
    names += re.findall(r"\bmodule\s+(\w+)", open(os.path.join(ROOT, "rtl/video/rpg_video.v"), encoding="utf-8").read())
    names += re.findall(r"\bmodule\s+(\w+)", open(os.path.join(ROOT, "rtl/rpg_top.v"), encoding="utf-8").read())
    allsrc = "\n".join([src_kb,
                        open(os.path.join(ROOT, "rtl/video/rpg_video.v"), encoding="utf-8").read(),
                        open(os.path.join(ROOT, "rtl/rpg_top.v"), encoding="utf-8").read()])
    allsrc = re.sub(r"//[^\n]*", "", allsrc)
    allsrc = re.sub(r"/\*.*?\*/", "", allsrc, flags=re.S)

    def extract(name, text):
        m = re.search(r"\bmodule\s+%s\b" % name, text)
        i = m.end(); depth = 1
        for mm in re.finditer(r"\b(module|endmodule)\b", text[i:]):
            depth += 1 if mm.group(1) == "module" else -1
            if depth == 0:
                return text[i:mm.start()]
        return text[i:]

    for mod in names:
        body = extract(mod, allsrc)
        blocks = [p for p in re.split(r"(?=always\s*@)", body) if p.startswith("always")]
        drv = {}
        for i, b in enumerate(blocks):
            for v in re.findall(r"(\w+)\s*<=", b):
                drv.setdefault(v, set()).add(i)
        for v, bs in drv.items():
            if len(bs) > 1:
                print("  [LINT] %s: %s 被 %d 个 always 块驱动 %s" % (mod, v, len(bs), sorted(bs)))
                ok = False

    top = strip_cmt(open(os.path.join(ROOT, "rtl/rpg_top.v"), encoding="utf-8").read())
    kb = open(os.path.join(ROOT, "rtl/common/key_debounce.v"), encoding="utf-8").read()
    vid = open(os.path.join(ROOT, "rtl/video/rpg_video.v"), encoding="utf-8").read()
    for mod in ("sd_spi", "sd_img", "media_ctrl", "media_cdc", "media_framebuffer"):
        ports = decl_ports(kb, mod)
        inst = re.search(r"\b%s\s+(?:#\s*\([^;]*?\)\s*)?(u_\w+)\s*\((.*?)\n\s*\);" % mod, top, re.S)
        assert inst, "顶层找不到 %s 实例" % mod
        conns = set(re.findall(r"\.(\w+)\s*\(", inst.group(2)))
        missing = ports - conns
        extra = conns - ports
        if missing or extra:
            print("  [LINT] %s 端口不匹配: 缺%s 多%s" % (mod, sorted(missing), sorted(extra)))
            ok = False
        else:
            print("  [LINT] %s 顶层端口配对 OK (%d 个)" % (mod, len(ports)))

    #---------------------------------------------------------------
    # RTL 语义回归 (踩过的坑; 逐像素比对只能证明"模型"对, 证明不了 RTL 对)
    #---------------------------------------------------------------
    def need(cond, msg):
        nonlocal ok
        if not cond:
            print("  [LINT-FAIL] " + msg)
            ok = False

    kb_n = strip_cmt(kb)
    # 1) FAT 扇区: (簇号*4)/512 = 簇号>>7, 绝不能用左移
    m = re.search(r"wire\s*\[31:0\]\s*fat_sec\s*=\s*([^;]+);", kb_n)
    need(m and "cur_clus[31:7]" in m.group(1),
         "fat_sec 应为 fat_lba + {.., cur_clus[31:7]} (簇号>>7), 当前: %s"
         % (m.group(1).strip() if m else "未找到"))
    # 2) FAT32 项是小端: fat_off 处必须写 fatent[7:0]
    m = re.search(r"if\s*\(cnt\s*==\s*fat_off\)\s*fatent\[([^\]]+)\]\s*<=", kb_n)
    need(m and m.group(1) == "7:0",
         "FAT 项字节序应小端 (fat_off 处 = fatent[7:0]), 当前写 fatent[%s]"
         % (m.group(1) if m else "?"))
    # 3) 目录项首簇必须取 32 位 (偏移 20/21 高字 + 26/27 低字)
    need("5'd21: echi[15:8]" in kb_n, "目录项缺少首簇高 16 位捕获 (偏移 20/21)")
    need(re.search(r"fcl\s*<=\s*\{4'd0,\s*echi\[11:0\]", kb_n) is not None, "fcl 应取首簇高12位和低16位(忽略FAT32保留位)")
    # 4) ACMD41 必须真的发出去 (S_A55R 状态存在且引用 C41V2/C41V1)
    need(re.search(r"S_A55R\s*:", kb_n) is not None, "缺少 S_A55R 状态 (CMD55 后发 ACMD41)")
    need(kb_n.count("C41V2") >= 2, "ACMD41 命令帧 C41V2 定义了却没被使用")
    # 5) 缩略图地址必须16位 (49152像素)
    need("output reg  [15:0] tw_addr" in kb_n, "tw_addr必须16位 (49152像素)")
    # 6) 读块路径必须有超时出口, 否则 sd_img 会永久等 blk_done
    need(kb_n.count("tmo == 24'hFFFFFF") >= 4, "sd_img 缺少超时看门狗 (应覆盖 MBR/BPB/数据/FAT 四处)")
    # 7) 请求锁存与组帧必须分处两拍; 实际波形/像素回归见verify_sd_rtl.py。
    need("state  <= S_RDSTART" in kb_n and "S_RDSTART: begin" in kb_n,
         "CMD17缺少地址锁存后的组帧状态")
    need("{rd_addr[22:0], 9'd0}" in kb_n, "SDSC地址必须左移9位")
    need("cmdsh   <= {8'h51, rdaddr, 8'h01}" in kb_n, "CMD17应使用上一拍锁存的当前请求")
    need("accx_sum >=" in kb_n and "accy_sum >=" in kb_n,
         "抽样比较必须使用加法后的累加器值")
    need("reg  [7:0]  spc" in kb_n and "spc      <= dout" in kb_n,
         "每簇扇区数必须保留完整8位")
    # 8) sd_spi 里不得引用 sd_img 的信号 (TD HDL-8007: 'cnt' remains unresolved)
    m = re.search(r"\bmodule\s+sd_spi\b", kb_n)
    if m:
        i = m.end(); depth = 1
        for mm in re.finditer(r"\b(module|endmodule)\b", kb_n[i:]):
            depth += 1 if mm.group(1) == "module" else -1
            if depth == 0:
                spi_body = kb_n[i:i + mm.start()]; break
        for alien in ("cnt", "dsel", "dbus", "fdiag", "b450", "echi"):
            if re.search(r"(?<![.\w'])%s\b" % alien, spi_body):
                need(False, "sd_spi 内出现 %s —— 这是 sd_img 的信号, 会报 HDL-8007" % alien)
        # 9) S_READY 重启分支绝不能清 step: 否则诊断画面永远回全暗 + 无限重初始化
        m2 = re.search(r"S_READY:\s*begin(.*?)\n                end\b", spi_body, re.S)
        if m2 and re.search(r"step\s*<=", m2.group(1)):
            need(False, "sd_spi 的 S_READY 里清了 step —— 会导致诊断全暗 + 无限重置循环")
    if ok:
        print("  [LINT] RTL 语义回归 OK (fat_sec/小端/首簇32位/ACMD41/16位地址/看门狗)")
    return ok


# ================= main =================
def main():
    print("== 1. 构建 FAT32 卡镜像 ==")
    disk, info = build_disk()
    print("   卡 %d 扇区, BMP %dx%d %d 字节, %d 簇 (首簇 %d)"
          % (len(disk), info["W"], info["H"], info["fsize"], info["nclus"], info["first"]))

    print("== 2. 复刻 RTL 算法跑读取链路 ==")
    thumb = model_rtl(disk, info)
    print("   完成: 256x192 缩略图已生成")

    print("== 3. 独立参考实现比对 ==")
    ref = reference(disk, info)
    diff = sum(1 for r in range(192) for c in range(256) if thumb[r][c] != ref[r][c])
    if diff:
        print("   [FAIL] 与参考实现相差 %d 像素" % diff)
        sys.exit(1)
    print("   逐像素一致 (49152/49152)")

    print("== 4. 渲染预览 ==")
    pal = PAL888
    rows = [[pal[thumb[r][c]] for c in range(256)] for r in range(192)]
    out = os.path.join(HERE, "out")
    os.makedirs(out, exist_ok=True)
    write_png(rows, os.path.join(out, "tf_thumb.png"), scale=2)
    print("   tools/out/tf_thumb.png")

    print("== 5. 静态检查 ==")
    if not lint():
        sys.exit(1)
    print("ALL CHECKS PASSED")


import zlib  # noqa: E402

if __name__ == "__main__":
    main()
