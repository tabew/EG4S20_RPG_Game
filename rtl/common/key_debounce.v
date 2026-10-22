//=============================================================================
// key_debounce.v —— 机械按键消抖 + 短按脉冲 + 长按检测
//   click      : 短按(松开时)输出 1 个 clk 周期脉冲
//   press      : 按下期间保持 1
//   long_press : 按住超过 HOLD_MS 后输出 1 个脉冲(用于进入设参模式)
// 说明: 采样节拍 1ms, 连续 DEB_MS 稳定才认账
//=============================================================================
`timescale 1ns/1ps
module key_debounce #(
    parameter integer CLK_KHZ = 100000,   // 输入时钟, 单位 kHz
    parameter integer DEB_MS  = 20,       // 消抖时间 ms
    parameter integer HOLD_MS = 1200       // 长按判定 ms
)(
    input  wire clk,
    input  wire rst_n,
    input  wire key_n,        // 按键输入, 低有效
    output reg  click,
    output reg  press,
    output reg  long_press
);

    reg        long_f;        // 本次按下已判为长按
    reg [15:0] ms_cnt;
    reg        key_meta, key_sync;
    reg [15:0] deb_cnt;
    reg        key_stable;    // 1=松开 0=按下
    reg [15:0] hold_ms;

    localparam integer CNT_1MS = (CLK_KHZ < 1) ? 1 : CLK_KHZ;
    wire tick_1ms = (ms_cnt == CNT_1MS - 1);

    // ---- 1ms 节拍 ----
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)        ms_cnt <= 16'd0;
        else if (tick_1ms) ms_cnt <= 16'd0;
        else               ms_cnt <= ms_cnt + 16'd1;
    end

    // ---- 输入同步 ----
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            key_meta <= 1'b1;
            key_sync <= 1'b1;
        end else begin
            key_meta <= key_n;
            key_sync <= key_meta;
        end
    end

    // ---- 消抖 ----
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            deb_cnt    <= 16'd0;
            key_stable <= 1'b1;
        end else if (key_sync != key_stable) begin
            if (tick_1ms) begin
                if (deb_cnt >= DEB_MS) begin
                    key_stable <= key_sync;
                    deb_cnt    <= 16'd0;
                end else begin
                    deb_cnt <= deb_cnt + 16'd1;
                end
            end
        end else begin
            deb_cnt <= 16'd0;
        end
    end

    // ---- 长按 ----
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            hold_ms    <= 16'd0;
            long_press <= 1'b0;
            long_f     <= 1'b0;
        end else begin
            long_press <= 1'b0;
            if (!key_stable) begin
                if (tick_1ms) begin
                    if (hold_ms < HOLD_MS + 1) hold_ms <= hold_ms + 16'd1;
                    if (hold_ms == HOLD_MS) begin
                        long_press <= 1'b1;
                        long_f     <= 1'b1;
                    end
                end
            end else begin
                hold_ms <= 16'd0;
                long_f  <= 1'b0;
            end
        end
    end

    // ---- 短按 / 状态输出 ----
    reg press_d;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            press_d <= 1'b0;
            press   <= 1'b0;
            click   <= 1'b0;
        end else begin
            press_d <= !key_stable;
            press   <= !key_stable;
            click   <= press_d & key_stable & ~long_f;
        end
    end

endmodule
