//=============================================================================
// tb_video.v —— 跑完整视频通路, 导出真实像素
//
//   rpg_core(画格子) + rpg_video(字符屏时序) -> vga_rgb/de/hs/vs
//
// 关键技巧: 视频域复位比核心晚 3500 周期释放。
//   核心只要约 3000 周期就把标题屏画完了, 所以等它画完再启动扫描,
//   第一帧就是完整的, 不用为了等第二帧多跑 42 万周期。
//
// 运行: yosys -s sim/run_video.ys
//       python tools/vcd_frame.py      -> 输出 preview/sim_frame.png
//=============================================================================
`timescale 1ns/1ps

module tb_video (
    input  wire        clk,
    output wire        o_de,
    output wire        o_hs,
    output wire        o_vs,
    output wire [15:0] o_rgb,
    output wire [31:0] o_cyc,
    output wire [2:0]  o_scene,
    output wire [3:0]  o_state,
    output wire [9:0]  o_hp,
    output wire [11:0] o_gold
);

    reg [31:0] cyc  = 0;
    reg        rst_core_n = 0;
    reg        rst_vid_n  = 0;
    reg  [3:0] key = 4'b0000;

    wire        we;
    wire [10:0] waddr;
    wire [15:0] wdata;
    wire        hs, vs, de;
    wire [15:0] rgb;

    rpg_core u_core (
        .clk        (clk),
        .rst_n      (rst_core_n),
        .key        (key),
        .we         (we),
        .waddr      (waddr),
        .wdata      (wdata),
        .dbg_scene  (o_scene),
        .dbg_hp     (o_hp),
        .dbg_maxhp  (),
        .dbg_atk    (),
        .dbg_def    (),
        .dbg_gold   (o_gold),
        .dbg_lv     (),
        .dbg_state  (o_state),
        .dbg_pc     ()
    );

    rpg_video u_vid (
        .clk   (clk),
        .rst_n (rst_vid_n),
        .we    (we),
        .waddr (waddr),
        .wdata (wdata),
        .hs    (hs),
        .vs    (vs),
        .de    (de),
        .rgb   (rgb)
    );

    assign o_de  = de;
    assign o_hs  = hs;
    assign o_vs  = vs;
    assign o_rgb = rgb;
    assign o_cyc = cyc;

`ifndef KEY1_AT
`define KEY1_AT 0            // 0 = 不按键
`endif
`ifndef KEY2_AT
`define KEY2_AT 0
`endif
`ifndef VID_AT
`define VID_AT 3500
`endif

    always @(posedge clk) begin
        cyc <= cyc + 1;
        if (cyc == 3) rst_core_n <= 1'b1;
        if (cyc == `VID_AT) rst_vid_n <= 1'b1;   // 等核心画完再启动扫描
        if (`KEY1_AT != 0) begin
            if (cyc == `KEY1_AT)       key <= 4'b0001;
            if (cyc == `KEY1_AT + 2)   key <= 4'b0000;
        end
        if (`KEY2_AT != 0) begin
            if (cyc == `KEY2_AT)       key <= 4'b0001;
            if (cyc == `KEY2_AT + 2)   key <= 4'b0000;
        end
    end

endmodule
