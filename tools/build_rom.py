ADESS = [
    "田埂草叶挂着露水",
    "雾气缠着树干不散",
    "矿灯照着湿滑岩壁",
    "热浪扑面石头烫脚",
    "黑曜长廊没有一丝风",
]

AREAS = [
    ("新手村外", [0, 1, 2, 3],      4),
    ("迷雾森林", [5, 6, 7, 8],      9),
    ("废弃矿洞", [10, 11, 12, 13],  14),
    ("火山口",   [15, 16, 17, 18],  19),
    ("暗黑城堡", [20, 21, 22, 23],  24),
]
# -*- coding: utf-8 -*-
"""
build_rom.py —— 字符 RPG 的全部资源生成器

一次运行产出:
    rtl/gen/font.hex    字模: 256 字形 x 16 行, 每行 16bit
    rtl/gen/ui.hex      UI 字符串 / 精灵图 / 指令表(见 ui_rom.v 的地址约定)
    rtl/gen/ui_rom.v    三个 ROM 的封装模块
    preview/*.bmp       每个界面的预览图(用同一套字模和指令解释器渲染)

设计约定:
    * 屏幕 40 列 x 30 行, 每格 16x16 像素 -> 640x480
    * 每个格子 16bit: glyph[7:0] | fg[11:8] | bg[15:12]
    * ASCII 字形水平放大一倍, 与中文等宽, 不会出现"字距拉开"
    * 边框/方块不用系统字体的制表符(16px 下会缩水), 而是自己画
"""
import os, sys, struct

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gdi_font import FontRaster

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GEN = os.path.join(ROOT, "rtl", "gen")
PREV = os.path.join(ROOT, "preview")

COLS, ROWS = 40, 30


def art_color(spr_id):
    """精灵颜色: 与 rtl/ctrl/rpg_core.v 的 art_fg 完全一致"""
    t = {0: 9, 10: 9, 1: 10, 11: 10, 2: 10, 3: 10, 4: 11, 5: 15,
         6: 7, 12: 7, 7: 5, 13: 5, 8: 15, 9: 13, 14: 14}
    return t.get(spr_id, 3)

# ══════════════════════════════════════════════════════════════
# 调色板(16 色, RGB565)
# ══════════════════════════════════════════════════════════════
PALETTE = [
    0x0000,  # 0 黑
    0x18E3,  # 1 暗灰(底纹)
    0x4208,  # 2 灰
    0x7BEF,  # 3 浅灰
    0xFFFF,  # 4 白
    0xF800,  # 5 红
    0x8000,  # 6 暗红
    0xFD20,  # 7 橙
    0xFFE0,  # 8 黄
    0x07E0,  # 9 绿
    0x03E0,  # 10 亮绿
    0x07FF,  # 11 青
    0x001F,  # 12 蓝
    0x781F,  # 13 紫
    0xF81F,  # 14 品红
    0xC618,  # 15 银白
]
BLACK, DGRAY, GRAY, LGRAY, WHITE = 0, 1, 2, 3, 4
RED, DRED, ORANGE, YELLOW, GREEN = 5, 6, 7, 8, 9
LGREEN, CYAN, BLUE, PURPLE, MAGENTA, SILVER = 10, 11, 12, 13, 14, 15
RPG_RED, RPG_DRED, RPG_GRAY, RPG_LGRAY = RED, DRED, GRAY, LGRAY

# ══════════════════════════════════════════════════════════════
# 自绘方块图元(16x16)
# ══════════════════════════════════════════════════════════════
def _tile(kind):
    rows = [0] * 16
    for y in range(16):
        v = 0
        for x in range(16):
            on = False
            if kind == "full":
                on = True
            elif kind == "shade":
                on = (x % 2 == 0) and (y % 2 == 0)
            elif kind == "dense":
                on = ((x + y) % 2 == 0) or ((x + y) % 4 == 0)
            elif kind == "half":
                on = y >= 8
            elif kind == "empty":
                on = (y == 2) or (y == 13)          # 上下两道细线, 表示空槽
            elif kind == "h":
                on = 7 <= y <= 8
            elif kind == "v":
                on = 7 <= x <= 8
            elif kind == "tl":
                on = (7 <= y <= 8 and x >= 7) or (7 <= x <= 8 and y >= 7)
            elif kind == "tr":
                on = (7 <= y <= 8 and x <= 8) or (7 <= x <= 8 and y >= 7)
            elif kind == "bl":
                on = (7 <= y <= 8 and x >= 7) or (7 <= x <= 8 and y <= 8)
            elif kind == "br":
                on = (7 <= y <= 8 and x <= 8) or (7 <= x <= 8 and y <= 8)
            elif kind == "tee_l":                        # 右侧有横线
                on = (7 <= x <= 8) or (7 <= y <= 8 and x <= 8)
            elif kind == "tee_r":
                on = (7 <= x <= 8) or (7 <= y <= 8 and x >= 7)
            elif kind == "solid_top":
                on = y < 3
            if on:
                v |= (1 << (15 - x))
        rows[y] = v
    return rows

CUSTOM = [
    (" ", None),            # 0 空格
    ("T_FULL", "full"),
    ("T_SHADE", "shade"),
    ("T_DENSE", "dense"),
    ("T_HALF", "half"),
    ("T_EMPTY", "empty"),
    ("T_H", "h"),
    ("T_V", "v"),
    ("T_TL", "tl"),
    ("T_TR", "tr"),
    ("T_BL", "bl"),
    ("T_BR", "br"),
    ("T_TEEL", "tee_l"),
    ("T_TEER", "tee_r"),
    ("T_TOPBAR", "solid_top"),
]
TILE = {}   # 名字 -> 字符占位(后面填真实码)
for i, (name, kind) in enumerate(CUSTOM):
    TILE[name] = name

# ══════════════════════════════════════════════════════════════
# 文本内容
# ══════════════════════════════════════════════════════════════
T = {
    "title":    "字界远征",
    "subtitle": "ASCII QUEST",
    "press":    "按 1 开始冒险",
    "class_h":  "选择职业",
    "w_name":   "剑士",  "w_desc": "血厚防高，重斩破甲",
    "m_name":   "法师",  "m_desc": "爆发极高，火球无视护甲",
    "r_name":   "游侠",  "r_desc": "暴击率高，三连射",
    "pick":     "1 剑士    2 法师    3 游侠",

    "hp": "生命", "mp": "魔力", "atk": "攻", "def": "防",
    "gold": "金", "lv": "级", "exp": "经验", "pot": "药水",
    "potxl": "大药水", "herb": "药草", "kills": "讨伐", "dmg": "伤害",

    "explore": "探索", "shop": "商店", "rest": "休息",
    "boss": "首领", "next": "前往", "ending": "结局",
    "attack": "攻击", "skill": "技能", "flee": "逃跑",

    "shop_h":  "补给站",
    "buy1": "药水    回复 50 生命",
    "buy2": "大药水  回复 130 生命",
    "buy3": "强化    攻 +3  防 +2",
    "leave": "离开",
    "no_gold": "金币不够",

    # 战斗消息
    "m_hit":    "你发起攻击",
    "m_skill":  "技能发动",
    "m_heal":   "喝下药水",
    "m_noMP":   "魔力不足",
    "m_enemy":  "敌人反击",
    "m_kill":   "击败了敌人",
    "m_levelup":"等级提升",
    "m_noPot":  "没有药水",
    "m_flee":   "你成功逃脱",
    "m_fail":   "逃跑失败",

    "dead_h":  "你倒下了",
    "dead_m":  "在补给站醒来，进度归零",
    "again":   "1 重新出发",
    "win_h":   "通 关",
    "win_m":   "深渊领主已被击败",
    "win_m2":  "世界重新排好版",
    "restart": "1 再来一次",
}

