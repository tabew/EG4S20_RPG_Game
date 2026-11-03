# -*- coding: utf-8 -*-
"""生成 spec_bars 零乘法器版本, 替换 key_debounce.v 里的旧模块

上一版用 12 位定点系数做乘法, 8 段 x 2 = 16 个乘法器把 29 个 DSP 全吃满,
布局拥塞 -> HDMI 200MHz 串行路径违例 (WNS -1.456ns) -> 上板画面卡死。
这一版把全部系数换成 ±2^-k 的加减移位, DSP 用量归零。
"""
import io
import os
import re

HERE = os.path.dirname(os.path.abspath(__file__))
TARGET = os.path.join(os.path.dirname(HERE), 'rtl', 'common', 'key_debounce.v')

# 频率边界 (1/4 倍频程), 每个 k 的移位表示由 design_shift.py 搜索得到
# (sign, shift) 列表
K = {
    150:  [(+1, 5), (-1, 9)],                      # 2^-5 - 2^-9
    198:  [(+1, 5), (+1, 7), (-1, 10)],            # 2^-5 + 2^-7 - 2^-10
    262:  [(+1, 4), (-1, 6), (+1, 8)],             # 2^-4 - 2^-6 + 2^-8
    346:  [(+1, 4), (+1, 8)],                      # 2^-4 + 2^-8
    457:  [(+1, 3), (-1, 5), (-1, 7)],             # 2^-3 - 2^-5 - 2^-7
    603:  [(+1, 3), (-1, 6), (+1, 9)],             # 2^-3 - 2^-6 + 2^-9
    797:  [(+1, 3), (+1, 6), (+1, 8)],             # 2^-3 + 2^-6 + 2^-8
    1053: [(+1, 2), (-1, 4)],                      # 2^-2 - 2^-4
    1391: [(+1, 2), (-1, 7)],                      # 2^-2 - 2^-7
}

EDGES = [150, 198, 262, 346, 457, 603, 797, 1053, 1391]


def shmul(var, terms):
    """把  var * sum(±2^-shift)  写成加减移位"""
    parts = []
    for i, (s, k) in enumerate(terms):
        op = '+' if s > 0 else '-'
        if i == 0:
            parts.append("%s(%s >>> %d)" % ('' if s > 0 else '-', var, k)
                         if s < 0 else "(%s >>> %d)" % (var, k))
        else:
            parts.append(" %s (%s >>> %d)" % (op, var, k))
    return "".join(parts)


def kexpr(terms):
    """把 [(+1,5),(-1,9)] 写成 2^-5-2^-9"""
    s = ""
    for i, (sg, k) in enumerate(terms):
        if i == 0:
            s += ("-" if sg < 0 else "") + "2^-%d" % k
        else:
            s += ("-" if sg < 0 else "+") + "2^-%d" % k
    return s


SEG = []
for i in range(8):
    lo, hi = EDGES[i], EDGES[i + 1]
    hp_expr = shmul("t%d" % i, K[lo])
    lp_expr = shmul("d%d" % i, K[hi])
    SEG.append("""    //---- seg{i}: {lo}~{hi} Hz   HP k={hpk}   LP k={lpk} ----
    reg signed [11:0] h{i}, l{i}, xp{i};
    wire signed [11:0] t{i}  = h{i} + xs - xp{i};
    wire signed [11:0] hp{i} = t{i} - ({hpe});
    wire signed [11:0] d{i}  = hp{i} - l{i};
    wire signed [11:0] y{i}  = l{i} + ({lpe});
    wire        [11:0] ab{i} = y{i}[11] ? (~y{i} + 12'd1) : y{i};
    // f 带 4 位小数: 只存整数的话, |y| < 32 时 (|y|-f)>>>5 恒为 0,
    // 小信号永远爬不上来, 柱子会卡在基线 (2026-10-29 实测)。
    wire        [15:0] ax{i} = {{ab{i}, 4'b0}};
    wire signed [16:0] dv{i} = $signed({{1'b0, ax{i}}}) - $signed({{1'b0, f{i}}});
    wire signed [16:0] nf{i} = $signed({{1'b0, f{i}}}) + (dv{i} >>> 5);
""".format(i=i, lo=lo, hi=hi,
           hpk=kexpr(K[lo]), lpk=kexpr(K[hi]),
           hpe=hp_expr, lpe=lp_expr))

