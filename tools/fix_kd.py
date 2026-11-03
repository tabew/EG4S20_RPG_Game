# -*- coding: utf-8 -*-
"""从损坏的文件里恢复 key_debounce.v

损坏经过: bash heredoc 在 Windows 上追加时把文件写坏, 前 276 行丢失
(消抖模块 + sound 模块头部), 剩下 spec_bars + sound 从 bdiv 那行起的内容。
这里补回头部, 再拼接。
"""
import io

HEAD = r'''//=============================================================================
// key_debounce.v —— 按键消抖 + PSG 音频合成
//
//   本文件包含三个模块:
//     key_debounce  4x4 矩阵键盘的单键消抖 (低有效)
//     sound         PSG 合成器: 三声部 BGM + 一路音效, 输出 8 位 PCM
//     spec_bars     音频频谱彩条分析: 8 段带通 + 峰值包络
//=============================================================================
`timescale 1ns/1ps

//-----------------------------------------------------------------------------
// key_debounce —— 低有效按键消抖
//
//   板上 4x4 矩阵键盘, 行全部驱动为低, 列经 1k 上拉到 3.3V。
//   按下任意键把对应列拉低, 恰好匹配低有效的 key_n。
//
//   CLK_KHZ 是时钟频率的 kHz 数值, 用来把消抖时间换算成时钟数:
//     40MHz -> CLK_KHZ = 40000 -> 一个"毫秒" = 40000 个时钟
//-----------------------------------------------------------------------------
module key_debounce #(
    parameter integer CLK_KHZ = 40000
)(
    input  wire clk,
    input  wire rst_n,
    input  wire key_n,        // 低有效
    output reg  click,        // 按下瞬间, 单拍脉冲
    output reg  press,        // 按住期间保持高
    output reg  long_press    // 按住满 1 秒后单拍脉冲(之后每秒一次)
);

    localparam integer DEB_MS  = 15;                    // 消抖时间 15ms
    localparam integer CNT_MAX = CLK_KHZ * DEB_MS;      // 40e3*15 = 600000
    localparam integer HOLD_MS = 1000;                  // 长按判定 1s

    //---- 三级同步, 消除亚稳态 ----
    reg [2:0] sync;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) sync <= 3'b111;
        else        sync <= {sync[1:0], key_n};
    end

    wire kin = sync[2];

    reg [19:0] cnt;           // 消抖计数 (600000 需要 20 位)
    reg [10:0] hold;          // 长按计数, 单位 ms
    reg        stable;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cnt        <= 20'd0;
            hold       <= 11'd0;
            stable     <= 1'b1;
            click      <= 1'b0;
            press      <= 1'b0;
            long_press <= 1'b0;
        end else begin
            click      <= 1'b0;
            long_press <= 1'b0;

            if (kin != stable) begin
                // 电平变化: 连续稳定 DEB_MS 才认账
                if (cnt >= CNT_MAX - 1) begin
                    cnt    <= 20'd0;
                    stable <= kin;
                    hold   <= 11'd0;
                    if (!kin) begin
                        press <= 1'b1;
                        click <= 1'b1;
                    end else begin
                        press <= 1'b0;
                    end
                end else begin
                    cnt <= cnt + 20'd1;
                end
            end else begin
                cnt <= 20'd0;
                if (press) begin
                    if (hold >= HOLD_MS - 1) begin
                        hold       <= 11'd0;
                        long_press <= 1'b1;
                    end else begin
                        hold <= hold + 11'd1;
                    end
                end
            end
        end
    end

endmodule

//=============================================================================
// sound —— PSG 合成器
//
//   三个 BGM 声部: ch0 方波 50%(主旋律) / ch1 方波 25%(和声) / ch2 三角波(低音)
//   一个音效通道: 15 种事件音, 单频方波 + 末端淡出
//
//   采样率 32kHz, 相位累加器 24 位:
//     step = 频率 * 2^24 / SAMPLE_HZ = 频率 * 524288
//
//   BGM 表每步 32 位:
//     [6:0]   ch0 音高索引 (127 = 休止)
//     [13:7]  ch1 音高
//     [20:14] ch2 音高
//     [27:21] 本步时长(单位 1/4 拍, 1..127)
//
//   重要: 相位累加在 32kHz 采样节拍上推进, 所以音高步进必须按 SAMPLE_HZ
//        计算。早期版本误用 CLK_HZ, 音高低了 1250 倍。
//=============================================================================
module sound #(
    parameter integer CLK_HZ    = 40000000,
    parameter integer SAMPLE_HZ = 32000,
    parameter integer BPM       = 120,
    parameter integer LOOP_END  = 63
)(
    input  wire       clk,
    input  wire       rst_n,
    input  wire [3:0] sfx_id,      // 1..15, 0 = 静音
    input  wire       sfx_trig,    // 单拍触发
    input  wire       mus_on,      // BGM 开关(1=播放)
    input  wire [1:0] mus_sel,     // BGM 曲目: 0=探索 1=战斗 2=胜利/结局
    output reg  [7:0] dac          // 无符号 8 位 -> R-2R / PWM
);

    localparam integer DIV_S = CLK_HZ / SAMPLE_HZ;          // 40MHz/32kHz = 1250
    // 1/4 拍 = 60/(BPM*4) 秒, 即 CLK_HZ*15/BPM 个时钟。
    // 注意: 绝不能写成 (CLK_HZ*60)/(BPM*4)。40e6*60 = 2.4e9 会溢出 32 位
    //       integer(上限 2.147e9), 结果变成负数, 于是 btk 永远不触发、
    //       音符指针不动、三个声部全停在休止符 -> 整首 BGM 静音。
    localparam integer DIV_B = (CLK_HZ * 15) / BPM;         // 40e6*15/120 = 5,000,000
    localparam [7:0]   LOOP_LAST = LOOP_END;                // 参数不能直接位选

    //---------------------------------------------------------
    // 32kHz 采样节拍
    //---------------------------------------------------------
    reg [10:0] sdiv;
    wire stk = (sdiv == DIV_S - 1);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)           sdiv <= 11'd0;
        else if (stk)         sdiv <= 11'd0;
        else                  sdiv <= sdiv + 11'd1;
    end

    //---------------------------------------------------------
    // 音符节拍(1/4 拍)
    //---------------------------------------------------------
    reg [22:0] bdiv;
    wire btk = (bdiv == DIV_B - 1);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)           bdiv <= 23'd0;
        else if (btk)         bdiv <= 23'd0;
        else                  bdiv <= bdiv + 23'd1;
    end
'''


def main():
    path = 'rtl/common/key_debounce.v'
    lines = open(path, encoding='utf-8').read().split('\n')
    # 前 241 行是 spec_bars, 242 行起是 sound 的残余(第一行被截断, 已在前 4 行)
    part_spec = '\n'.join(lines[0:241])
    part_sound = '\n'.join(lines[241:])
    sl = part_sound.split('\n')
    # sl[0..3] = 被截断的 bdiv 赋值, header 里已经补全; 从 sl[4] 起是正文
    body = '\n'.join(sl[4:])

    out = HEAD + '\n' + body + '\n\n' + part_spec + '\n'
    with io.open(path, 'w', encoding='utf-8', newline='\n') as f:
        f.write(out)

    n = out.count('\n')
    print('written lines:', n)
    print('module count:', out.count('\nmodule ') + out.count('\nmodule\t'))


if __name__ == '__main__':
    main()