# 敌人: 名字, hp, atk, def, exp, gold, sprite_id, is_boss
ENEMIES = [
    # 名字, hp, atk, def, exp, gold, 精灵, 是否BOSS
    # ── 区域 0 新手村外 ──
    ("史莱姆",    36,  8,  2,   9,   7,  0, 0),
    ("野兔",      30, 11,  1,   8,   6,  1, 0),
    ("田鼠",      28, 10,  1,   7,   5, 15, 0),
    ("蜂群",      24, 12,  0,   8,   6, 16, 0),
    ("史莱姆王", 135, 12,  7,  70,  90, 10, 1),
    # ── 区域 1 迷雾森林 ──
    ("灰狼",      66, 15,  4,  18,  13,  2, 0),
    ("树精",      86, 13,  8,  22,  16,  3, 0),
    ("毒蝠",      58, 20,  3,  26,  19,  4, 0),
    ("藤蔓",      92, 17, 10,  25,  18, 17, 0),
    ("森林守望者",250, 20, 11, 130, 170, 11, 1),
    # ── 区域 2 废弃矿洞 ──
    ("石魔",     132, 17, 13,  34,  27,  5, 0),
    ("岩蜘蛛",   108, 24,  8,  36,  29, 19, 0),
    ("矿工幽灵", 120, 22, 10,  38,  31, 18, 0),
    ("洞穴蝙蝠",  96, 26,  6,  34,  28, 20, 0),
    ("矿洞巨魔", 420, 28, 17, 230, 280, 12, 1),
    # ── 区域 3 火山口 ──
    ("火蜥蜴",   212, 25, 12,  48,  38,  6, 0),
    ("熔岩傀儡", 280, 23, 20,  58,  46,  7, 0),
    ("火元素",   196, 31,  9,  56,  44, 21, 0),
    ("灰烬鸟",   176, 34,  7,  52,  41, 22, 0),
    ("熔岩魔王", 640, 36, 23, 400, 450, 13, 1),
    # ── 区域 4 暗黑城堡 ──
    ("不死骑士", 380, 31, 19,  74,  62,  8, 0),
    ("骨法师",   320, 40, 12,  82,  70,  9, 0),
    ("血仆",     350, 36, 15,  80,  68, 23, 0),
    ("幽影",     300, 43, 10,  78,  66, 24, 0),
    ("深渊领主", 840, 40, 24, 900, 1200, 14, 1),
]
# 每区域的 2 只小怪 + 1 只首领(索引到 ENEMIES)

