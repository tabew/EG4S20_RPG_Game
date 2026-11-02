//=============================================================================
// vid_timing.v —— 视频时序发生器 (CEA-861 / VESA DMT 标准)
//   MODE = 0 : 1280x720p60   像素时钟 74.25MHz
//   MODE = 1 : 640x480p60    像素时钟 25.175MHz
//   MODE = 2 : 1920x1080p30  像素时钟 74.25MHz  —— 帧率高不了, 慎用
//   MODE = 3 : 800x600p60    像素时钟 40.000MHz —— 本工程使用
//              VESA DMT 标准: H 总 1056 (800+40+128+88), V 总 628 (600+1+4+23)
//              H/V 同步均为【正极性】(+hsync +vsync, 与 640x480 不同!)
//              PLL 可以精确生成 (VCO=800MHz: /20=40, /4=200)。
//
// ★ 1.25x 缩放器 (MODE=3):
//   游戏画面逻辑分辨率仍是 640x480 (40x30 字符格), 输出 800x600。
//   src_x = floor(out_x * 4/5), src_y = floor(out_y * 4/5)。
//   用相位累加器实现, 无乘法器: 每 5 个输出像素/行, 第 1 个复用源像素
//   (宽度 2), 其余 4 个一一对应 —— 源像素宽度模式 [2,1,1,1]。
//   rpg_video 用 src_x/src_y 代替 hcnt/vcnt 查格子缓冲即可, 游戏逻辑零改动。
//
// 输出 hcnt/vcnt 给上层做坐标运算; de 为数据有效
// hs/vs 已按各模式的显示器标准极性输出, 并额外给出上升沿标志位,
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
    output wire [11:0] src_x,       // 缩放后源坐标(MODE=3), 其余模式 = hcnt/vcnt
    output wire [11:0] src_y,
    output wire        hs_rise,     // 行同步上升沿(进入行后肩), 数据岛调度基准
    output wire        vs_rise,     // 场同步上升沿
    output wire        frame_start, // 每帧第一个有效行
    output wire        line_start,  // 每行第一个有效像素
    output wire [11:0] h_active,
    output wire [11:0] v_active
);

    // ---------------- 参数 ----------------  (H_ACT,H_FP,H_SYNC,H_BP) (V_ACT,V_FP,V_SYNC,V_BP)
    localparam integer H_ACT  = (MODE == 0) ? 1280 :
                                (MODE == 1) ? 640  :
                                (MODE == 3) ? 800  : 1920;
    localparam integer H_FP   = (MODE == 0) ? 110  :
                                (MODE == 1) ? 16   :
                                (MODE == 3) ? 40   : 88;
    localparam integer H_SYNC = (MODE == 0) ? 40   :
                                (MODE == 1) ? 96   :
                                (MODE == 3) ? 128  : 44;
    localparam integer H_BP   = (MODE == 0) ? 220  :
                                (MODE == 1) ? 48   :
                                (MODE == 3) ? 88   : 148;

    localparam integer V_ACT  = (MODE == 0) ? 720  :
                                (MODE == 1) ? 480  :
                                (MODE == 3) ? 600  : 1080;
    localparam integer V_FP   = (MODE == 0) ? 5    :
                                (MODE == 1) ? 10   :
                                (MODE == 3) ? 1    : 4;
    localparam integer V_SYNC = (MODE == 0) ? 5    :
                                (MODE == 1) ? 2    :
                                (MODE == 3) ? 4    : 5;
    localparam integer V_BP   = (MODE == 0) ? 20   :
                                (MODE == 1) ? 33   :
                                (MODE == 3) ? 23   : 36;

    localparam integer H_TOTAL = H_ACT + H_FP + H_SYNC + H_BP;
    localparam integer V_TOTAL = V_ACT + V_FP + V_SYNC + V_BP;

    assign h_active = H_ACT;
    assign v_active = V_ACT;

    reg hs_d, vs_d;

    // 同步极性(按显示器标准, VESA DMT):
    //   640x480p60 : 负极性 (-/-)
    //   800x600p60 : 正极性 (+/+)  ← 注意与 640x480 相反!
    //   720p60 / 1080p30 (CEA-861): H/V 同步均为【正极性】
    wire hs_p = (hcnt >= H_ACT + H_FP) && (hcnt < H_ACT + H_FP + H_SYNC);
    wire vs_p = (vcnt >= V_ACT + V_FP) && (vcnt < V_ACT + V_FP + V_SYNC);
    wire sync_neg = (MODE == 1);

    //---------------------------------------------------------
    // 1.25x 缩放累加器 (仅 MODE=3 启用; 其余模式直通)
    //   规则: 源像素宽 [2,1,1,1] 循环 -> src = floor(out*4/5)
    //   phx/phy 为 0..4 相位, 相位 0 时保持(宽像素), 其余推进
    //---------------------------------------------------------
    reg  [9:0]  sx_r;
    reg  [8:0]  sy_r;
    reg  [2:0]  phx, phy;
    wire        scale_on = (MODE == 3);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            hcnt <= 12'd0;
            vcnt <= 12'd0;
            hs   <= 1'b0;
            vs   <= 1'b0;
            de   <= 1'b0;
            hs_d <= 1'b0;
            vs_d <= 1'b0;
            sx_r <= 10'd0;
            sy_r <= 9'd0;
            phx  <= 3'd0;
            phy  <= 3'd0;
        end else begin
            // 行计数
            if (hcnt == H_TOTAL - 1) begin
                hcnt <= 12'd0;
                // ---- 每行一次: 垂直缩放推进 ----
                if (vcnt == V_TOTAL - 1) begin
                    vcnt <= 12'd0;
                    sy_r <= 9'd0;          // 帧回绕: 源行归零
                    phy  <= 3'd0;
                end else begin
                    vcnt <= vcnt + 12'd1;
                    if (scale_on && (vcnt < V_ACT - 1)) begin
                        if (phy == 3'd0) phy <= 3'd1;   // 宽行: 源行保持
                        else begin
                            phy <= (phy == 3'd4) ? 3'd0 : phy + 3'd1;
                            sy_r <= sy_r + 9'd1;
                        end
                    end
                end
                // ---- 行回绕: 源列归零 ----
                sx_r <= 10'd0;
                phx  <= 3'd0;
            end else begin
                hcnt <= hcnt + 12'd1;
                // ---- 每像素: 水平缩放推进 (只在前 799 像素推进) ----
                if (scale_on && (hcnt < H_ACT - 1)) begin
                    if (phx == 3'd0) phx <= 3'd1;       // 宽像素: 源列保持
                    else begin
                        phx <= (phx == 3'd4) ? 3'd0 : phx + 3'd1;
                        sx_r <= sx_r + 10'd1;
                    end
                end
            end

            // 同步信号: 位于 active 之后, 依次 FP -> SYNC -> BP
            hs   <= sync_neg ? ~hs_p : hs_p;
            vs   <= sync_neg ? ~vs_p : vs_p;
            de   <= (hcnt < H_ACT) && (vcnt < V_ACT);
            hs_d <= hs;
            vs_d <= vs;
        end
    end

    // 缩放模式输出源坐标; 其他模式直通
    assign src_x = scale_on ? {2'd0, sx_r} : hcnt;
    assign src_y = scale_on ? {3'd0, sy_r} : vcnt;

    assign hs_rise    = hs & ~hs_d;
    assign vs_rise    = vs & ~vs_d;
    assign line_start = (hcnt == 12'd0) && (vcnt < V_ACT);
    assign frame_start= (hcnt == 12'd0) && (vcnt == 12'd0);

endmodule
