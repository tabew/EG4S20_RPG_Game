//=============================================================================
// rpg_video.v —— 16x16 字符显示引擎(40 列 x 30 行 = 640x480)
//
// 每格 16bit: {bg[3:0], fg[3:0], glyph[7:0]}
//
// 三级直流水线(简单、不会有行边界错位):
//   S1  按当前 (x,y) 取格子数据            cell_r  <- cell_mem[idx]
//   S2  用 cell_r 的字形 + 子行号查字模    gw_r    <- font_q
//   S3  取该行第 sx 位, 配色输出
//
// 代价: 整幅图像右移 3 个像素(de/hs/vs 一起延迟, 显示器上看不出来)。
// 之所以不用"提前一格预取": 行末预取下一行首格时子行号要跨行 +1,
// 稍有不慎整屏错位 —— 实测踩过这个坑, 所以改用最不容易错的直流水线。
//=============================================================================
`timescale 1ns/1ps
module rpg_video (
    input  wire        clk,          // clk_pix = 25.175MHz
    input  wire        rst_n,

    // 格子写入端口(来自 rpg_core)
    input  wire        we,
    input  wire [10:0] waddr,
    input  wire [16:0] wdata,

    // 动态插图（图片层：窗口内且该格无字形时显示，文字压在图上）
    input  wire        anim_on,
    input  wire [2:0]  anim_frame,

    // 视频输出
    output wire        hs,
    output wire        vs,
    output wire        de,
    output wire [15:0] rgb
);

    //---------------------------------------------------------
    // 时序
    //---------------------------------------------------------
    wire [11:0] x, y;
    wire        hs_i, vs_i, de_i;

    vid_timing #(.MODE(1)) u_tmg (      // MODE=1 -> 640x480p60
        .clk         (clk),
        .rst_n       (rst_n),
        .hs          (hs_i),
        .vs          (vs_i),
        .de          (de_i),
        .hcnt        (x),
        .vcnt        (y),
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

    wire [10:0] cell_idx = (y[8:4] * 40) + x[9:4];

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
            y_d1    <= y[3:0];
            sx1     <= x[3:0];
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
    //   S0: 按 (x,y) 算源像素地址
    //   S1: BRAM 输出字节, 选高/低半字节
    //   S2: 调色板查表
    //   S3: 与字符层对齐输出
    //---------------------------------------------------------
    localparam integer AW = 128, AH = 96;            // 源尺寸
    localparam integer FRM_BYTES = AW * AH / 2;      // 每帧字节数
    localparam [11:0]  AX0 = 12'd192, AY0 = 12'd144; // 居中, 256x192

    wire in_win0 = anim_on &&
                   (x >= AX0) && (x < AX0 + 12'd256) &&
                   (y >= AY0) && (y < AY0 + 12'd192);

    // 注意：必须先做全宽相减再取位。用 y[7:0]-AY0[7:0] 的话，
    // y 超过 255 会回绕，图片下半部分会重复上半部分（实测踩过）。
    wire [11:0] ax = x - AX0;                         // 0..255
    wire [11:0] ay = y - AY0;                         // 0..191
    wire [6:0]  sx = ax[7:1];                         // /2 水平放大
    wire [6:0]  sy = ay[7:1];                         // /2 垂直放大（96 行需要 7 位!）
    wire [13:0] spix = {sy, sx};                      // sy*128 + sx, 0..12287
    wire [16:0] anim_addr = anim_frame * FRM_BYTES + (spix >> 1);

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

    // 混层：插图窗口内且该格没有字形 -> 出插图；否则出字符（文字/边框压在图上）
    wire [15:0] pix = (win3 && cell_r3[8:0] == 9'd0) ? anim_rgb_r : char_pix;

    assign hs  = hs3;
    assign vs  = vs3;
    assign de  = de3;
    assign rgb = de3 ? pix : 16'h0000;

endmodule