# ══════════════════════════════════════════════════════════════
# 方块画精灵(12 宽 x 9 高, 字符: ' ' '.'=透明 可用 █▓░)
# ══════════════════════════════════════════════════════════════
F, H, L = "█", "▓", "░"
SPRITES = {
    0: [  # 史莱姆
        "            ",
        "    ▓▓▓▓    ",
        "  ▓██████▓  ",
        " ▓██░░░░██▓ ",
        " ████░░████ ",
        " ██████████ ",
        " ▓████████▓ ",
        "  ▓▓▓▓▓▓▓▓  ",
        "            ",
    ],
    1: [  # 野兔
        "            ",
        "  ▓      ▓  ",
        "  ▓▓    ▓▓  ",
        "  ▓██████▓  ",
        "  ▓█░██░█▓  ",
        "  ▓██████▓  ",
        "   ▓████▓   ",
        "   ▓▓  ▓▓   ",
        "            ",
    ],
    2: [  # 灰狼
        "            ",
        " ▓        ▓ ",
        " ▓▓      ▓▓ ",
        " ▓██▓▓▓▓██▓ ",
        " ▓█░████░█▓ ",
        " ▓████████▓ ",
        " ▓▓██████▓▓ ",
        "  ▓▓    ▓▓  ",
        "            ",
    ],
    3: [  # 树精
        "     ▓▓     ",
        "   ▓▓██▓▓   ",
        "  ▓██████▓  ",
        " ▓█░████░█▓ ",
        " ▓████████▓ ",
        "  ▓█▓██▓█▓  ",
        "   ▓████▓   ",
        "    ▓██▓    ",
        "     ▓▓     ",
    ],
    4: [  # 毒蝠
        "            ",
        " ▓▓      ▓▓ ",
        " ▓██▓  ▓██▓ ",
        " ▓████████▓ ",
        "  ▓█░██░█▓  ",
        "   ▓████▓   ",
        "    ▓██▓    ",
        "     ▓▓     ",
        "            ",
    ],
    5: [  # 石魔
        "            ",
        "  ▓▓▓▓▓▓▓▓  ",
        "  ▓██████▓  ",
        "  ▓█░██░█▓  ",
        "  ▓██████▓  ",
        "  ▓▓████▓▓  ",
        " ▓██▓▓▓▓██▓ ",
        " ▓▓      ▓▓ ",
        "            ",
    ],
    6: [  # 火蜥蜴
        "            ",
        "   ▓    ▓   ",
        "  ▓▓▓▓▓▓▓▓  ",
        " ▓████████▓ ",
        " ▓█░████░█▓ ",
        "  ▓██████▓  ",
        "  ▓▓████▓▓  ",
        "   ▓▓  ▓▓   ",
        "            ",
    ],
    7: [  # 熔岩傀儡
        "    ▓▓▓▓    ",
        "  ▓▓████▓▓  ",
        " ▓████████▓ ",
        " ▓█░████░█▓ ",
        " ▓████████▓ ",
        " ▓▓██████▓▓ ",
        "▓██▓▓▓▓▓▓██▓",
        "▓▓        ▓▓",
        "            ",
    ],
    8: [  # 不死骑士
        "     ▓▓     ",
        "    ▓██▓    ",
        "   ▓████▓   ",
        "   ▓█░░█▓   ",
        "    ▓██▓    ",
        "  ▓▓████▓▓  ",
        " ▓████████▓ ",
        "   ▓▓  ▓▓   ",
        "            ",
    ],
    9: [  # 骨法师
        "     ▓▓     ",
        "    ▓██▓    ",
        "   ▓█░░█▓   ",
        "    ▓██▓    ",
        "  ▓▓▓██▓▓▓  ",
        " ▓████████▓ ",
        "   ▓▓██▓▓   ",
        "     ▓▓     ",
        "            ",
    ],
    10: [  # 史莱姆王
        "   ▓ ▓ ▓ ▓  ",
        "  ▓██████▓  ",
        " ▓████████▓ ",
        "▓██░░░░░░██▓",
        "████░░░░████",
        "████████████",
        "▓██████████▓",
        " ▓▓▓▓▓▓▓▓▓▓ ",
        "            ",
    ],
    11: [  # 森林守望者
        "    ▓▓▓▓    ",
        "  ▓▓████▓▓  ",
        " ▓████████▓ ",
        "▓██░████░██▓",
        "▓██████████▓",
        " ▓██▓██▓██▓ ",
        "  ▓██████▓  ",
        "   ▓▓██▓▓   ",
        "    ▓▓▓▓    ",
    ],
    12: [  # 矿洞巨魔
        "   ▓▓▓▓▓▓   ",
        "  ▓██████▓  ",
        " ▓█░████░█▓ ",
        " ▓███▓▓███▓ ",
        "▓██████████▓",
        "▓█▓██████▓█▓",
        "▓▓ ▓████▓ ▓▓",
        "   ▓▓  ▓▓   ",
        "            ",
    ],
    13: [  # 熔岩魔王
        "▓          ▓",
        "▓▓  ▓▓▓▓  ▓▓",
        " ▓▓██████▓▓ ",
        "  ▓█░░░░█▓  ",
        " ▓████████▓ ",
        "▓██▓████▓██▓",
        "▓▓ ▓████▓ ▓▓",
        "   ▓▓  ▓▓   ",
        "            ",
    ],
    14: [  # 深渊领主
        "     ▓▓     ",
        "    ▓██▓    ",
        "   ▓████▓   ",
        "  ▓█░██░█▓  ",
        "  ▓██████▓  ",
        " ▓████████▓ ",
        "▓██▓████▓██▓",
        "▓▓  ▓██▓  ▓▓",
        "     ▓▓     ",
    ],
    15: [  # 田鼠
        "            ",
        "  ▓▓    ▓▓  ",
        " ▓██▓  ▓██▓ ",
        " ▓████████▓ ",
        " ▓█░███░██▓ ",
        "  ▓██████▓  ",
        "   ▓████▓ ▓ ",
        "    ▓▓▓▓ ▓▓ ",
        "            ",
    ],
    16: [  # 蜂群
        "            ",
        "   ▓  ░  ▓  ",
        "  ▓█▓▓█▓▓█  ",
        "   ▓░▓█▓░▓  ",
        " ▓█▓▓█▓▓█▓  ",
        "  ▓░▓█▓░▓▓  ",
        "   ▓▓█▓▓▓   ",
        "    ░ ▓ ░   ",
        "            ",
    ],
    17: [  # 藤蔓
        "  ▓   ▓   ▓ ",
        " ▓█▓ ▓█▓ ▓█▓",
        "  ▓▓  ▓▓  ▓▓",
        " ▓▓▓ ▓▓▓ ▓▓▓",
        "  ▓   ▓   ▓ ",
        " ▓▓  ▓▓  ▓▓ ",
        "▓█▓ ▓█▓ ▓█▓ ",
        " ▓   ▓   ▓  ",
        "            ",
    ],
    18: [  # 矿工幽灵
        "            ",
        "   ▓▓▓▓▓▓   ",
        "  ▓██████▓  ",
        " ▓██░██░██▓ ",
        " ▓████████▓ ",
        " ▓████████▓ ",
        " ▓██▓██▓██▓ ",
        "  ▓ ▓▓ ▓▓ ▓ ",
        "            ",
    ],
    19: [  # 岩蜘蛛
        "  ▓      ▓  ",
        "  ▓▓    ▓▓  ",
        " ▓▓▓▓▓▓▓▓▓▓ ",
        "  ▓██████▓  ",
        " ▓█░████░█▓ ",
        "  ▓██████▓  ",
        " ▓▓▓▓▓▓▓▓▓▓ ",
        "  ▓▓    ▓▓  ",
        "  ▓      ▓  ",
    ],
    20: [  # 洞穴蝙蝠
        "            ",
        "▓          ▓",
        "▓▓        ▓▓",
        "▓██▓    ▓██▓",
        "▓██████▓███▓",
        " ▓███░█░██▓ ",
        "  ▓██████▓  ",
        "   ▓▓  ▓▓   ",
        "            ",
    ],
    21: [  # 火元素
        "     ▓      ",
        "    ▓█▓     ",
        "   ▓███▓    ",
        "  ▓█████▓   ",
        " ▓███░███▓  ",
        " ▓██░░░██▓  ",
        " ▓███░███▓  ",
        "  ▓█████▓   ",
        "   ▓▓▓▓▓    ",
    ],
    22: [  # 灰烬鸟
        "            ",
        "     ▓▓     ",
        "    ▓██▓    ",
        "   ▓████▓   ",
        " ▓▓█████▓▓  ",
        "▓███████▓   ",
        " ▓▓████▓▓   ",
        "   ▓▓▓▓     ",
        "            ",
    ],
    23: [  # 血仆
        "            ",
        "   ▓▓▓▓▓▓   ",
        "  ▓██████▓  ",
        "  ▓█░██░█▓  ",
        "   ▓████▓   ",
        "  ▓██████▓  ",
        " ▓███▓▓███▓ ",
        " ▓▓▓    ▓▓▓ ",
        "            ",
    ],
    24: [  # 幽影
        "            ",
        "    ▓▓▓▓    ",
        "  ▓▓████▓▓  ",
        " ▓████████▓ ",
        " ▓██░██░██▓ ",
        " ▓████████▓ ",
        "  ▓██▓▓██▓  ",
        "  ▓▓ ▓▓ ▓▓  ",
        "            ",
    ],
}

AREA_ARTS = [
    ["            ","            ","   ░    ░   ","  ░░░  ░░░  ",
     "   ░    ░   ","            ","            ","▓▓▓▓▓▓▓▓▓▓▓▓","░░░░░░░░░░░░"],
    ["     ▓      ","    ▓█▓     ","   ▓███▓    ","  ▓█████▓   ",
     "    ▓█▓     ","   ▓███▓    ","  ▓█████▓   ","▓▓▓▓▓▓▓▓▓▓▓▓","░░░░░░░░░░░░"],
    ["            ","   ▓▓▓▓▓▓   ","  ▓██████▓  "," ▓██░░░░██▓ ",
     " ▓█░░░░░░█▓ "," ▓█░░░░░░█▓ "," ▓█░░░░░░█▓ ","▓▓▓▓▓▓▓▓▓▓▓▓","░░░░░░░░░░░░"],
    ["      ▓     ","     ▓█▓    ","    ▓███▓   ","   ▓█████▓  ",
     "  ▓███████▓ "," ▓██▓██▓██▓ ","▓▓▓▓▓▓▓▓▓▓▓▓","░░▓░░░░▓░░░░","░░░░░░░░░░░░"],
    ["  ▓  ▓▓  ▓  "," ▓█▓▓██▓▓█▓ "," ▓██▓██▓██▓ "," ▓████████▓ ",
     " ▓█░████░█▓ "," ▓████████▓ ","▓▓▓▓▓▓▓▓▓▓▓▓","░░░░░░░░░░░░","░░░░░░░░░░░░"],
]

# ══════════════════════════════════════════════════════════════
# 字形表: 自定义图元在前, 然后是所有字符串里出现的字符
# ══════════════════════════════════════════════════════════════
def build_glyphs(extra=()):
    codes = []          # code -> 显示名
    rows_of = {}        # 显示名 -> 16 行位图

    # 1) 自定义图元
    for i, (ch, kind) in enumerate(CUSTOM):
        name = "space" if kind is None else ch
        codes.append(name)
        rows_of[name] = [0] * 16 if kind is None else _tile(kind)

    # 2) 收集字符
    used = []
    def scan(s):
        for c in s:
            if c not in used:
                used.append(c)
    for s in SPRITES.values():
        for line in s:
            scan(line)
    for s in AREA_ARTS:
        for line in s:
            scan(line)
    for name, *_ in ENEMIES:
        scan(name)
    for name, _, _ in AREAS:
        scan(name)
    for t in extra:
        scan(t)
    scan("0123456789")   # 数字必须常驻: NUM 指令运行时要用

    # ASCII 先排, 中文按出现顺序
    used = sorted([c for c in used if ord(c) < 128]) + [c for c in used if ord(c) >= 128]

    fr = FontRaster()
    for c in used:
        if c == " ":
            codes.append("space")
            rows_of["space"] = [0] * 16
            continue
        if c in "█▓░":
            kind = {"█": "full", "▓": "dense", "░": "shade"}[c]
            codes.append(c)
            rows_of[c] = _tile(kind)
            continue
        codes.append(c)
        rows_of[c] = fr.render(c)

    if len(codes) > 511:
        print("".join(c for c in codes if len(c)==1 and ord(c)>=128))
        raise SystemExit("字形数 %d 超过 511(9bit 字形码上限), 需要精简文本" % len(codes))
    idx = {}
    for i, n in enumerate(codes):
        if n not in idx:
            idx[n] = i
    return codes, rows_of, idx



