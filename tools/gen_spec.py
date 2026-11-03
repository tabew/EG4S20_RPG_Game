#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
gen_spec.py —— 生成新的 spec_bars 模块并替换进 key_debounce.v

设计依据 tools/design_spec2.py + tools/final_diff.py 的仿真结论:
  * 前置 4 级低通 (c=1/4) 把方波磨成正弦
  * 8 段 一阶 HP + 一阶 LP, 系数 12 位定点 (每段 2 个乘法器)
  * 每段 fast 平均 (吃掉边沿) -> env 峰值保持
  * bar = 14 + 7*env - 6*avg  (减掉八段均值, 音高在哪段, 哪段就凸出来)

用法: python gen_spec.py
"""

import io
import math
import os

FS = 32000
EDGES = [150, 198, 262, 346, 457, 603, 797, 1053, 1391]
Q = 4096

HERE = os.path.dirname(os.path.abspath(__file__))
TARGET = os.path.join(os.path.dirname(HERE), 'rtl', 'common', 'key_debounce.v')


def hp_a(fc):
    return round(math.exp(-2 * math.pi * fc / FS) * Q)


def lp_c(fc):
    return round((1.0 - math.exp(-2 * math.pi * fc / FS)) * Q)


A = [hp_a(f) for f in EDGES[:-1]]
C = [lp_c(f) for f in EDGES[1:]]

HEAD = """//=============================================================================
// spec_bars —— 音频频谱分析 (8 段, 2026-10-29 重做)
//
//   ★ 旧版的问题 (tools/verify_bars.py 实测, 不是猜的):
//       PSG 输出是方波, 边沿是宽带脉冲, 8 个频段同时被激发;
//       加上包络是快攻, 于是 91% 的时间里八根柱同方向摆动,
//       峰值段固定死在 seg2/seg3, 跟音高完全无关。
//       一阶滤波只有 6dB/oct, 相邻段高度差只有个位数, 本来就分不开。
//
//   ★ 新结构:
//       PCM -> 前置低通 x4 (c=1/4, fc≈1.4kHz) 把方波磨成正弦, 砍掉 3 次以上谐波
//           -> seg i: 一阶 HP(f_lo) + 一阶 LP(f_hi), 12 位定点系数(用乘法器)
//           -> fast = fast + (|y|-fast)/32      1ms 平均, 吃掉边沿冲击
//           -> env  = max(fast, env - (env>>13) - 1)    峰值保持 + 慢落
//           -> bar  = 14 + 7*env - 6*avg        减掉八段均值, 让"高于平均"的段凸显
//
//   8 段按 1/4 倍频程铺在三个声部的基频范围:
//     seg0 150-198   seg1 198-262   seg2 262-346   seg3 346-457
//     seg4 457-603   seg5 603-797   seg6 797-1053  seg7 1053-1391 Hz
//
//   实测效果 (真实 music.hex, 10 秒):
//     同方向摆动占比  91% -> 34%
//     低音峰值段 4.4 / 高音峰值段 5.9  (改造前都是 2~3, 不动)
//     单音 150~1400Hz 扫描: 峰值段 0->1->2->3->4->6->7 单调右移
//=============================================================================
module spec_bars #(
    parameter integer CLK_HZ    = 40000000,
    parameter integer SAMPLE_HZ = 32000
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire [7:0]  pcm,
    output wire [63:0] bars
);

    localparam integer DIV_S = CLK_HZ / SAMPLE_HZ;

    reg [10:0] sdiv;
    wire stk = (sdiv == DIV_S - 1);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)   sdiv <= 11'd0;
        else if (stk) sdiv <= 11'd0;
        else          sdiv <= sdiv + 11'd1;
    end

    //---------------------------------------------------------
    // 输入: 8 位无符号 -> 16 位有符号 (-128..127)
    //---------------------------------------------------------
    wire signed [15:0] xin = {8'd0, pcm} - 16'sd128;

    //---------------------------------------------------------
    // 前置低通 4 级, c = 1/4 (fc ≈ 1.4kHz)
    //   用 18 位带 2 位小数, 否则 (x-pl)>>>2 在差值小于 4 时归零,
    //   四级累积死区会把小信号吃掉。
    //---------------------------------------------------------
    reg signed [17:0] pl0, pl1, pl2, pl3;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pl0 <= 18'sd0; pl1 <= 18'sd0; pl2 <= 18'sd0; pl3 <= 18'sd0;
        end else if (stk) begin
            pl0 <= pl0 + (((xin <<< 2) - pl0) >>> 2);
            pl1 <= pl1 + ((pl0 - pl1) >>> 2);
            pl2 <= pl2 + ((pl1 - pl2) >>> 2);
            pl3 <= pl3 + ((pl2 - pl3) >>> 2);
        end
    end

    wire signed [15:0] xs = pl3[17:2];
"""

SEG = """
    //---------------------------------------------------------
    // seg{i}: {lo}~{hi} Hz   HP a={a}/4096  LP c={c}/4096
    //---------------------------------------------------------
    reg signed [15:0] h{i}, l{i};
    reg signed [15:0] xp{i};
    wire signed [15:0] mt{i} = h{i} + xs - xp{i};
    wire signed [15:0] hp{i} = (mt{i} * $signed({{1'b0, 12'd{a}}})) >>> 12;
    wire signed [15:0] df{i} = hp{i} - l{i};
    wire signed [15:0] y{i}  = l{i} + ((df{i} * $signed({{1'b0, 12'd{c}}})) >>> 12);
    wire        [15:0] ab{i} = y{i}[15] ? (~y{i} + 16'd1) : y{i};
    wire signed [16:0] dv{i} = $signed({{1'b0, ab{i}}}) - $signed({{1'b0, f{i}}});
    wire signed [16:0] nf{i} = $signed({{1'b0, f{i}}}) + (dv{i} >>> 5);
"""

STATE = """
    //---------------------------------------------------------
    // fast 平均 + env 峰值保持
    //   f 只能在 >=0 范围变化, 否则 16 位无符号回绕成 65535。
    //---------------------------------------------------------
    reg [17:0] e0, e1, e2, e3, e4, e5, e6, e7;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            h0 <= 16'sd0; l0 <= 16'sd0; xp0 <= 16'sd0;
            h1 <= 16'sd0; l1 <= 16'sd0; xp1 <= 16'sd0;
            h2 <= 16'sd0; l2 <= 16'sd0; xp2 <= 16'sd0;
            h3 <= 16'sd0; l3 <= 16'sd0; xp3 <= 16'sd0;
            h4 <= 16'sd0; l4 <= 16'sd0; xp4 <= 16'sd0;
            h5 <= 16'sd0; l5 <= 16'sd0; xp5 <= 16'sd0;
            h6 <= 16'sd0; l6 <= 16'sd0; xp6 <= 16'sd0;
            h7 <= 16'sd0; l7 <= 16'sd0; xp7 <= 16'sd0;
            f0 <= 16'd0; f1 <= 16'd0; f2 <= 16'd0; f3 <= 16'd0;
            f4 <= 16'd0; f5 <= 16'd0; f6 <= 16'd0; f7 <= 16'd0;
            e0 <= 18'd0; e1 <= 18'd0; e2 <= 18'd0; e3 <= 18'd0;
            e4 <= 18'd0; e5 <= 18'd0; e6 <= 18'd0; e7 <= 18'd0;
        end else if (stk) begin
            h0 <= hp0; l0 <= y0; xp0 <= xs;
            h1 <= hp1; l1 <= y1; xp1 <= xs;
            h2 <= hp2; l2 <= y2; xp2 <= xs;
            h3 <= hp3; l3 <= y3; xp3 <= xs;
            h4 <= hp4; l4 <= y4; xp4 <= xs;
            h5 <= hp5; l5 <= y5; xp5 <= xs;
            h6 <= hp6; l6 <= y6; xp6 <= xs;
            h7 <= hp7; l7 <= y7; xp7 <= xs;

            f0 <= nf0[16] ? 16'd0 : nf0[15:0];
            f1 <= nf1[16] ? 16'd0 : nf1[15:0];
            f2 <= nf2[16] ? 16'd0 : nf2[15:0];
            f3 <= nf3[16] ? 16'd0 : nf3[15:0];
            f4 <= nf4[16] ? 16'd0 : nf4[15:0];
            f5 <= nf5[16] ? 16'd0 : nf5[15:0];
            f6 <= nf6[16] ? 16'd0 : nf6[15:0];
            f7 <= nf7[16] ? 16'd0 : nf7[15:0];

            e0 <= ({2'b0, f0} >= e0) ? {2'b0, f0} : e0 - ((e0 >> 13) + 18'd1);
            e1 <= ({2'b0, f1} >= e1) ? {2'b0, f1} : e1 - ((e1 >> 13) + 18'd1);
            e2 <= ({2'b0, f2} >= e2) ? {2'b0, f2} : e2 - ((e2 >> 13) + 18'd1);
            e3 <= ({2'b0, f3} >= e3) ? {2'b0, f3} : e3 - ((e3 >> 13) + 18'd1);
            e4 <= ({2'b0, f4} >= e4) ? {2'b0, f4} : e4 - ((e4 >> 13) + 18'd1);
            e5 <= ({2'b0, f5} >= e5) ? {2'b0, f5} : e5 - ((e5 >> 13) + 18'd1);
            e6 <= ({2'b0, f6} >= e6) ? {2'b0, f6} : e6 - ((e6 >> 13) + 18'd1);
            e7 <= ({2'b0, f7} >= e7) ? {2'b0, f7} : e7 - ((e7 >> 13) + 18'd1);
        end
    end
"""

TAIL = """
    //---------------------------------------------------------
    // 柱高 = 14 + 7*env - 6*avg
    //   减掉八段均值: 音高落在哪一段, 那一段就凸出来, 其余被压回去。
    //   全是加法和移位, 不额外占乘法器。
    //---------------------------------------------------------
    // 8 段求和最大 8 x 262143 = 2,097,144, 需要 22 位, 不能只给 20 位
    wire [21:0] esum = {1'b0, e0} + {1'b0, e1} + {1'b0, e2} + {1'b0, e3}
                     + {1'b0, e4} + {1'b0, e5} + {1'b0, e6} + {1'b0, e7};
    wire [18:0] eavg = esum[21:3];                      // 除以 8
    wire [20:0] esix = (eavg << 2) + (eavg << 1);       // 6*avg

    function [7:0] sat120;
        input signed [23:0] v;
        begin
            sat120 = v[23] ? 8'd0 : (v > 24'sd120 ? 8'd120 : v[7:0]);
        end
    endfunction

    // 24 位有符号: 18 位 env << 3 = 21 位, 再减 21 位的 6*avg, 留 3 位余量
    //   ★ 必须显式 $signed, 否则拼接结果是无符号, 减法下溢会变成巨大的正数
    wire signed [23:0] r0 = 24'sd14 + $signed({3'b0, e0, 3'b0}) - $signed({6'b0, e0}) - $signed({3'b0, esix});
    wire signed [23:0] r1 = 24'sd14 + $signed({3'b0, e1, 3'b0}) - $signed({6'b0, e1}) - $signed({3'b0, esix});
    wire signed [23:0] r2 = 24'sd14 + $signed({3'b0, e2, 3'b0}) - $signed({6'b0, e2}) - $signed({3'b0, esix});
    wire signed [23:0] r3 = 24'sd14 + $signed({3'b0, e3, 3'b0}) - $signed({6'b0, e3}) - $signed({3'b0, esix});
    wire signed [23:0] r4 = 24'sd14 + $signed({3'b0, e4, 3'b0}) - $signed({6'b0, e4}) - $signed({3'b0, esix});
    wire signed [23:0] r5 = 24'sd14 + $signed({3'b0, e5, 3'b0}) - $signed({6'b0, e5}) - $signed({3'b0, esix});
    wire signed [23:0] r6 = 24'sd14 + $signed({3'b0, e6, 3'b0}) - $signed({6'b0, e6}) - $signed({3'b0, esix});
    wire signed [23:0] r7 = 24'sd14 + $signed({3'b0, e7, 3'b0}) - $signed({6'b0, e7}) - $signed({3'b0, esix});

    assign bars[7:0]   = sat120(r0);
    assign bars[15:8]  = sat120(r1);
    assign bars[23:16] = sat120(r2);
    assign bars[31:24] = sat120(r3);
    assign bars[39:32] = sat120(r4);
    assign bars[47:40] = sat120(r5);
    assign bars[55:48] = sat120(r6);
    assign bars[63:56] = sat120(r7);

endmodule
"""


def build():
    out = [HEAD]
    # 每段的组合逻辑 (fast 平均值寄存器 f 用在 dv 里, 先声明)
    out.append("\n    reg [15:0] f0, f1, f2, f3, f4, f5, f6, f7;\n")
    for i in range(8):
        out.append(SEG.format(i=i, lo=EDGES[i], hi=EDGES[i + 1],
                              a=A[i], c=C[i]))
    out.append(STATE)
    out.append(TAIL)
    return ''.join(out)


def main():
    src = io.open(TARGET, encoding='utf-8').read()
    i = src.index('module spec_bars')
    j = src.rindex('//=====', 0, i)
    new = src[:j] + build()
    io.open(TARGET, 'w', encoding='utf-8', newline='\n').write(new)
    print('replaced, %d bytes -> %d bytes' % (len(src), len(new)))
    print('HP coef:', A)
    print('LP coef:', C)


if __name__ == '__main__':
    main()
