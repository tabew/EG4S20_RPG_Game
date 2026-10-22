# -*- coding: utf-8 -*-
"""
build_player.py —— 生成单文件 HTML 仿真器 rpg_player.html

它把 FPGA 实际用的四份 ROM 原封不动打包进去:
    rtl/gen/font.hex   字模 4096 x 16bit
    rtl/gen/cmd.hex    界面指令表
    rtl/gen/str.hex    字符串
    rtl/gen/art.hex    精灵图
再加怪物表/区域表/消息地址, 前端用与 rpg_core.v 相同的解释器和状态机跑。

改了界面或数值之后:
    python tools/build_player.py
"""
import json, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)

import build_rom as B          # 会顺带重新生成 rtl/gen/*.hex

GEN = os.path.join(ROOT, "rtl", "gen")


def hex_words(name, width):
    out = []
    for line in open(os.path.join(GEN, name), encoding="ascii"):
        line = line.strip()
        if line:
            out.append(int(line, 16))
    return out


def rgb565_to_css(v):
    r = ((v >> 11) & 0x1F) * 255 // 31
    g = ((v >> 5) & 0x3F) * 255 // 63
    b = (v & 0x1F) * 255 // 31
    return (r << 16) | (g << 8) | b


# ---- 精灵取色：与 rpg_core.v 的 art_fg 表一致 ----
ART_COLOR = {0: 9, 10: 9, 1: 10, 11: 10, 2: 10, 3: 10, 4: 11, 5: 15,
             6: 7, 12: 7, 7: 5, 13: 5, 8: 15, 9: 13, 14: 14}


def main():
    data = {
        "font": hex_words("font.hex", 16),
        "cmd": hex_words("cmd.hex", 32),
        "str": hex_words("str.hex", 8),
        "art": hex_words("art.hex", 8),
        "palette": [rgb565_to_css(v) for v in B.PALETTE],
        "screens": [B.SCREEN_ADDR[k] for k in
                    ("title", "class", "map", "battle", "shop", "dead", "win")],
        "digBase": B.GIDX["0"],
        # 字符 -> 字形码（前端 decodeStr 用）
        "cidMap": {c: B.GIDX[c] for c in B.GIDX
                   if len(c) == 1 and ord(c) >= 32},
        # 字形码 -> 字符（指令流里反显文字用）
        "charOf": [""] * 256,
        "enemies": [],
        "enemyName": [],
        "areaName": [],
        "areas": [],
        "msgs": {},
        "artBase": {int(k): int(v) for k, v in B.SPR_BASE.items()},
        "artColor": {int(k): v for k, v in ART_COLOR.items()},
    }

    for code, name in enumerate(B.CODES):
        if len(name) == 1:            # 包括中文, 指令流里要反显文字
            data["charOf"][code] = name

    for (nm, hp, atk, df, exp, gold, spr, boss) in B.ENEMIES:
        data["enemies"].append({"hp": hp, "atk": atk, "def": df, "exp": exp,
                                "gold": gold, "spr": spr, "boss": boss})
        data["enemyName"].append(nm)

    for (nm, mobs, boss) in B.AREAS:
        data["areaName"].append(nm)
        data["areas"].append({"mob0": mobs[0], "mob1": mobs[1], "boss": boss})

    for name, addr in B.msg_addr.items():
        data["msgs"][name] = addr

    js = json.dumps(data, ensure_ascii=False, separators=(",", ":"))

    tpl = open(os.path.join(HERE, "player_template.html"), encoding="utf-8").read()
    html = tpl.replace("__DATA__", js)
    out = os.path.join(ROOT, "rpg_player.html")
    with open(out, "w", encoding="utf-8", newline="\n") as f:
        f.write(html)

    print("已生成:", out)
    print("  字形 %d, 指令 %d, 字符串 %d B, 精灵 %d B" %
          (len(data["font"]) // 16, len(data["cmd"]), len(data["str"]), len(data["art"])))
    print("  怪物 %d 种, 区域 %d 个, 消息 %d 条" %
          (len(data["enemies"]), len(data["areas"]), len(data["msgs"])))
    print("  文件大小 %.0f KB" % (os.path.getsize(out) / 1024))
    return 0


if __name__ == "__main__":
    sys.exit(main())