def g(ch):
    """字符 -> 字形码"""
    if ch == " ":
        return 0
    return GIDX[ch]

# ══════════════════════════════════════════════════════════════
# 屏幕指令
# ══════════════════════════════════════════════════════════════
OP_END, OP_CLEAR, OP_COLOR, OP_TEXT, OP_NUM, OP_ART, OP_BAR, \
OP_ENAME, OP_ANAME, OP_MSG, OP_FRAME, OP_ADESC = range(12)

SRC = {"hp": 0, "maxhp": 1, "mp": 2, "maxmp": 3, "atk": 4, "def": 5,
       "gold": 6, "lv": 7, "exp": 8, "need": 9, "pot": 10, "potxl": 11,
       "kills": 12, "ehp": 13, "emaxhp": 14, "dmg": 15,
       "herb": 16}

def S(x, y, s, fg=WHITE, bg=BLACK):
    return [("color", fg, bg), ("text", x, y, s)]

def N(x, y, src, digits, fg=WHITE, bg=BLACK):
    return [("color", fg, bg), ("num", x, y, SRC[src], digits)]

def BAR(x, y, cur, mx, w, fg=GREEN, bg=DGRAY):
    return [("color", fg, bg), ("bar", x, y, SRC[cur], SRC[mx], w)]

def FRAME(x, y, w, h, fg=GRAY):
    return [("color", fg, BLACK), ("frame", x, y, w, h)]


def stat_row(y, label, cur, mx, col=RPG_RED, bw=10):
    return (S(2, y, label, RPG_GRAY) + BAR(5, y, cur, mx, bw, col, DGRAY)
            + N(16, y, cur, 3, WHITE) + S(19, y, "/", RPG_GRAY) + N(20, y, mx, 3, RPG_GRAY))


def screen_title():
    o = [("clear", BLACK)]
    o += FRAME(0, 0, 40, 30, RPG_GRAY)
    o += FRAME(9, 2, 22, 7, RPG_LGRAY)
    o += S(18, 3, "字界远征", YELLOW)
    o += S(14, 4, "ASCII QUEST", GREEN)
    o += S(19, 6, "2026", RPG_GRAY)
    o += S(16, 10, "字符搭成的世界", RPG_LGRAY)
    o += S(15, 17, "按 1 开始冒险", WHITE)
    o += S(15, 19, "按 2 看图", RPG_LGRAY)
    o += S(12, 21, "板载按键 1-4 操作", RPG_GRAY)
    o += [("end",)]
    return o


def screen_pic():
    """动态插图页：中央 16x12 格留给图片层（视频端盖上去），四周是文字"""
    o = [("clear", BLACK)]
    o += FRAME(0, 0, 40, 30, RPG_GRAY)
    o += S(2, 1, "营地", YELLOW)
    o += FRAME(11, 8, 18, 14, DGRAY)          # 框住 16x12 的图片区
    o += S(2, 3, "128X96", RPG_LGRAY)
    o += S(2, 23, "篝火", WHITE)
    o += S(2, 26, "1 上 2 下 3 停 4 返", RPG_GRAY)
    o += [("end",)]
    return o


def screen_class():
    o = [("clear", BLACK)]
    o += FRAME(0, 0, 40, 30, RPG_GRAY)
    o += S(2, 1, "选择职业", YELLOW)
    o += S(14, 1, "1 剑士   2 法师   3 游侠", WHITE)
    o += FRAME(1, 3, 38, 7, DGRAY)
    o += S(3, 4, "剑士", ORANGE)
    o += S(9, 4, "血厚防高，重斩破甲", RPG_LGRAY)
    o += S(3, 6, "生命", RPG_GRAY); o += N(7, 6, "hp", 3, WHITE)
    o += S(13, 6, "攻击", RPG_GRAY); o += N(17, 6, "atk", 3, WHITE)
    o += FRAME(1, 11, 38, 7, DGRAY)
    o += S(3, 12, "法师", CYAN)
    o += S(9, 12, "爆发极高，火球无视护甲", RPG_LGRAY)
    o += S(3, 14, "魔力", RPG_GRAY); o += N(7, 14, "mp", 3, WHITE)
    o += S(13, 14, "攻击", RPG_GRAY); o += N(17, 14, "atk", 3, WHITE)
    o += FRAME(1, 19, 38, 7, DGRAY)
    o += S(3, 20, "游侠", GREEN)
    o += S(9, 20, "暴击率高，三连射", RPG_LGRAY)
    o += S(3, 22, "生命", RPG_GRAY); o += N(7, 22, "hp", 3, WHITE)
    o += S(13, 22, "攻击", RPG_GRAY); o += N(17, 22, "atk", 3, WHITE)
    o += S(8, 27, "按 1 / 2 / 3 选择职业", WHITE)
    o += [("end",)]
    return o


def screen_map():
    o = [("clear", BLACK)]
    o += FRAME(0, 0, 40, 30, RPG_GRAY)
    o += S(2, 1, "字界远征", YELLOW)
    o += S(11, 1, "·", RPG_GRAY)
    o += [("color", RPG_LGRAY, BLACK), ("aname", 13, 1)]
    o += [("color", RPG_GRAY, BLACK), ("frame", 1, 2, 38, 1)]
    o += [("color", RPG_LGRAY, BLACK), ("adesc", 2, 4)]
    o += S(2, 5, "远处有东西在动", RPG_LGRAY)
    o += [("color", RPG_GRAY, BLACK), ("art", 15, 4, 254)]
    o += [("color", RPG_GRAY, BLACK), ("frame", 1, 13, 38, 1)]
    o += S(2, 14, "勇者", WHITE)
    o += S(7, 14, "级", RPG_GRAY); o += N(9, 14, "lv", 2, YELLOW)
    o += S(14, 14, "攻击", RPG_GRAY); o += N(18, 14, "atk", 3, WHITE)
    o += S(23, 14, "防御", RPG_GRAY); o += N(27, 14, "def", 3, WHITE)
    o += stat_row(16, "生命", "hp", "maxhp", 5)
    o += stat_row(18, "魔力", "mp", "maxmp", CYAN)
    o += S(2, 20, "金币", RPG_GRAY); o += N(6, 20, "gold", 5, YELLOW)
    o += S(8, 20, "药草", RPG_GRAY); o += N(12, 20, "herb", 2, WHITE)
    o += S(17, 20, "药水", RPG_GRAY); o += N(21, 20, "pot", 2, WHITE)
    o += S(26, 20, "大药水", RPG_GRAY); o += N(32, 20, "potxl", 2, WHITE)
    o += S(2, 22, "讨伐", RPG_GRAY); o += N(6, 22, "kills", 2, WHITE)
    o += S(9, 22, "/4", RPG_GRAY)
    o += S(14, 22, "经验", RPG_GRAY); o += N(18, 22, "exp", 4, WHITE)
    o += S(23, 22, "/", RPG_GRAY); o += N(24, 22, "need", 4, RPG_GRAY)
    o += [("color", RPG_GRAY, BLACK), ("frame", 1, 24, 38, 1)]
    o += S(2, 26, "1", YELLOW); o += S(4, 26, "探索", WHITE)
    o += S(12, 26, "2", YELLOW); o += S(14, 26, "商店", WHITE)
    o += S(22, 26, "3", YELLOW); o += S(24, 26, "休息", WHITE)
    o += S(32, 26, "4", YELLOW); o += S(34, 26, "首领", WHITE)
    o += [("end",)]
    return o


