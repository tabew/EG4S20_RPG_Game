# -*- coding: utf-8 -*-
"""把 spec_bars(8 段频谱分析) 换成 note_bars(音高可视化)

为什么放弃频谱分析:
  用真实 music.hex 跑离线验证 (tools/verify_spec2.py), 方波音源 + 一阶
  带通组做不出可用的频段分离 —— 同一频率下 8 个频段只差 1.2 倍, 800Hz
  输入的峰值甚至落在 346~457Hz 那一段。方波边沿是宽带脉冲, 一阶滤波
  只有 6dB/oct, 压不住。改二阶能好一点, 但 8 段逻辑量翻倍, 时序又会
  像刚才那样崩掉 (WNS -1.456ns, DSP 29/29 用满)。

改成 note_bars:
  三个声部的音号 -> 8 根柱子的位置, 包络 -> 柱高。
  位置 100% 由音高决定, 音高变了柱子就真的左右移。
  逻辑量从 1520 LE + 16 DSP 降到约 500 LE + 0 DSP。
"""
import io
import os

HERE = os.path.dirname(os.path.abspath(__file__))
TARGET = os.path.join(os.path.dirname(HERE), 'rtl', 'common', 'key_debounce.v')

TGT = "\n".join(
    "    wire [7:0] t{i} = mx3(hit(I0, e0, 4'd{i}), hit(I1, e1, 4'd{i}), hit(I2, e2, 4'd{i}));".format(i=i)
    for i in range(8))

SMOOTH = "\n".join(
    "            s{i} = {{2'b0, b{i}}} + {{2'b0, b{i}}} + {{2'b0, b{i}}} + {{2'b0, t{i}}};".format(i=i)
    for i in range(8))

UPD = "\n".join(
    "            b{i} <= s{i}[9:2];".format(i=i)
    for i in range(8))