RS = "".join("            h%d <= 16'sd0; l%d <= 16'sd0; xp%d <= 16'sd0;\n" % (i, i, i)
             for i in range(8))
RS = RS.replace("16'sd0", "12'sd0")
RF = "            " + " ".join("f%d <= 16'd0;" % i for i in range(4)) + "\n" \
     + "            " + " ".join("f%d <= 16'd0;" % i for i in range(4, 8)) + "\n"
UP = "".join("            h%d <= hp%d; l%d <= y%d; xp%d <= xs;\n" % (i, i, i, i, i)
             for i in range(8))
UF = "".join("            f%d <= nf%d[16] ? 16'd0 : nf%d[15:0];\n" % (i, i, i)
             for i in range(8))

BARS = "".join(
    "    assign bars[{h}:{l}] = barf(f{i}, favg);\n".format(h=8 * i + 7, l=8 * i, i=i)
    for i in range(8))

MOD = """//=============================================================================
// spec_bars —— 音频频谱分析 (8 段, 全移位实现, 零乘法器)
//
//   ★ 为什么重做 (2026-10-29 第二次):
//     上一版每段用两个 12 位定点系数做乘法, 8 段共 16 个乘法器,
//     把 EG4S20 仅有的 29 个 DSP 吃到 29/29 = 100%, 布局拥塞,
//     HDMI 的 200MHz 串行路径被打散 (WNS -1.456ns / TNS -15.174ns),
//     上板表现为画面卡死。这一版所有系数换成 ±2^-k 的加减移位,
//     DSP 用量归零, 逻辑量也压到原来的六成。
//
//   ★ 结构:
//       PCM -> 前置低通 x4 (c=1/4, fc≈1.4kHz) 把方波磨成正弦, 砍掉 3 次以上谐波
//           -> seg i: 一阶 HP(f_lo) + 一阶 LP(f_hi)
//                  一阶 HP: hp = t - t*k            (k = 1-exp(-2pi*fc/fs))
//                  一阶 LP: l  = l + (x-l)*k
//           -> fast = fast + (|y|-fast)/32      1ms 平均, 吃掉方波边沿的冲击
//           -> bar  = 10 + 7*fast - 6*avg       减掉八段均值,
//                                              音高在哪段, 哪段就凸出来
//
//   ★ 系数近似 (design_shift.py 搜索, 每项误差 < 1.6%, 段宽 33% 不受影响):
//      fc= 150  k=2^-5-2^-9              fc= 603  k=2^-3-2^-6+2^-9
//      fc= 198  k=2^-5+2^-7-2^-10        fc= 797  k=2^-3+2^-6+2^-8
//      fc= 262  k=2^-4-2^-6+2^-8         fc=1053  k=2^-2-2^-4
//      fc= 346  k=2^-4+2^-8              fc=1391  k=2^-2-2^-7
//      fc= 457  k=2^-3-2^-5-2^-7
//
//   8 段按 1/4 倍频程铺在三个声部的基频范围:
//     seg0 150-198   seg1 198-262   seg2 262-346   seg3 346-457
//     seg4 457-603   seg5 603-797   seg6 797-1053  seg7 1053-1391 Hz
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

    localparam integer DIV_S = CLK_HZ / SAMPLE_HZ;      // 1250

    //---------------------------------------------------------
    // 32kHz 采样节拍
    //---------------------------------------------------------
    reg [10:0] sdiv;
    wire stk = (sdiv == DIV_S - 1);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)   sdiv <= 11'd0;
        else if (stk) sdiv <= 11'd0;
        else          sdiv <= sdiv + 11'd1;
    end

    //---------------------------------------------------------
    // 输入: 8 位无符号 -> 12 位有符号 (-128..127)
    //   12 位而不是 16 位: 信号幅度只有 +-133, 12 位(+-2048)有 15 倍余量,
    //   加法器位宽直接决定逻辑量。
    //---------------------------------------------------------
    wire signed [11:0] xin = $signed({{4'b0, pcm}}) - 12'sd128;

    //---------------------------------------------------------
    // 前置低通 2 级, c = 1/4 (单级 -3dB ≈ 1.4kHz, 两级 ≈ 900Hz)
    //   方波边沿是宽带脉冲, 不先磨圆, 八段会同时被激发, 柱子整排一起跳。
    //   级数从 4 降到 2: 4 级的 -3dB 只有 640Hz, 把 1kHz 以上的柱段
    //   饿死了 (实测 seg6/seg7 恒为 0), 2 级刚好把 3 次以上谐波压住,
    //   又不至于砍掉音乐的高音区。
    //---------------------------------------------------------
    //   14 位 = 12 位信号 + 2 位小数。不留小数位的话 (x-pl)>>>2 在
    //   差值小于 4 时恒为 0, 四级累积的死区会把小信号吃掉。
    reg signed [13:0] pl0, pl1;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pl0 <= 14'sd0; pl1 <= 14'sd0;
        end else if (stk) begin
            pl0 <= pl0 + (((xin <<< 2) - pl0) >>> 2);
            pl1 <= pl1 + ((pl0 - pl1) >>> 2);
        end
    end

    wire signed [11:0] xs = pl1[13:2];

    reg [15:0] f0, f1, f2, f3, f4, f5, f6, f7;   // 12 位信号 + 4 位小数

{seg}
    //---------------------------------------------------------
    // 状态更新 (每 32kHz 采样一次)
    //---------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
{rs}{rf}        end else if (stk) begin
{up}{uf}        end
    end

    //---------------------------------------------------------
    // 柱高 = 10 + 7*f - 6*avg
    //   avg 是八段的平均值。减掉均值以后, 高于平均的那一段凸出来,
    //   低于平均的压回去 —— 音高一变, 亮点就左右扫。
    //   全是移位加法, 不用乘法器。
    //---------------------------------------------------------
    wire [19:0] fsum = {{4'b0, f0}} + {{4'b0, f1}} + {{4'b0, f2}} + {{4'b0, f3}}
                     + {{4'b0, f4}} + {{4'b0, f5}} + {{4'b0, f6}} + {{4'b0, f7}};
    wire [16:0] favg = fsum[19:3];                     // 除以 8

    // 柱高 = 10 + (7*f - 6*avg) / 16
    //   f 带 4 位小数, 所以最后要右移 4 位才回到"柱高像素"。
    //   减法故意不省: 高于平均的段凸出来, 低于平均的压回去,
    //   音高变了亮点才会左右扫。
    function [7:0] barf;
        input [15:0] fv;
        input [16:0] av;
        reg signed [20:0] d;
        begin
            d = $signed({{2'b0, fv, 3'b0}}) - $signed({{3'b0, fv}})
              - $signed({{1'b0, av, 2'b0}}) - $signed({{1'b0, av, 1'b0}});
            d = 21'sd10 + (d >>> 4);
            barf = d[20] ? 8'd0 : (d > 21'sd120 ? 8'd120 : d[7:0]);
        end
    endfunction

{bars}
endmodule
""".format(seg="\n".join(SEG), rs=RS, rf=RF, up=UP, uf=UF, bars=BARS)


def main():
    src = io.open(TARGET, encoding='utf-8').read()
    idx = src.find('//=============================================================================\n// spec_bars')
    if idx < 0:
        idx = src.find('// spec_bars')
    assert idx > 0, '找不到 spec_bars 注释起点'
    new = src[:idx] + MOD
    io.open(TARGET, 'w', encoding='utf-8', newline='\n').write(new)
    print('已替换: 原 %d 行 -> 新文件 %d 行' % (src.count('\n') + 1, new.count('\n') + 1))


if __name__ == '__main__':
    main()