def screen_battle():
    o = [("clear", BLACK)]
    o += FRAME(0, 0, 40, 30, RPG_RED)
    o += [("color", WHITE, BLACK), ("ename", 2, 1)]
    o += S(18, 1, "生命", RPG_GRAY)
    o += BAR(21, 1, "ehp", "emaxhp", 12, RPG_RED, DGRAY)
    o += [("color", RPG_GRAY, BLACK), ("frame", 1, 2, 38, 1)]
    o += [("color", MAGENTA, BLACK), ("art", 14, 3, 255)]
    o += [("color", RPG_GRAY, BLACK), ("frame", 1, 12, 38, 1)]
    o += [("color", WHITE, BLACK), ("msg", 2, 13)]
    o += S(2, 15, "伤害", RPG_GRAY); o += N(6, 15, "dmg", 4, ORANGE)
    o += [("color", RPG_GRAY, BLACK), ("frame", 1, 17, 38, 1)]
    o += stat_row(18, "生命", "hp", "maxhp", RPG_RED)
    o += stat_row(20, "魔力", "mp", "maxmp", CYAN)
    o += [("color", RPG_GRAY, BLACK), ("frame", 1, 22, 38, 1)]
    o += S(2, 24, "1 攻击", YELLOW)
    o += S(11, 24, "2 技能", CYAN)
    o += S(20, 24, "3 药水", GREEN)
    o += S(29, 24, "4 逃跑", RPG_GRAY)
    o += S(2, 26, "技能耗魔力，威力高", DGRAY)
    o += [("end",)]
    return o


def screen_shop():
    """补给站 第 1 页：消耗品"""
    o = [("clear", BLACK)]
    o += FRAME(0, 0, 40, 30, RPG_GRAY)
    o += S(2, 1, "补给站", YELLOW)
    o += S(13, 1, "金币", RPG_GRAY); o += N(17, 1, "gold", 5, YELLOW)
    o += S(25, 1, "第 1/2 页", DGRAY)
    o += [("color", RPG_GRAY, BLACK), ("frame", 1, 2, 38, 1)]
    o += S(2, 4, "今天想买点什么", RPG_LGRAY)

    o += FRAME(1, 6, 38, 3, DGRAY)
    o += S(2, 7, "1", YELLOW); o += S(4, 7, "药草", WHITE)
    o += S(10, 7, "回复 30 生命", RPG_GRAY); o += S(28, 7, "15 金", YELLOW)

    o += FRAME(1, 10, 38, 3, DGRAY)
    o += S(2, 11, "2", YELLOW); o += S(4, 11, "药水", WHITE)
    o += S(10, 11, "回复 60 生命", RPG_GRAY); o += S(28, 11, "30 金", YELLOW)

    o += FRAME(1, 14, 38, 3, DGRAY)
    o += S(2, 15, "3", YELLOW); o += S(4, 15, "大药水", WHITE)
    o += S(10, 15, "回复 150 生命", RPG_GRAY); o += S(27, 15, "60 金", YELLOW)

    o += S(2, 19, "4", YELLOW); o += S(4, 19, "看看装备", RPG_GRAY)

    o += [("color", RPG_GRAY, BLACK), ("frame", 1, 21, 38, 1)]
    o += S(2, 23, "药草", RPG_GRAY); o += N(6, 23, "herb", 2, WHITE)
    o += S(9, 23, "药水", RPG_GRAY); o += N(13, 23, "pot", 2, WHITE)
    o += S(16, 23, "大药水", RPG_GRAY); o += N(22, 23, "potxl", 2, WHITE)
    o += S(2, 25, "攻击", RPG_GRAY); o += N(6, 25, "atk", 3, WHITE)
    o += S(12, 25, "防御", RPG_GRAY); o += N(16, 25, "def", 3, WHITE)
    o += S(2, 27, "打不过就多备点药", DGRAY)
    o += [("end",)]
    return o


def screen_shop2():
    """补给站 第 2 页：永久强化"""
    o = [("clear", BLACK)]
    o += FRAME(0, 0, 40, 30, RPG_GRAY)
    o += S(2, 1, "补给站 · 装备", YELLOW)
    o += S(13, 1, "金币", RPG_GRAY); o += N(17, 1, "gold", 5, YELLOW)
    o += S(25, 1, "第 2/2 页", DGRAY)
    o += [("color", RPG_GRAY, BLACK), ("frame", 1, 2, 38, 1)]
    o += S(2, 4, "买件像样的东西", RPG_LGRAY)

    o += FRAME(1, 6, 38, 3, DGRAY)
    o += S(2, 7, "1", YELLOW); o += S(4, 7, "力量护符", WHITE)
    o += S(12, 7, "攻击永久 +3", RPG_GRAY); o += S(27, 7, "120 金", YELLOW)

    o += FRAME(1, 10, 38, 3, DGRAY)
    o += S(2, 11, "2", YELLOW); o += S(4, 11, "守护护符", WHITE)
    o += S(12, 11, "防御永久 +3", RPG_GRAY); o += S(27, 11, "120 金", YELLOW)

    o += FRAME(1, 14, 38, 3, DGRAY)
    o += S(2, 15, "3", YELLOW); o += S(4, 15, "大师之证", WHITE)
    o += S(12, 15, "攻防各 +3", RPG_GRAY); o += S(27, 15, "200 金", YELLOW)

    o += S(2, 19, "4", YELLOW); o += S(4, 19, "回地图", RPG_GRAY)

    o += [("color", RPG_GRAY, BLACK), ("frame", 1, 21, 38, 1)]
    o += S(2, 23, "当前攻击", RPG_GRAY); o += N(10, 23, "atk", 3, WHITE)
    o += S(15, 23, "当前防御", RPG_GRAY); o += N(23, 23, "def", 3, WHITE)
    o += S(2, 25, "护符效果永久保留", DGRAY)
    o += S(2, 27, "金币不够就去多打几场", DGRAY)
    o += [("end",)]
    return o


def screen_dead():
    o = [("clear", BLACK)]
    o += FRAME(0, 0, 40, 30, RPG_DRED)
    o += S(16, 4, "你倒下了", RPG_RED)
    o += [("color", RPG_DRED, BLACK), ("art", 14, 8, 8)]
    o += S(9, 19, "在补给站醒来，进度归零", RPG_LGRAY)
    o += S(11, 23, "1  重新出发", WHITE)
    o += [("end",)]
    return o


