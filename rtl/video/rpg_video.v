//=============================================================================
// rpg_video.v —— 16x16 字符显示引擎 + 动态插图层 + 怪物立绘层
//
// 逻辑分辨率 640x480 (40 列 x 30 行), 输出 800x600 (MODE=3, 1.25x 缩放)。
//
// 每格 17bit: {bg[3:0], fg[3:0], glyph[8:0]}
//
// 三级直流水线(简单、不会有行边界错位):
//   S1  按当前 (xs,ys) 取格子数据          cell_r  <- cell_mem[idx]
//   S2  用 cell_r 的字形 + 子行号查字模    gw_r    <- font_q
//   S3  取该行第 sx 位, 配色输出
//
// ★ 800x600 适配: vid_timing MODE=3 同时输出
//     (x,y)   = 输出像素坐标 0..799 / 0..599
//     (xs,ys) = 缩放回逻辑坐标 0..639 / 0..479
//   所有"第几列第几个字符格"的运算、插图窗口、立绘窗口全部用 xs/ys,
//   因此游戏逻辑和美术素材仍是 640x480 坐标, 只是被整体放大 1.25 倍。
//   xs/ys 与 x/y 由同一组寄存器同步更新, 相位一致, 流水线对齐关系不变。
//=============================================================================
`timescale 1ns/1ps
module rpg_video #(
    parameter integer TEST_BARS = 0   // 0=正常游戏画面; 1=纯色条测试(诊断 TMDS 链路)
)(
    input  wire        clk,          // clk_pix = 40MHz (800x600)
    input  wire        rst_n,

    // 格子写入端口(来自 rpg_core)
    input  wire        we,
    input  wire [10:0] waddr,
    input  wire [16:0] wdata,

    // 动态插图（图片层：窗口内且该格无字形时显示，文字压在图上）
    input  wire        anim_on,
    input  wire [2:0]  anim_frame,

    // 怪物立绘层（战斗界面，带淡入淡出）
    input  wire        mon_on,
    input  wire [4:0]  mon_id,
    input  wire [3:0]  mon_fade,

    // 视频输出
    output wire        hs,
    output wire        vs,
    output wire        de,
    output wire [15:0] rgb
);

    //---------------------------------------------------------
    // 时序: MODE=3 -> 800x600p60 (40MHz), 内部带 1.25x 缩放器
    //---------------------------------------------------------
    wire [11:0] x, y;          // 输出像素坐标 (0..799 / 0..599)
    wire [11:0] xs, ys;        // 缩放回逻辑坐标 (0..639 / 0..479)
    wire        hs_i, vs_i, de_i;

    vid_timing #(.MODE(3)) u_tmg (
        .clk         (clk),
        .rst_n       (rst_n),
        .hs          (hs_i),
        .vs          (vs_i),
        .de          (de_i),
        .hcnt        (x),
        .vcnt        (y),
        .src_x       (xs),
        .src_y       (ys),
        .hs_rise     (),
        .vs_rise     (),
        .frame_start (),
        .line_start  (),
        .h_active    (),
        .v_active    ()
    );

    //---------------------------------------------------------
    // 格子 RAM(简单双口: 一写一读, 必须分两个 always 块)
    //---------------------------------------------------------
    reg [16:0] cell_mem [0:1199];
    reg [16:0] cell_r;

    wire [10:0] cell_idx = (ys[8:4] * 40) + xs[9:4];

    always @(posedge clk) begin
        if (we) cell_mem[waddr] <= wdata;
    end

    always @(posedge clk) begin
        cell_r <= cell_mem[cell_idx];
    end

    //---------------------------------------------------------
    // 字模 ROM
    //---------------------------------------------------------
    reg  [3:0]  y_d1;
    wire [12:0] font_a;
    wire [15:0] font_q;

    assign font_a = {cell_r[8:0], y_d1};     // 字形号来自延迟一拍的格子

    font_rom u_font (
        .clk   (clk),
        .glyph (font_a[12:4]),
        .row   (font_a[3:0]),
        .data  (font_q)
    );

    //---------------------------------------------------------
    // 流水线寄存器
    //---------------------------------------------------------
    reg [16:0] cell_r2, cell_r3;      // 颜色与像素对齐用
    reg [15:0] gw_r;                  // 字模行数据
    reg [3:0]  sx1, sx2, sx3;
    reg        de1, de2, de3;
    reg        hs1, hs2, hs3;
    reg        vs1, vs2, vs3;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            y_d1    <= 4'd0;
            cell_r2 <= 17'd0;
            cell_r3 <= 17'd0;
            gw_r    <= 16'd0;
            sx1     <= 4'd0;
            sx2     <= 4'd0;
            sx3     <= 4'd0;
            de1 <= 1'b0; de2 <= 1'b0; de3 <= 1'b0;
            hs1 <= 1'b0; hs2 <= 1'b0; hs3 <= 1'b0;
            vs1 <= 1'b0; vs2 <= 1'b0; vs3 <= 1'b0;
        end else begin
            // ---- S1 -> S2 ----
            y_d1    <= ys[3:0];
            sx1     <= xs[3:0];
            cell_r2 <= cell_r;
            de1     <= de_i;
            hs1     <= hs_i;
            vs1     <= vs_i;

            // ---- S2 -> S3 ----
            gw_r    <= font_q;
            cell_r3 <= cell_r2;
            sx2     <= sx1;
            de2     <= de1;
            hs2     <= hs1;
            vs2     <= vs1;

            // ---- S3 输出 ----
            sx3     <= sx2;
            de3     <= de2;
            hs3     <= hs2;
            vs3     <= vs2;
        end
    end

    //---------------------------------------------------------
    // 动态插图层（4bpp 位图，2 倍放大到 256x192，居中）
    //
    //   S0: 按 (xs,ys) 算源像素地址
    //   S1: BRAM 输出字节, 选高/低半字节
    //   S2: 调色板查表
    //   S3: 与字符层对齐输出
    //---------------------------------------------------------
    localparam integer AW = 128, AH = 96;            // 源尺寸
    localparam integer FRM_BYTES = AW * AH / 2;      // 每帧字节数
    localparam [11:0]  AX0 = 12'd192, AY0 = 12'd144; // 居中, 256x192

    wire in_win0 = anim_on &&
                   (xs >= AX0) && (xs < AX0 + 12'd256) &&
                   (ys >= AY0) && (ys < AY0 + 12'd192);

    // 注意：必须先做全宽相减再取位。用 ys[7:0]-AY0[7:0] 的话，
    // ys 超过 255 会回绕，图片下半部分会重复上半部分（实测踩过）。
    wire [11:0] ax = xs - AX0;                        // 0..255
    wire [11:0] ay = ys - AY0;                        // 0..191
    wire [6:0]  sx = ax[7:1];                         // /2 水平放大
    wire [6:0]  sy = ay[7:1];                         // /2 垂直放大（96 行需要 7 位!）
    wire [13:0] spix = {sy, sx};                      // sy*128 + sx, 0..12287
    wire [1:0]  afr = anim_frame[1:0];                // 4 帧 ROM, 手动翻帧也只循环 0..3
    wire [14:0] anim_addr = afr * FRM_BYTES + (spix >> 1);   // 最大 24575, 15 位够

    wire [7:0]  anim_byte;
    wire [15:0] anim_rgb;
    reg  [3:0]  pal_idx;
    reg         win1, win2, win3;
    reg  [15:0] anim_rgb_r;

    anim_rom u_anim (
        .clk     (clk),
        .addr    (anim_addr),
        .data    (anim_byte),
        .pal_idx (pal_idx),
        .pal_rgb (anim_rgb)
    );

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pal_idx    <= 4'd0;
            win1 <= 1'b0; win2 <= 1'b0; win3 <= 1'b0;
            anim_rgb_r <= 16'h0000;
        end else begin
            pal_idx    <= spix[0] ? anim_byte[3:0] : anim_byte[7:4];
            win1       <= in_win0;
            win2       <= win1;
            win3       <= win2;
            anim_rgb_r <= anim_rgb;
        end
    end

    //---------------------------------------------------------
    // 怪物立绘层（坐标同样用逻辑坐标 xs/ys）
    //---------------------------------------------------------
    wire        mon_win;
    wire [15:0] mon_rgb;
    wire        mon_valid;

    mon_layer u_mon (
        .clk    (clk),
        .rst_n  (rst_n),
        .mon_id (mon_id),
        .fade   (mon_fade),
        .x      (xs),
        .y      (ys),
        .in_win (mon_win),
        .rgb    (mon_rgb),
        .valid  (mon_valid)
    );

    //---------------------------------------------------------
    // 调色板
    //---------------------------------------------------------
    function [15:0] pal;
        input [3:0] c;
        begin
            case (c)
                4'd0:  pal = 16'h0000;
                4'd1:  pal = 16'h18E3;
                4'd2:  pal = 16'h4208;
                4'd3:  pal = 16'h7BEF;
                4'd4:  pal = 16'hFFFF;
                4'd5:  pal = 16'hF800;
                4'd6:  pal = 16'h8000;
                4'd7:  pal = 16'hFD20;
                4'd8:  pal = 16'hFFE0;
                4'd9:  pal = 16'h07E0;
                4'd10: pal = 16'h03E0;
                4'd11: pal = 16'h07FF;
                4'd12: pal = 16'h001F;
                4'd13: pal = 16'h781F;
                4'd14: pal = 16'hF81F;
                default: pal = 16'hC618;
            endcase
        end
    endfunction

    wire        bit_on   = gw_r[15 - sx3];
    wire [15:0] char_pix = pal(bit_on ? cell_r3[12:9] : cell_r3[16:13]);

    // 混层优先级：怪物立绘 > 动态插图 > 字符层
    //   前两者只在"该格没有字形"时透出，所以文字和边框始终压在图上
    wire cell_blank = (cell_r3[8:0] == 9'd0);
    wire [15:0] pix = (mon_on && mon_valid && cell_blank) ? mon_rgb :
                      (win3 && cell_blank)                ? anim_rgb_r : char_pix;

    //---------------------------------------------------------
    // 诊断色条(仅 TEST_BARS=1 时): 8 条 100 像素宽, 绕过所有图层
    //---------------------------------------------------------
    wire [15:0] bars = (x < 12'd100) ? 16'hFFFF :
                       (x < 12'd200) ? 16'hFFE0 :
                       (x < 12'd300) ? 16'h07FF :
                       (x < 12'd400) ? 16'h07E0 :
                       (x < 12'd500) ? 16'hF81F :
                       (x < 12'd600) ? 16'hF800 :
                       (x < 12'd700) ? 16'h001F : 16'h0000;

    assign hs  = TEST_BARS ? hs_i : hs3;
    assign vs  = TEST_BARS ? vs_i : vs3;
    assign de  = TEST_BARS ? de_i : de3;
    assign rgb = TEST_BARS ? (de_i ? bars : 16'h0000)
                           : (de3 ? pix  : 16'h0000);

endmodule
