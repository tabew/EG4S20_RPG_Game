#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
make_audio.py —— 生成 PSG 音频模块需要的两张表

  1. rtl/gen/pitch.hex   : 128 项，MIDI 音符号 -> 24 位相位累加步进
                            step = 440 * 2^((n-69)/12) * 2^24 / 32kHz
  2. rtl/gen/music.hex   : 256 步 x 32 位，BGM 音符表（3 声部同步步进）
                            每步 = [5:0]ch0 [11:6]ch1 [17:12]ch2 [25:18]dur
                            音高 0x3F = 休止，dur 单位 = 1/16 拍

用法:
  python make_audio.py                 # 生成音高表 + 内置示例曲
  python make_audio.py xxx.mid         # 用 MIDI 生成音乐表（覆盖 music.hex）
"""

import sys
import os
import math
import struct

OUT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'rtl', 'gen')
OUT_DIR = os.path.abspath(OUT_DIR)

SAMPLE_HZ = 32_000       # 相位累加在 32kHz 采样节拍上进行, 音高必须按采样率算
REST = 0x7F          # 7 位音高的休止符
STEPS = 64           # ROM 深度（= 循环步数，节省 BRAM）
MUSIC_LOOP = 64      # 实际循环步数（改这里要同步改 sound.v 的 LOOP_END）


# ------------------------------------------------------------------
# 1. 音高表
# ------------------------------------------------------------------
def gen_pitch():
    lines = []
    for n in range(128):
        f = 440.0 * (2.0 ** ((n - 69) / 12.0))
        step = int(round(f * (1 << 24) / SAMPLE_HZ))
        step = max(0, min(step, (1 << 24) - 1))
        lines.append('%06X' % step)
    path = os.path.join(OUT_DIR, 'pitch.hex')
    with open(path, 'w', encoding='ascii') as fh:
        fh.write('\n'.join(lines) + '\n')
    print('written %s (%d entries)' % (path, len(lines)))


# ------------------------------------------------------------------
# 2. 音符表写出
# ------------------------------------------------------------------
def write_music(steps, loop_len=None):
    """steps: [(n0, n1, n2, dur), ...] 不足 STEPS 的部分用休止填充"""
    loop_len = loop_len or len(steps)
    rows = []
    for i in range(STEPS):
        if i < len(steps):
            n0, n1, n2, dur = steps[i]
        else:
            n0 = n1 = n2 = REST
            dur = 8
        n0 = REST if n0 is None else max(0, min(n0, REST))
        n1 = REST if n1 is None else max(0, min(n1, REST))
        n2 = REST if n2 is None else max(0, min(n2, REST))
        dur = max(1, min(int(dur), 127))
        # [6:0]n0 [13:7]n1 [20:14]n2 [29:21]dur
        word = (dur << 21) | (n2 << 14) | (n1 << 7) | n0
        rows.append('%08X' % word)

    path = os.path.join(OUT_DIR, 'music.hex')
    with open(path, 'w', encoding='ascii') as fh:
        fh.write('\n'.join(rows) + '\n')
    print('written %s (%d steps, loop=%d)' % (path, len(rows), loop_len))


# ------------------------------------------------------------------
# 3. 内置示例：Undertale 风格地图循环（原创，占位用）
#    F 大调，4/4，120BPM，8 小节 = 64 步（每步半拍）
# ------------------------------------------------------------------
def demo_song():
    # 和弦低音 / 三音
    F   = (53, 57)   # F3  A3
    Dm  = (50, 53)   # D3  F3
    Bb  = (46, 50)   # Bb2 D3
    C   = (48, 52)   # C3  E3
    prog = [F, F, Dm, Dm, Bb, Bb, C, C]      # 每和弦 2 小节

    # 旋律：每小节 8 个半拍音（0x3F 为休止）
    melody = [
        [77, 79, 81, 84, 81, 79, 77, 76],
        [74, 77, 81, 79, 77, 74, 72, 74],
        [77, 81, 84, 86, 84, 81, 79, 77],
        [76, 79, 84, 81, 79, 76, 74, 72],
        [74, 77, 82, 81, 79, 77, 74, 72],
        [72, 74, 77, 79, 77, 74, 72, 70],
        [72, 76, 79, 84, 79, 76, 72, 76],
        [77, 76, 74, 72, 74, 72, 70, 72],
    ]

    steps = []
    for bar in range(8):
        low, third = prog[bar]
        for k in range(8):
            m = melody[bar][k]
            # 低音每 4 步换一次（2 拍），和声每 2 步轻点一下
            bass = low if (k % 4 == 0) else REST
            harm = third if (k % 2 == 0) else REST
            steps.append((m, harm, bass, 2))
    return steps


# ------------------------------------------------------------------
# 4. MIDI -> 音符表（纯标准库实现）
# ------------------------------------------------------------------
def _vlq(data, i):
    v = 0
    while True:
        b = data[i]
        i += 1
        v = (v << 7) | (b & 0x7F)
        if not (b & 0x80):
            return v, i


def parse_midi(path):
    raw = open(path, 'rb').read()
    if raw[:4] != b'MThd':
        raise ValueError('不是标准 MIDI 文件')
    fmt, ntrk, div = struct.unpack('>HHH', raw[8:14])

    # 收集所有 note 事件 (tick, note, on)
    notes = []
    pos = 14
    tick0 = 0
    for _ in range(ntrk):
        if raw[pos:pos + 4] != b'MTrk':
            break
        ln = struct.unpack('>I', raw[pos + 4:pos + 8])[0]
        body = raw[pos + 8:pos + 8 + ln]
        pos += 8 + ln

        i = 0
        tick = 0
        status = None
        while i < len(body):
            dt, i = _vlq(body, i)
            tick += dt
            if i >= len(body):
                break
            b = body[i]
            if b & 0x80:
                status = b
                i += 1
            if status is None:
                continue
            cmd = status & 0xF0

            if cmd in (0x80, 0x90):
                note = body[i]
                vel = body[i + 1]
                i += 2
                if cmd == 0x90 and vel > 0:
                    notes.append((tick, note, True))
                else:
                    notes.append((tick, note, False))
            elif cmd in (0xA0, 0xB0, 0xE0):
                i += 2
            elif cmd in (0xC0, 0xD0):
                i += 1
            elif status == 0xFF:
                meta = body[i]
                i += 1
                mlen, i = _vlq(body, i)
                i += mlen
            elif status in (0xF0, 0xF7):
                mlen, i = _vlq(body, i)
                i += mlen
            else:
                break

    if not notes:
        raise ValueError('MIDI 里没有音符')

    notes.sort()
    # 每个 1/16 拍一个格子
    grid = max(1, div // 4)
    total_ticks = notes[-1][0]
    ncell = min(STEPS * 2, total_ticks // grid + 1)

    active = {}
    cells = []
    idx = 0
    events = notes
    for c in range(ncell):
        t_end = (c + 1) * grid
        while idx < len(events) and events[idx][0] < t_end:
            tick, note, on = events[idx]
            if on:
                active[note] = True
            else:
                active.pop(note, None)
            idx += 1
        cur = sorted(active.keys())
        if not cur:
            cells.append(None)
        else:
            # 高音给 ch0，低音给 ch2，中间给 ch1
            n0 = cur[-1]
            n2 = cur[0] if len(cur) > 1 else None
            n1 = cur[len(cur) // 2] if len(cur) > 2 else None
            cells.append((n0, n1, n2))

    # 合并连续相同内容为一个 step，累加 dur
    steps = []
    i = 0
    while i < len(cells):
        j = i
        while j + 1 < len(cells) and cells[j + 1] == cells[i]:
            j += 1
        n0, n1, n2 = cells[i] if cells[i] else (None, None, None)
        steps.append((n0, n1, n2, min((j - i + 1) * 2, 255)))
        i = j + 1

    return steps[:STEPS]


# ------------------------------------------------------------------
def main():
    gen_pitch()
    if len(sys.argv) > 1 and sys.argv[1].lower().endswith('.mid'):
        mid = sys.argv[1]
        print('converting %s ...' % mid)
        steps = parse_midi(mid)
        write_music(steps, len(steps))
        print('提示: 改 sound.v 里的 LOOP_END = %d 以匹配循环长度' % (len(steps) - 1))
    else:
        steps = demo_song()
        write_music(steps, MUSIC_LOOP)
        print('内置示例曲: 8 小节 F 大调循环，LOOP_END 应为 %d' % (MUSIC_LOOP - 1))


if __name__ == '__main__':
    main()