def screen_win():
    o = [("clear", BLACK)]
    o += FRAME(0, 0, 40, 30, YELLOW)
    o += S(16, 2, "通  关", YELLOW)
    o += [("color", MAGENTA, BLACK), ("art", 14, 5, 14)]
    o += S(7, 15, "深渊领主已被击败", RPG_LGRAY)
    o += S(6, 17, "世界重新排好版", RPG_LGRAY)
    o += S(2, 21, "最终等级", RPG_GRAY); o += N(11, 21, "lv", 2, WHITE)
    o += S(2, 22, "剩余金币", RPG_GRAY); o += N(11, 22, "gold", 5, YELLOW)
    o += S(2, 23, "总击杀", RPG_GRAY); o += N(10, 23, "kills", 3, WHITE)
    o += S(13, 26, "1  再来一次", WHITE)
    o += [("end",)]
    return o


MSGS = [
    ("MSG_NONE",    ""),
    ("MSG_HIT",     "你发起攻击"),
    ("MSG_SKILL",   "技能发动"),
    ("MSG_POTION",  "喝下药水"),
    ("MSG_NOMANA",  "魔力不足"),
    ("MSG_ENEMY",   "敌人反击"),
    ("MSG_KILL",    "击败了敌人"),
    ("MSG_LEVEL",   "等级提升"),
    ("MSG_NOPOT",   "没有药水"),
    ("MSG_NOGOLD",  "金币不够"),
    ("MSG_FLEE",    "逃掉了"),
    ("MSG_FAIL",    "逃跑失败"),
    ("MSG_REST",    "休息了一会儿"),
    ("MSG_BUY",     "买好了"),
    ("MSG_UPGRADE", "强化了"),
    ("MSG_NOKILLS", "讨伐还不够"),
]

SCREENS = {
    "title":  screen_title(),
    "class":  screen_class(),
    "map":    screen_map(),
    "battle": screen_battle(),
    "shop":   screen_shop(),
    "shop2":  screen_shop2(),
    "dead":   screen_dead(),
    "win":    screen_win(),
    "pic":    screen_pic(),
}

_extra_text = [op[3] for ops in SCREENS.values() for op in ops if op[0] == "text"]
_extra_text += [t for _, t in MSGS]
_extra_text += ADESS          # 区域环境描述也要进字库
CODES, ROWS_OF, GIDX = build_glyphs(_extra_text)

# ══════════════════════════════════════════════════════════════
# 编码: 指令表 / 字符串表 / 精灵表
# ══════════════════════════════════════════════════════════════
class Blob:
    def __init__(self):
        self.data = []

    def add_bytes(self, bs):
        a = len(self.data)
        self.data.extend(bs)
        return a

CMD_ROM = []          # (op,y,x,arg)
STR = Blob()
ART = Blob()
SCREEN_ADDR = {}

def enc_string(s):
    """写入字符串表, 返回起始地址(以字形为单位), 末尾 0xFF 结束"""
    return STR.add_bytes([g(c) for c in s] + [0xFFFF])

def emit(ops):
    out = []
    for op in ops:
        k = op[0]
        if k == "end":
            out.append((OP_END, 0, 0, 0))
        elif k == "clear":
            out.append((OP_CLEAR, 0, 0, op[1]))
        elif k == "color":
            out.append((OP_COLOR, 0, 0, (op[2] << 4) | op[1]))
        elif k == "text":
            x, y, s = op[1], op[2], op[3]
            out.append((OP_TEXT, y, x, enc_string(s)))
        elif k == "num":
            x, y, src, dg = op[1], op[2], op[3], op[4]
            out.append((OP_NUM, y, x, ((dg & 0xF) << 8) | (src & 0x1F)))
        elif k == "bar":
            x, y, a, b, w = op[1], op[2], op[3], op[4], op[5]
            # arg[3:0]=cur源 arg[7:4]=max源 arg[12:8]=宽度(格数)
            out.append((OP_BAR, y, x, ((w & 0x1F) << 8) | ((b & 0xF) << 4) | (a & 0xF)))
        elif k == "art":
            x, y, aid = op[1], op[2], op[3]
            out.append((OP_ART, y, x, aid))
        elif k == "ename":
            out.append((OP_ENAME, op[2], op[1], 0))
        elif k == "aname":
            out.append((OP_ANAME, op[2], op[1], 0))
        elif k == "adesc":
            out.append((OP_ADESC, op[2], op[1], 0))
        elif k == "msg":
            out.append((OP_MSG, op[2], op[1], 0))
        elif k == "frame":
            x, y, w, h = op[1], op[2], op[3], op[4]
            out.append((OP_FRAME, y, x, ((h & 0x1F) << 8) | (w & 0x3F)))
        else:
            raise SystemExit("未知指令 " + k)
    return out

# 名字表: 区域名 6 格, 敌人名 7 格
NAME_AREA_W, NAME_ENEMY_W = 6, 7
AREA_NAMES = Blob()
for name, _, _ in AREAS:
    s = [g(c) for c in name]
    s = (s + [0] * NAME_AREA_W)[:NAME_AREA_W]
    AREA_NAMES.add_bytes(s)

ENEMY_NAMES = Blob()
for name, *_ in ENEMIES:
    s = [g(c) for c in name]
    s = (s + [0] * NAME_ENEMY_W)[:NAME_ENEMY_W]
    ENEMY_NAMES.add_bytes(s)

# 精灵表: 每个 16 宽 x 9 高
SPR_W, SPR_H = 12, 9
SPR_BASE = {}
for sid, rows in SPRITES.items():
    a = ART.add_bytes([g(c) for line in rows for c in line.ljust(SPR_W)])
    SPR_BASE[sid] = a
# 地图/结局用的图标(用现有字符凑)
MAP_ICON = ART.add_bytes([g(c) for line in [
    "      ▓▓      ",
    "    ▓▓██▓▓    ",
    "  ▓▓██████▓▓  ",
    "▓▓██████████▓▓",
    "▓▓██████████▓▓",
    "  ▓▓██████▓▓  ",
    "    ▓▓██▓▓    ",
    "      ▓▓      ",
    "              ",
] for c in line])
for i, rows in enumerate(AREA_ARTS):
    SPR_BASE[30 + i] = ART.add_bytes([g(c) for line in rows for c in line.ljust(SPR_W)])
SPR_BASE[20] = MAP_ICON
SPR_BASE[15] = SPR_BASE[8]      # 死亡页借用骑士图
SPR_BASE[14] = SPR_BASE[14]

for k, ops in SCREENS.items():
    SCREEN_ADDR[k] = len(CMD_ROM)
    CMD_ROM.extend(emit(ops))

print("字形数:", len(CODES))
print("指令数:", len(CMD_ROM))
print("字符串字节:", len(STR.data))
print("精灵字节:", len(ART.data))
print("屏幕地址:", SCREEN_ADDR)

# ══════════════════════════════════════════════════════════════
# 预览: 用和 RTL 相同的解释器把界面画成 BMP, 便于核对排版
# ══════════════════════════════════════════════════════════════
SAMPLE = {"hp": 118, "maxhp": 130, "mp": 32, "maxmp": 40, "atk": 16, "def": 11,
          "gold": 1430, "lv": 3, "exp": 41, "need": 78, "pot": 2, "potxl": 1,
          "kills": 2, "ehp": 22, "emaxhp": 36, "dmg": 11}
SAMPLE_MSG = "你发起攻击"
SAMPLE_ID = {SRC[k]: v for k, v in SAMPLE.items() if k in SRC}