MOD = """//=============================================================================
// note_bars —— 音高可视化彩条 (屏幕底部)
//
//   ★ 为什么不是频谱分析 (2026-10-29 实测结论, 不是猜的):
//     做过两版 8 段带通滤波器组, 拿真实 music.hex 跑离线仿真验证:
//       - 一阶 HP+LP (6dB/oct) 做 8 段: 同一频率下各段只差 1.2 倍,
//         800Hz 输入的峰值落在 346~457Hz 段, 峰位不随音高移动;
//       - 换 12 位定点系数把选择性做上去: 8 段 x 2 个乘法器吃满
//         EG4S20 全部 29 个 DSP, 布局拥塞, HDMI 的 200MHz 串行路径
//         违例 (WNS -1.456ns / TNS -15.174ns), 上板画面卡死。
//     根因是音源为方波: 边沿是宽带脉冲, 每个频段都能捞到能量。
//
//   ★ 做法:
//     三个声部各有音号 (MIDI) 和包络 (0..255):
//       音号 -> 8 根柱子之一 (每 6 个半音换一根)
//       包络 -> 柱高 (0..120)
//     命中的柱子满高, 左右隔壁给 1/4 高, 看起来像一根有宽度的峰。
//     三个声部取最大值, 所以和弦会点亮两三根柱子。
//     每根柱子再做 0.75/0.25 一阶平滑, 换音时不硬闪。
//
//   ★ 音域: 本工程音号 40(E2,82Hz) ~ 91(G6,1568Hz)
//       40~45 -> 柱0   46~51 -> 柱1   52~57 -> 柱2   58~63 -> 柱3
//       64~69 -> 柱4   70~75 -> 柱5   76~81 -> 柱6   82以上 -> 柱7
//=============================================================================
module note_bars (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [6:0]  n0,
    input  wire [6:0]  n1,
    input  wire [6:0]  n2,
    input  wire [7:0]  g0,
    input  wire [7:0]  g1,
    input  wire [7:0]  g2,
    output wire [63:0] bars
);

    //---------------------------------------------------------
    // 音号 -> 柱子序号 (每 6 个半音一根, 覆盖 E2..G6)
    //---------------------------------------------------------
    function [2:0] nidx;
        input [6:0] n;
        begin
            if      (n < 7'd46) nidx = 3'd0;
            else if (n < 7'd52) nidx = 3'd1;
            else if (n < 7'd58) nidx = 3'd2;
            else if (n < 7'd64) nidx = 3'd3;
            else if (n < 7'd70) nidx = 3'd4;
            else if (n < 7'd76) nidx = 3'd5;
            else if (n < 7'd82) nidx = 3'd6;
            else                nidx = 3'd7;
        end
    endfunction

    // 包络 -> 柱高: 255 折到 120, 给屏幕留空间
    function [7:0] lvl;
        input [7:0] g;
        begin
            lvl = (g >= 8'd240) ? 8'd120 : (g >> 1);
        end
    endfunction

    // 单个声部对第 j 根柱子的贡献: 正上方满高, 左右各一格 1/4 高
    //   idx 与 j 都用 4 位, 避免 idx+1 在 idx=7 时回绕到 0 误判成相邻
    function [7:0] hit;
        input [3:0] idx;
        input [7:0] e;
        input [3:0] j;
        begin
            if (e == 8'd0)                                    hit = 8'd0;
            else if (idx == j)                                hit = e;
            else if ((idx + 4'd1 == j) || (j + 4'd1 == idx))   hit = e >> 2;
            else                                              hit = 8'd0;
        end
    endfunction

    function [7:0] mx3;
        input [7:0] a;
        input [7:0] b;
        input [7:0] c;
        reg   [7:0] m;
        begin
            m   = (a > b) ? a : b;
            mx3 = (m > c) ? m : c;
        end
    endfunction

    // 休止符(0x7F)不点亮
    wire [3:0] I0 = (n0 == 7'h7F) ? 4'd15 : {{1'b0, nidx(n0)}};
    wire [3:0] I1 = (n1 == 7'h7F) ? 4'd15 : {{1'b0, nidx(n1)}};
    wire [3:0] I2 = (n2 == 7'h7F) ? 4'd15 : {{1'b0, nidx(n2)}};

    wire [7:0] e0 = (n0 == 7'h7F) ? 8'd0 : lvl(g0);
    wire [7:0] e1 = (n1 == 7'h7F) ? 8'd0 : lvl(g1);
    wire [7:0] e2 = (n2 == 7'h7F) ? 8'd0 : lvl(g2);

    // 每根柱子的目标高度
{tgt}

    //---------------------------------------------------------
    // 32kHz 更新节拍 + 0.75/0.25 一阶平滑
    //   b = (3*b + target) / 4, 时间常数约 4 帧 (125ms)
    //   ★ 三个 b 相加会到 765, 必须扩到 10 位再移位, 否则溢出回绕
    //---------------------------------------------------------
    reg [10:0] sdiv;
    wire stk = (sdiv == 11'd1249);          // 40MHz / 32kHz = 1250

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)   sdiv <= 11'd0;
        else if (stk) sdiv <= 11'd0;
        else          sdiv <= sdiv + 11'd1;
    end

    reg  [7:0] b0, b1, b2, b3, b4, b5, b6, b7;
    reg [11:0] s0, s1, s2, s3, s4, s5, s6, s7;

    always @(*) begin
{smooth}
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            b0 <= 8'd0; b1 <= 8'd0; b2 <= 8'd0; b3 <= 8'd0;
            b4 <= 8'd0; b5 <= 8'd0; b6 <= 8'd0; b7 <= 8'd0;
        end else if (stk) begin
{upd}
        end
    end

    assign bars = {{b7, b6, b5, b4, b3, b2, b1, b0}};

endmodule
""".format(tgt=TGT, smooth=SMOOTH, upd=UPD)


def main():
    src = io.open(TARGET, encoding='utf-8').read()
    idx = src.find('//=============================================================================\n// note_bars')
    if idx < 0:
        idx = src.find('//=============================================================================\n// spec_bars')
    assert idx > 0, '找不到 note_bars/spec_bars 起点'
    io.open(TARGET, 'w', encoding='utf-8', newline='\n').write(src[:idx] + MOD)
    print('替换完成')


if __name__ == '__main__':
    main()
