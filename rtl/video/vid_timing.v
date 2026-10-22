//=============================================================================
// vid_timing.v —— 视频时序发生器 (CEA-861 标准)
//   MODE = 0 : 1280x720p60  像素时钟 74.25MHz   —— 默认, 画面好看
//   MODE = 1 : 640x480p60   像素时钟 25.175MHz  —— 第一次上板先用这个
//   MODE = 2 : 1920x1080p30 像素时钟 74.25MHz   —— 帧率高不了, 慎用
//
// 输出 hcnt/vcnt 给上层做坐标运算; de 为数据有效
// hs/vs 已经按 CEA 极性(正极性)输出, 并额外给出上升沿标志位,
// 供 hdmi_tx 在"行消隐区"插入音频数据岛
//=============================================================================
`timescale 1ns/1ps
module vid_timing #(
    parameter integer MODE = 0
)(
    input  wire        clk,         // 像素时钟
    input  wire        rst_n,
    output reg         hs,
    output reg         vs,
    output reg         de,
    output reg  [11:0] hcnt,
    output reg  [11:0] vcnt,
    output wire        hs_rise,     // 行同步上升沿(进入行后肩), 数据岛调度基准
    output wire        vs_rise,     // 场同步上升沿
    output wire        frame_start, // 每帧第一个有效行
    output wire        line_start,  // 每行第一个有效像素
    output wire [11:0] h_active,
    output wire [11:0] v_active
);

    // ---------------- 参数 ----------------  (H_ACT,H_FP,H_SYNC,H_BP) (V_ACT,V_FP,V_SYNC,V_BP)
    localparam integer H_ACT  = (MODE == 0) ? 1280 : (MODE == 1) ? 640 : 1920;
    localparam integer H_FP   = (MODE == 0) ? 110  : (MODE == 1) ? 16  : 88;
    localparam integer H_SYNC = (MODE == 0) ? 40   : (MODE == 1) ? 96  : 44;
    localparam integer H_BP   = (MODE == 0) ? 220  : (MODE == 1) ? 48  : 148;

    localparam integer V_ACT  = (MODE == 0) ? 720  : (MODE == 1) ? 480 : 1080;
    localparam integer V_FP   = (MODE == 0) ? 5    : (MODE == 1) ? 10  : 4;
    localparam integer V_SYNC = (MODE == 0) ? 5    : (MODE == 1) ? 2   : 5;
    localparam integer V_BP   = (MODE == 0) ? 20   : (MODE == 1) ? 33  : 36;

    localparam integer H_TOTAL = H_ACT + H_FP + H_SYNC + H_BP;
    localparam integer V_TOTAL = V_ACT + V_FP + V_SYNC + V_BP;

    assign h_active = H_ACT;
    assign v_active = V_ACT;

    reg hs_d, vs_d;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            hcnt <= 12'd0;
            vcnt <= 12'd0;
            hs   <= 1'b0;
            vs   <= 1'b0;
            de   <= 1'b0;
            hs_d <= 1'b0;
            vs_d <= 1'b0;
        end else begin
            // 行计数
            if (hcnt == H_TOTAL - 1) begin
                hcnt <= 12'd0;
                if (vcnt == V_TOTAL - 1) vcnt <= 12'd0;
                else                     vcnt <= vcnt + 12'd1;
            end else begin
                hcnt <= hcnt + 12'd1;
            end

            // 同步信号: 位于 active 之后, 依次 FP -> SYNC -> BP
            hs   <= (hcnt >= H_ACT + H_FP) && (hcnt < H_ACT + H_FP + H_SYNC);
            vs   <= (vcnt >= V_ACT + V_FP) && (vcnt < V_ACT + V_FP + V_SYNC);
            de   <= (hcnt < H_ACT) && (vcnt < V_ACT);
            hs_d <= hs;
            vs_d <= vs;
        end
    end

    assign hs_rise    = hs & ~hs_d;
    assign vs_rise    = vs & ~vs_d;
    assign line_start = (hcnt == 12'd0) && (vcnt < V_ACT);
    assign frame_start= (hcnt == 12'd0) && (vcnt == 12'd0);

endmodule