def draw_ops(ops, enemy_id=0, area_id=0, msg_text=SAMPLE_MSG, dyn_sprite=None):
    grid = [[(0, LGRAY, BLACK) for _ in range(COLS)] for _ in range(ROWS)]
    fg, bg = WHITE, BLACK

    def put(x, y, code, f, b):
        if 0 <= x < COLS and 0 <= y < ROWS:
            grid[y][x] = (code, f, b)

    def put_str(x, y, s, f, b):
        for i, c in enumerate(s):
            put(x + i, y, g(c), f, b)

    def put_name(x, y, blob, idx, width, f, b):
        for i in range(width):
            put(x + i, y, blob.data[idx * width + i], f, b)

    for op in ops:
        k = op[0]
        if k == "clear":
            grid = [[(0, 0, op[1]) for _ in range(COLS)] for _ in range(ROWS)]   # 清屏: 空格 fg=0, 与 RTL 一致
        elif k == "color":
            fg, bg = op[1], op[2]
        elif k == "text":
            put_str(op[1], op[2], op[3], fg, bg)
        elif k == "num":
            x, y, src, dg = op[1], op[2], op[3], op[4]
            val = str(SAMPLE_ID.get(src, 0))[:dg]
            put_str(x, y, val, fg, bg)
        elif k == "bar":
            x, y, a, b, w = op[1], op[2], op[3], op[4], op[5]
            cur, mx = SAMPLE_ID.get(a, 0), SAMPLE_ID.get(b, 1)
            n = 0 if mx == 0 else max(0, min(w, (cur * w) // mx))
            for i in range(w):
                put(x + i, y, GIDX["T_FULL"] if i < n else GIDX["T_SHADE"], fg, bg)
        elif k == "art":
            if op[3] == 254:
                spr = 30 + area_id
            else:
                spr = dyn_sprite if op[3] == 255 else op[3]
            base = SPR_BASE[spr]
            afg = art_color(spr)          # 颜色按精灵档位取, 不用指令里的 fg
            for r in range(SPR_H):
                for c in range(SPR_W):
                    code = ART.data[base + r * SPR_W + c]
                    put(op[1] + c, op[2] + r, code, afg, bg)
        elif k == "ename":
            put_name(op[1], op[2], ENEMY_NAMES, enemy_id, NAME_ENEMY_W, fg, bg)
        elif k == "aname":
            put_name(op[1], op[2], AREA_NAMES, area_id, NAME_AREA_W, fg, bg)
        elif k == "msg":
            put_str(op[1], op[2], msg_text, fg, bg)
        elif k == "frame":
            x, y, w, h = op[1], op[2], op[3], op[4]
            for i in range(w):
                put(x + i, y, GIDX["T_H"] if 0 < i < w - 1 else GIDX["T_TL" if i == 0 else "T_TR"], fg, bg)
                put(x + i, y + h - 1, GIDX["T_H"] if 0 < i < w - 1 else GIDX["T_BL" if i == 0 else "T_BR"], fg, bg)
            for j in range(1, h - 1):
                put(x, y + j, GIDX["T_V"], fg, bg)
                put(x + w - 1, y + j, GIDX["T_V"], fg, bg)
    return grid


def grid_to_png(grid, path, scale=2):
    """用 zlib 手写 PNG, 不依赖 PIL"""
    import zlib
    W, H = COLS * 16 * scale, ROWS * 16 * scale
    raw = bytearray()
    for py in range(H):
        raw.append(0)                      # 行过滤: 无
        cy, ry = divmod(py, 16 * scale)
        for px in range(W):
            cx, rx = divmod(px, 16 * scale)
            code, f, b = grid[cy][cx]
            bits = ROWS_OF[CODES[code]]
            on = (bits[ry // scale] >> (15 - rx // scale)) & 1
            rgb = PALETTE[f if on else b]
            r = ((rgb >> 11) & 0x1F) * 255 // 31
            g_ = ((rgb >> 5) & 0x3F) * 255 // 63
            bb = (rgb & 0x1F) * 255 // 31
            raw += bytes((r, g_, bb))

    def chunk(tag, data):
        c = tag + data
        return struct.pack(">I", len(data)) + c + struct.pack(">I", zlib.crc32(c) & 0xFFFFFFFF)

    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", W, H, 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(bytes(raw), 6))
    png += chunk(b"IEND", b"")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as fp:
        fp.write(png)


PREVIEWS = [
    ("title", dict()),
    ("class", dict()),
    ("map", dict(area_id=0)),
    ("battle", dict(enemy_id=0, dyn_sprite=0, msg_text="你发起攻击")),
    ("battle", dict(enemy_id=14, dyn_sprite=14, msg_text="深渊领主反击")),
    ("shop", dict()),
    ("dead", dict()),
    ("win", dict()),
]
for i, (name, kw) in enumerate(PREVIEWS):
    grid = draw_ops(SCREENS[name], **kw)
    fn = os.path.join(PREV, "%d_%s.png" % (i, name))
    grid_to_png(grid, fn)
    print("预览:", fn)

# ══════════════════════════════════════════════════════════════
# 输出 Verilog / hex
# ══════════════════════════════════════════════════════════════
os.makedirs(GEN, exist_ok=True)


def w_hex(name, words, width):
    with open(os.path.join(GEN, name), "w", encoding="ascii", newline="\n") as f:
        for v in words:
            f.write(("%0*X\n" % (width // 4, v)))


font_words = []
for code in range(512):
    if code < len(CODES):
        rows = ROWS_OF[CODES[code]]
    else:
        rows = [0] * 16
    font_words.extend(rows)
w_hex("font.hex", font_words, 16)

cmd_words = []
for (op, y, x, arg) in CMD_ROM:
    cmd_words.append((op << 28) | (y << 23) | (x << 17) | (arg & 0x1FFFF))
w_hex("cmd.hex", cmd_words, 32)

w_hex("str.hex", STR.data, 16)
w_hex("art.hex", ART.data, 8)

# 名字表 -> Verilog case
area_case = []
for i, (name, _, _) in enumerate(AREAS):
    chars = [g(c) for c in name]
    chars = (chars + [0] * 6)[:6]
    v = 0
    for k, c in enumerate(chars):
        v |= c << (k * 9)
    area_case.append("      4'd%d: area_name = 54'h%014X;" % (i, v))

enemy_name_case = []
for i, row in enumerate(ENEMIES):
    chars = [g(c) for c in row[0]]
    chars = (chars + [0] * 7)[:7]
    v = 0
    for k, c in enumerate(chars):
        v |= c << (k * 9)
    enemy_name_case.append("      5'd%d: ename = 63'h%016X;" % (i, v))

enemy_stat_case = []
for i, (nm, hp, atk, df, exp, gold, spr, boss) in enumerate(ENEMIES):
    v = (hp & 0x3FF) | ((atk & 0xFF) << 10) | ((df & 0xFF) << 18) | \
        ((exp & 0x3FF) << 26) | ((gold & 0xFFF) << 36) | \
        ((spr & 0x1F) << 48) | ((boss & 1) << 53) | ((i & 0x1F) << 54)
    enemy_stat_case.append("      5'd%d: es = 64'h%016X;" % (i, v))

adesc_addr = [enc_string(t) for t in ADESS]
adesc_case = []
for i, a in enumerate(adesc_addr):
    adesc_case.append("      3'd%d: adesc = 11'd%d;" % (i, a))

area_mob_case = []
for i, (nm, mobs, boss) in enumerate(AREAS):
    v = ((mobs[0] & 0x1F) | ((mobs[1] & 0x1F) << 5) |
         ((mobs[2] & 0x1F) << 10) | ((mobs[3] & 0x1F) << 15) |
         ((boss & 0x1F) << 20))
    area_mob_case.append("      3'd%d: am = 25'h%07X;" % (i, v))

msg_addr = {}
for name, text in MSGS:
    if text == "":
        msg_addr[name] = enc_string(" ")
    else:
        msg_addr[name] = enc_string(text)

# 消息字符串是在上面才追加进去的, 所以必须重新写一次 str.hex。
# (原来漏了这步, 结果 MSG 读到表尾之外, 整个战斗页被刷成垃圾)
w_hex("str.hex", STR.data, 16)
print("字符串表最终长度: %d 字节 (含 %d 条消息)" % (len(STR.data), len(MSGS)))

msg_lines = "\n".join("    localparam [10:0] %-14s = 11'd%d;" % (n, a)
                       for n, a in msg_addr.items())

art_lines = "\n".join("            6'd%-3d: b = 12'd%d;" % (k, v) for k, v in sorted(SPR_BASE.items()))

defs_lines = "\n".join("`define %-14s 11'd%d" % (n, a) for n, a in msg_addr.items())
defs_lines += "\n`define G_DIG_BASE     9'd%d" % GIDX["0"]   # '0'..'9' 连续排布
with open(os.path.join(GEN, "rpg_defs.vh"), "w", encoding="utf-8", newline="\n") as f:
    f.write("// 自动生成: 消息字符串地址(用 `include \"rpg_defs.vh\" 引入)\n")
    f.write("`ifndef RPG_DEFS_VH\n`define RPG_DEFS_VH\n")
    f.write(defs_lines + "\n")
    f.write("`endif\n")

art_lines = "\n".join("            6'd%-3d: b = 12'd%d;" % (k, v) for k, v in sorted(SPR_BASE.items()))

msgs_v = """//=============================================================================
// rpg_msgs.v —— 自动生成: 精灵基址表(每个精灵 12x9 = 108 字节)
//=============================================================================
`timescale 1ns/1ps
module rpg_artbase (
    input  wire [5:0]  id,
    output reg  [11:0] b
);
    always @(*) begin
        case (id)
%s
            default: b = 12'd0;
        endcase
    end
endmodule
""" % art_lines

with open(os.path.join(GEN, "rpg_msgs.v"), "w", encoding="utf-8", newline="\n") as f:
    f.write(msgs_v)

ui_v = """//=============================================================================
// ui_rom.v —— 由 tools/build_rom.py 自动生成, 不要手改
//
// 四个 ROM 用 $readmemh 初始化, 综合前请把 rtl/gen 目录加入 TD 的
// 文件搜索路径(或把 hex 拷到工程根目录并改下面的路径)。
//
// 指令格式(32bit): op[31:28] y[27:23] x[22:17] arg[16:0]
//   0 END  1 CLEAR(bg)  2 COLOR(fg,bg)  3 TEXT(arg=str_addr)
//   4 NUM(arg[7:0]=src, arg[11:8]=位数)  5 ART(arg=精灵号)
//   6 BAR(arg[7:0]=cur, arg[15:8]=max, 宽固定 12)  7 ENAME  8 ANAME
//   9 MSG  10 FRAME(arg[5:0]=w, arg[12:8]=h)
//=============================================================================
`timescale 1ns/1ps

module font_rom (
    input  wire        clk,
    input  wire [8:0]  glyph,
    input  wire [3:0]  row,
    output reg  [15:0] data
);
    reg [15:0] mem [0:8191];
    initial $readmemh("rtl/gen/font.hex", mem);
    always @(posedge clk) data <= mem[{glyph, row}];
endmodule

module cmd_rom (
    input  wire        clk,
    input  wire [9:0]  addr,
    output reg  [31:0] data
);
    reg [31:0] mem [0:1023];
    initial $readmemh("rtl/gen/cmd.hex", mem);
    always @(posedge clk) data <= mem[addr];
endmodule

module str_rom (
    input  wire       clk,
    input  wire [10:0] addr,
    output reg  [15:0] data
);
    reg [15:0] mem [0:2047];
    initial $readmemh("rtl/gen/str.hex", mem);
    always @(posedge clk) data <= mem[addr];
endmodule

module art_rom (
    input  wire        clk,
    input  wire [11:0] addr,
    output reg  [7:0]  data
);
    reg [7:0] mem [0:4095];
    initial $readmemh("rtl/gen/art.hex", mem);
    always @(posedge clk) data <= mem[addr];
endmodule

//-----------------------------------------------------------------------------
// 数据表(直接综合成查找表)
//-----------------------------------------------------------------------------
module rpg_tables (
    input  wire [4:0]  ename_id,
    input  wire [2:0]  area_id,
    input  wire [4:0]  stat_id,
    input  wire        sel,          // 0=名字 1=数值
    output reg  [62:0] ename,
    output reg  [53:0] area_name,
    output reg  [54:0] adesc,
    output reg  [63:0] es
);
    always @(*) begin
        case (ename_id)
%s
        default: ename = 63'd0;
        endcase
    end

    always @(*) begin
        case (area_id)
%s
        default: area_name = 54'd0;
        endcase
    end

    always @(*) begin
        case (area_id)
%s
        default: adesc = 55'd0;
        endcase
    end

    always @(*) begin
        case (stat_id)
%s
        default: es = 64'd0;
        endcase
    end
endmodule

//-----------------------------------------------------------------------------
// 区域 -> 怪物索引
//-----------------------------------------------------------------------------
module rpg_area (
    input  wire [2:0]  area,
    output reg  [4:0]  mob0,
    output reg  [4:0]  mob1,
    output reg  [4:0]  mob2,
    output reg  [4:0]  mob3,
    output reg  [4:0]  boss
);
    reg [24:0] am;
    always @(*) begin
        case (area)
%s
        default: am = 25'd0;
        endcase
        mob0 = am[4:0];
        mob1 = am[9:5];
        mob2 = am[14:10];
        mob3 = am[19:15];
        boss = am[24:20];
    end
endmodule

//-----------------------------------------------------------------------------
// 语句表地址
//-----------------------------------------------------------------------------
module rpg_screens (
    input  wire [3:0]  scene,
    output reg  [9:0]  addr
);
    always @(*) begin
        case (scene)
            4'd0: addr = 10'd%d;   // title
            4'd1: addr = 10'd%d;   // class
            4'd2: addr = 10'd%d;   // map
            4'd3: addr = 10'd%d;   // battle
            4'd4: addr = 10'd%d;   // shop
            4'd5: addr = 10'd%d;   // dead
            4'd6: addr = 10'd%d;   // win
            4'd7: addr = 10'd%d;   // pic
            4'd8: addr = 10'd%d;   // shop2
            default: addr = 10'd0;
        endcase
    end
endmodule
""" % ("\n".join(enemy_name_case), "\n".join(area_case), "\n".join(adesc_case),
       "\n".join(enemy_stat_case),
       "\n".join(area_mob_case),
       SCREEN_ADDR["title"], SCREEN_ADDR["class"], SCREEN_ADDR["map"],
       SCREEN_ADDR["battle"], SCREEN_ADDR["shop"], SCREEN_ADDR["dead"], SCREEN_ADDR["win"],
       SCREEN_ADDR["pic"], SCREEN_ADDR["shop2"])

with open(os.path.join(GEN, "ui_rom.v"), "w", encoding="utf-8", newline="\n") as f:
    f.write(ui_v)

print("生成完毕: rtl/gen/{font.hex, cmd.hex, str.hex, art.hex, ui_rom.v}")
