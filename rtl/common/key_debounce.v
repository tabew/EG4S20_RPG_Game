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


//=============================================================================
// buzzer —— 无源蜂鸣器音效发生器（和 key_debounce 放同一文件是刻意的：
//   key_debounce.v 早就在 TD 工程里，这样就不用再手动 Add Source Files）
//
//   板上是无源蜂鸣器（9040 直插），经 MMBT3906 PNP 三极管驱动：
//     FPGA 引脚 -> 2.21k -> 基极；发射极 3.3V；集电极 -> 蜂鸣器
//   所以【低电平 = 蜂鸣器通电】，输出取反。
//
//   无源蜂鸣器没有内部振荡器，必须由外部送方波，频率决定音高
//   （1~3kHz 最响）。本模块按 id 查表得到"半周期计数 + 半周期个数"，
//   播放一次自动停止。
//
//   id 音效表（clk = 40MHz）：
//     1  1200Hz  35ms  按键/菜单
//     2   300Hz 120ms  被击中
//     3  2000Hz  40ms  击杀
//     4  1500Hz 200ms  升级
//     5   200Hz 500ms  阵亡
//     6  2400Hz 250ms  通关
//     7  1000Hz 120ms  上电自检提示音
//=============================================================================
module buzzer (
    input  wire       clk,
    input  wire       rst_n,
    input  wire [2:0] id,        // 1..7, 0 = 静音
    input  wire       trig,      // 单拍触发脉冲
    output wire       buzz_n     // 低有效（PNP 三极管）
);

    //---------------------------------------------------------
    // 音效参数表
    //---------------------------------------------------------
    reg [16:0] half_n;      // 半个周期的时钟数
    reg [10:0] halves_n;    // 总半周期数 (= 2 x 整周期数)

    always @(*) begin
        case (id)
            3'd1: begin half_n = 17'd16667; halves_n = 11'd84;   end // 1.2kHz 35ms
            3'd2: begin half_n = 17'd66667; halves_n = 11'd72;   end // 300Hz 120ms
            3'd3: begin half_n = 17'd10000; halves_n = 11'd160;  end // 2.0kHz 40ms
            3'd4: begin half_n = 17'd13333; halves_n = 11'd600;  end // 1.5kHz 200ms
            3'd5: begin half_n = 17'd100000;halves_n = 11'd200;  end // 200Hz 500ms
            3'd6: begin half_n = 17'd8333;  halves_n = 11'd1200; end // 2.4kHz 250ms
            3'd7: begin half_n = 17'd20000; halves_n = 11'd240;  end // 1.0kHz 120ms
            default: begin half_n = 17'd20000; halves_n = 11'd0; end
        endcase
    end

    //---------------------------------------------------------
    // 播放状态机
    //---------------------------------------------------------
    reg [16:0] half;        // 本次音效的半周期
    reg [16:0] cnt;         // 半周期内计数
    reg [10:0] left;        // 剩余半周期数
    reg        pwm;
    reg        run;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            half <= 17'd20000;
            cnt  <= 17'd0;
            left <= 11'd0;
            pwm  <= 1'b0;
            run  <= 1'b0;
        end else if (trig && id != 3'd0) begin
            half <= half_n;
            cnt  <= 17'd0;
            left <= halves_n;
            pwm  <= 1'b1;
            run  <= (halves_n != 11'd0);
        end else if (run) begin
            if (cnt + 17'd1 >= half) begin
                cnt <= 17'd0;
                pwm <= ~pwm;
                if (left <= 11'd1) begin
                    run <= 1'b0;
                    pwm <= 1'b0;
                end else begin
                    left <= left - 11'd1;
                end
            end else begin
                cnt <= cnt + 17'd1;
            end
        end
    end

    // PNP 三极管：低电平导通
    assign buzz_n = ~pwm;

endmodule
