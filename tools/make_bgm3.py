#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
make_bgm3.py —— 生成三首 BGM 的 music.hex (192 步 = 3 首 x 64 步)

  轨 0 (0..63)    : 探索/城镇  —— 沿用 make_audio.demo_song()
  轨 1 (64..127)  : 战斗      —— A 小调, 快速推进
  轨 2 (128..191) : 胜利/结局 —— C 大调, 明亮号角

sound 模块用 mus_sel[1:0] 选择起始偏移 = mus_sel * 64,
每轨播完 64 步回到本轨开头循环。

用法: python make_bgm3.py
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from make_audio import REST, demo_song, gen_pitch  # noqa: E402

OUT_DIR = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                       '..', 'rtl', 'gen'))
TRACK_STEPS = 64
TRACKS = 3
TOTAL = TRACK_STEPS * TRACKS


def battle_song():
    """A 小调, 8 小节, 每小节 8 个八分音符。低音走 Am-F-G-E。"""
    # (低音 MIDI, 和弦三音 MIDI)
    Am = (45, 60)   # A2  C4
    F  = (41, 57)   # F2  A3
    G  = (43, 59)   # G2  B3
    E  = (40, 56)   # E2  G#3
    prog = [Am, Am, F, F, G, G, E, E]

    melody = [
        [76, 76, 81, 76, 72, 76, 81, 83],
        [76, 76, 81, 76, 84, 81, 79, 76],
        [77, 77, 81, 77, 72, 77, 81, 84],
        [77, 77, 81, 77, 84, 81, 79, 77],
        [79, 79, 83, 79, 74, 79, 83, 86],
        [79, 79, 83, 79, 86, 83, 81, 79],
        [80, 80, 83, 80, 76, 80, 83, 88],
        [80, 83, 86, 83, 80, 76, 71, None],
    ]

    steps = []
    for bar in range(8):
        low, third = prog[bar]
        for k in range(8):
            m = melody[bar][k]
            # 低音每 2 步一下(四分音符), 和声每 4 步一下, 比探索曲更密
            bass = low if (k % 2 == 0) else REST
            harm = third if (k % 4 == 0) else REST
            steps.append((m, harm, bass, 2))
    return steps


def win_song():
    """C 大调号角, 先上行走句再回落, 8 小节。"""
    C  = (48, 64)   # C3  E4
    F  = (53, 57)   # F3  A3
    G  = (55, 59)   # G3  B3
    prog = [C, C, F, G, C, C, G, C]

    melody = [
        [72, 76, 79, 84, None, 84, 79, None],
        [81, 84, 86, 84, 81, 79, 76, None],
        [77, 81, 84, 89, None, 89, 84, None],
        [79, 83, 86, 91, None, 86, 83, 79],
        [84, 86, 88, 89, 91, None, None, None],
        [79, 81, 83, 84, 86, None, None, None],
        [83, 86, 91, 88, 86, 83, 79, None],
        [72, 76, 79, 84, 79, 76, 72, None],
    ]

    steps = []
    for bar in range(8):
        low, third = prog[bar]
        for k in range(8):
            m = melody[bar][k]
            bass = low if (k % 4 == 0) else REST
            harm = third if (k % 2 == 0) else REST
            steps.append((m, harm, bass, 2))
    return steps


def encode(steps):
    """64 步补休止, 打包成 32 位字串列表"""
    rows = []
    for i in range(TRACK_STEPS):
        if i < len(steps):
            n0, n1, n2, dur = steps[i]
        else:
            n0 = n1 = n2 = REST
            dur = 8
        n0 = REST if n0 is None else max(0, min(n0, REST))
        n1 = REST if n1 is None else max(0, min(n1, REST))
        n2 = REST if n2 is None else max(0, min(n2, REST))
        dur = max(1, min(int(dur), 127))
        rows.append('%08X' % ((dur << 21) | (n2 << 14) | (n1 << 7) | n0))
    return rows


def main():
    gen_pitch()                       # 顺带刷新 pitch.hex
    rows = []
    rows += encode(demo_song())       # 轨 0 探索
    rows += encode(battle_song())     # 轨 1 战斗
    rows += encode(win_song())        # 轨 2 胜利
    assert len(rows) == TOTAL, len(rows)

    path = os.path.join(OUT_DIR, 'music.hex')
    with open(path, 'w', encoding='ascii') as fh:
        fh.write('\n'.join(rows) + '\n')
    print('written %s (%d steps = %d 轨 x %d 步)'
          % (path, len(rows), TRACKS, TRACK_STEPS))


if __name__ == '__main__':
    main()
