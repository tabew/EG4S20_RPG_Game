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
    parameter integer TEST_BARS = 0,  // 0=normal layers; 1=link diagnostic bars
    parameter integer VIDEO_MODE = 3 // 3=800x600/40MHz; 1=CEA VIC1 640x480/25.2MHz
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
    input  wire [1:0]  mon_rotation, // clockwise quarter turns, monster layer only
    input  wire        mon_mirror,   // horizontal mirror after rotation

    // 彩条高度（来自 note_bars，每 8 位一根，0..120）
    input  wire [63:0] bars,

    // 相册（图片轮播）层：gal_on=1 时整屏接管，音乐与彩条不受影响
    input  wire        gal_on,
    input  wire [1:0]  gal_img,      // 当前图片号 0..3
    input  wire [3:0]  gal_fade,     // 淡入淡出等级 0(黑)..8(全亮)

    // TF 卡图片 (sd_img 读卡解码后的 256x192 缩略图, 相册全部页共用)
    input  wire        tf_valid,     // 1 = tf_ram 内容有效
    input  wire [1:0]  tf_err,       // 0无 1无卡/初始化失败 2无BMP 3格式不符 (诊断窗色)
    input  wire [7:0]  diag,         // 诊断里程碑: bit0..4=SPI初始化步骤 bit5=找到BMP bit6=图片写入
    input  wire [7:0]  diag2,        // 诊断第二排: 轮询字节 (ACMD41 R1 / BPB 字段 / 状态码), MSB 在左
    input  wire        dfill,        // 第二排消隐: 1=整排不画 (分隔相邻两次读数)
    input  wire [3:0]  tf_rdata,     // tf_ram 读数据 (1 拍延迟)
    output wire [15:0] tf_raddr,     // tf_ram 读地址 (0..49151, 16位)

    // Media controls: explicit case defaults retain legacy behavior on open ports.
    input wire [1:0] media_mode,
    input wire media_auto, media_settings, media_loading, media_osd,
    input wire [5:0] media_index, media_count,
    input wire [63:0] media_name, // eight basename ASCII bytes, MSB first
    input wire [3:0] media_brightness,
    input wire [1:0] media_contrast, media_view,
    input wire media_visual,
    output wire frame_tick, // one pixel clock at the beginning of vertical blank

    // 视频输出
    output wire        hs,
    output wire        vs,
    output wire        de,
    output wire [15:0] rgb,
    // Sequential RGB888 framebuffer: request at S2, pixel/valid at S3.
    input wire fb_front_valid, fb_pixel_valid,
    input wire [23:0] fb_pixel_rgb,
    output wire fb_pixel_req,
    output wire [23:0] rgb_full,
    // Optional real-spectrum outer frame. Open/X enable retains legacy pixels.
    input wire spectrum_border_en,
    input wire [63:0] spectrum_levels // eight unsigned bytes, clamped to 0..120
);

    //---------------------------------------------------------
    // 时序: MODE=3 -> 800x600p60 (40MHz), 内部带 1.25x 缩放器
    //---------------------------------------------------------
    wire [11:0] x, y;          // 输出像素坐标 (0..799 / 0..599)
    wire [11:0] xs, ys;
    wire [11:0] src_x_raw, src_y_raw;
    reg [11:0] timing_x, timing_y;
    // vid_timing registers HS/VS/DE from the previous raw counter value.
    // The edge-to-edge CEA image requires coordinates from that same clock.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin timing_x<=0; timing_y<=0; end
        else begin timing_x<=x; timing_y<=y; end
    end
    wire [11:0] raster_x = (VIDEO_MODE==1) ? timing_x : x;
    wire [11:0] raster_y = (VIDEO_MODE==1) ? timing_y : y;
    assign xs = (VIDEO_MODE==1) ? timing_x : src_x_raw;
    assign ys = (VIDEO_MODE==1) ? timing_y : src_y_raw;
    wire        hs_i, vs_i, de_i;

    vid_timing #(.MODE(VIDEO_MODE)) u_tmg (
        .clk         (clk),
        .rst_n       (rst_n),
        .hs          (hs_i),
        .vs          (vs_i),
        .de          (de_i),
        .hcnt        (x),
        .vcnt        (y),
        .src_x       (src_x_raw),
        .src_y       (src_y_raw),
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
    // 坐标要跟着流水线一起延迟, 否则彩条会偏移 3 个像素
    reg [11:0] xd1, xd2, xd3;
    reg [11:0] yd1, yd2, yd3;

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
            xd1 <= 12'd0; xd2 <= 12'd0; xd3 <= 12'd0;
            yd1 <= 12'd0; yd2 <= 12'd0; yd3 <= 12'd0;
        end else begin
            // ---- S1 -> S2 ----
            y_d1    <= ys[3:0];
            sx1     <= xs[3:0];
            cell_r2 <= cell_r;
            de1     <= de_i;
            hs1     <= hs_i;
            vs1     <= vs_i;
            xd1     <= raster_x;
            yd1     <= raster_y;

            // ---- S2 -> S3 ----
            gw_r    <= font_q;
            cell_r3 <= cell_r2;
            sx2     <= sx1;
            de2     <= de1;
            hs2     <= hs1;
            vs2     <= vs1;
            xd2     <= xd1;
            yd2     <= yd1;

            // ---- S3 输出 ----
            sx3     <= sx2;
            de3     <= de2;
            hs3     <= hs2;
            vs3     <= vs2;
            xd3     <= xd2;
            yd3     <= yd2;
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
        .rotation(mon_rotation),.mirror(mon_mirror),
        .x      (xs),
        .y      (ys),
        .in_win (mon_win),
        .rgb    (mon_rgb),
        .valid  (mon_valid)
    );

    //---------------------------------------------------------
    // 相册层（图片轮播，待机时整屏显示）
    //   地址用第 2 级坐标 (xd2/yd2) 发起 ROM 读，1 拍后数据返回，
    //   恰好与第 3 级输出 (xd3/yd3) 对齐，不改主流水线深度。
    //---------------------------------------------------------
    wire [15:0] gal_rgb;
    wire [23:0] gal_rgb_full;
    wire fb_req_s2;
    // In CEA the full image includes coordinate zero. Qualify reset/startup
    // pipeline contents with the matching S2 DE, not just coordinate bounds.
    assign fb_pixel_req = fb_req_s2 && ((VIDEO_MODE!=1) || de2);

    gal_layer #(.PIPELINE(1), .VIDEO_MODE(VIDEO_MODE)) u_gal (
        .clk      (clk),
        .rst_n    (rst_n),
        .gal_on   (gal_on),
        .gal_img  (gal_img),
        .gal_fade (gal_fade),
        .media_mode(media_mode), .media_auto(media_auto),
        .media_settings(media_settings), .media_loading(media_loading),
        .media_osd(media_osd), .media_index(media_index), .media_count(media_count),
        .media_name(media_name), .media_brightness(media_brightness),
        .media_contrast(media_contrast), .media_view(media_view), .media_visual(media_visual),
        .x2       (xd2),
        .y2       (yd2),
        .x3       (xd3),
        .y3       (yd3),
        .tf_valid (tf_valid),
        .tf_err   (tf_err),
        .diag     (diag),
        .diag2    (diag2),
        .dfill    (dfill),
        .tf_rdata (tf_rdata),
        .tf_raddr (tf_raddr),
        .gal_rgb  (gal_rgb), .gal_rgb_full(gal_rgb_full),
        .fb_front_valid(fb_front_valid), .fb_pixel_valid(fb_pixel_valid),
        .fb_pixel_rgb(fb_pixel_rgb), .fb_pixel_req(fb_req_s2)
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
    wire [15:0] pix_base = (mon_on && mon_valid && cell_blank) ? mon_rgb :
                           (win3 && cell_blank)                ? anim_rgb_r : char_pix;

    // Gallery OSD has two registered stages. Carry every other layer and the
    // raster timing through the same two clocks before the final bar mixer.
    reg [15:0] base4, base5;
    reg [11:0] xd4, xd5, yd4, yd5;
    reg hs4, hs5, vs4, vs5, de4, de5;
    reg gal4, gal5, visual4, visual5, loading4, loading5, osd4, osd5;
    reg front4, front5;
    reg [63:0] bars4, bars5;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            base4<=0; base5<=0; xd4<=0; xd5<=0; yd4<=0; yd5<=0;
            hs4<=0; hs5<=0; vs4<=0; vs5<=0; de4<=0; de5<=0;
            gal4<=0; gal5<=0; visual4<=0; visual5<=0;
            loading4<=0; loading5<=0; osd4<=0; osd5<=0;
            bars4<=0; bars5<=0; front4<=0; front5<=0;
        end else begin
            base4<=pix_base; base5<=base4;
            xd4<=xd3; xd5<=xd4; yd4<=yd3; yd5<=yd4;
            hs4<=hs3; hs5<=hs4; vs4<=vs3; vs5<=vs4; de4<=de3; de5<=de4;
            gal4<=gal_on; gal5<=gal4;
            front4<=(fb_front_valid===1'b1); front5<=front4;
            visual4<=(media_visual===1'b0) ? 1'b0 : 1'b1; visual5<=visual4;
            loading4<=(media_loading===1'b1); loading5<=loading4;
            osd4<=(media_osd===1'b1); osd5<=osd4;
            bars4<=bars; bars5<=bars4;
        end
    end
    wire [15:0] pix_gal = gal5 ? gal_rgb : base5;
    function [23:0] expand565;
        input [15:0] c;
        begin expand565={c[15:11],c[15:13],c[10:5],c[10:9],c[4:0],c[4:2]}; end
    endfunction
    wire [23:0] pix_gal_full = gal5 ? gal_rgb_full : expand565(base5);

    //---------------------------------------------------------
    // 音频频谱彩条层（最上层，屏幕底部）
    //   8 根柱, 每根占 100 像素, 柱体 60 宽, 间隔 40 (留白比柱体还大)
    //   柱高 0..90, 从屏幕底边往上长, 占 y = 510..599 (90 行)
    //   ★ 半透明: 柱色与背后的游戏画面按 1:1 混合, 底下的字/立绘仍看得见
    //   ★ 柱间空隙与柱底空槽都不画, 直接透出原画面
    //---------------------------------------------------------
    localparam [11:0] VIDEO_H = (VIDEO_MODE==1) ? 12'd480 : 12'd600;
    localparam [11:0] BAR_W = (VIDEO_MODE==1) ? 12'd80 : 12'd100;
    wire in_bar_area = (yd5 >= VIDEO_H-12'd90) && (yd5 < VIDEO_H);

    wire [2:0] bi = (xd5 < BAR_W)   ? 3'd0 :
                    (xd5 < BAR_W*2) ? 3'd1 :
                    (xd5 < BAR_W*3) ? 3'd2 :
                    (xd5 < BAR_W*4) ? 3'd3 :
                    (xd5 < BAR_W*5) ? 3'd4 :
                    (xd5 < BAR_W*6) ? 3'd5 :
                    (xd5 < BAR_W*7) ? 3'd6 : 3'd7;

    // bi * 100 = bi*64 + bi*32 + bi*4
    wire [11:0] bmul = (VIDEO_MODE==1) ?
                       ({3'd0,bi,6'd0}+{5'd0,bi,4'd0}) :
                       ({3'd0,bi,6'd0}+{4'd0,bi,5'd0}+{7'd0,bi,2'd0});
    wire [11:0] bx   = xd5 - bmul;              // 柱内坐标 0..99

    reg [7:0] bh;
    always @(*) begin
        case (bi)
            3'd0:    bh = bars5[7:0];
            3'd1:    bh = bars5[15:8];
            3'd2:    bh = bars5[23:16];
            3'd3:    bh = bars5[31:24];
            3'd4:    bh = bars5[39:32];
            3'd5:    bh = bars5[47:40];
            3'd6:    bh = bars5[55:48];
            default: bh = bars5[63:56];
        endcase
    end

    reg [15:0] bcol;
    always @(*) begin
        case (bi)
            3'd0:    bcol = 16'hF800;           // 红
            3'd1:    bcol = 16'hFC00;           // 橙
            3'd2:    bcol = 16'hFE60;           // 橙黄
            3'd3:    bcol = 16'hFFE0;           // 黄
            3'd4:    bcol = 16'h87E0;           // 黄绿
            3'd5:    bcol = 16'h07E0;           // 绿
            3'd6:    bcol = 16'h07FF;           // 青
            default: bcol = 16'h781F;           // 紫
        endcase
    end

    // 柱高缩放: 原始 0..120 -> 0..90 (0.75x, 用移位加法)
    wire [7:0]  bh2  = (bh >> 1) + (bh >> 2);
    wire [11:0] by0  = VIDEO_H - {4'd0, bh2};   // 柱顶 y
    wire        bwin = in_bar_area && (bx >= ((VIDEO_MODE==1) ? 12'd16 : 12'd20)) &&
                       (bx < ((VIDEO_MODE==1) ? 12'd64 : 12'd80));
    wire        bhit = bwin && (yd5 >= by0);

    // 柱体: 顶部 3 行白色高亮(不透明), 每 8 行一条暗线 (像 LED 频谱条)
    wire [15:0] bdim = {1'b0, bcol[15:11], 1'b0, bcol[10:5], 1'b0, bcol[4:0]};
    wire        bhot = (yd5 < by0 + 12'd3);
    wire [15:0] bbody = (yd5[2:0] == 3'd0) ? bdim : bcol;

    // 与背景 1:1 混合: (前景 + 背景) / 2, RGB565 逐通道
    function [15:0] mix50;
        input [15:0] a;          // 前景(柱色)
        input [15:0] b;          // 背景(游戏画面)
        reg   [5:0]  fr;
        reg   [6:0]  fg;
        reg   [5:0]  fb;
        begin
            fr = {1'b0, a[15:11]} + {1'b0, b[15:11]};   // 5+5 -> 6 位
            fg = {1'b0, a[10:5]}  + {1'b0, b[10:5]};    // 6+6 -> 7 位
            fb = {1'b0, a[4:0]}   + {1'b0, b[4:0]};     // 5+5 -> 6 位
            mix50 = {fr[5:1], fg[6:1], fb[5:1]};
        end
    endfunction

    // note_bars represents pitch/envelope activity, not an FFT spectrum.
    // An open visual port preserves legacy bars; explicit zero disables them.
    wire visual_on = visual5;
    wire loading_on = loading5;
    wire hud_footer = gal5 && osd5 && (yd5 >= ((VIDEO_MODE==1) ? 12'd420 : 12'd560));
    wire bars_hidden = !bhit || !visual_on || (gal5 && loading_on && !front5) || hud_footer;
    wire [15:0] pix = bars_hidden ? pix_gal :
                      bhot   ? 16'hFFFF :
                               mix50(bbody, pix_gal);

    // Full-color music-bar blending never quantizes the framebuffer to RGB565.
    function [23:0] mix50_full;
        input [23:0] a,b;
        reg [8:0] r,g,bl;
        begin
            r={1'b0,a[23:16]}+{1'b0,b[23:16]};
            g={1'b0,a[15:8]}+{1'b0,b[15:8]};
            bl={1'b0,a[7:0]}+{1'b0,b[7:0]};
            mix50_full={r[8:1],g[8:1],bl[8:1]};
        end
    endfunction
    wire [23:0] pix_full = bars_hidden ? pix_gal_full :
                           bhot ? 24'hffffff : mix50_full(expand565(bbody),pix_gal_full);
    wire full_gallery = gal5 && front5;

    // Real-spectrum replacement is restricted to the OUTER character-cell strip.
    // Keep the original game/gallery, note bars and framebuffer pipeline intact.
    // vid_timing DE describes the previous counter. In MODE3 its source scaler
    // needs that same one-clock alignment; do not reuse the legacy raw xs/ys.
    reg [9:0] spectrum_src_x;
    reg [8:0] spectrum_src_y;
    reg [9:0] spectrum_x1, spectrum_x2, spectrum_x3, spectrum_x4;
    reg [8:0] spectrum_y1, spectrum_y2, spectrum_y3, spectrum_y4;
    reg spectrum_border_active;
    reg [63:0] spectrum_levels_frame;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            spectrum_src_x<=0; spectrum_src_y<=0;
            spectrum_x1<=0; spectrum_x2<=0; spectrum_x3<=0; spectrum_x4<=0;
            spectrum_y1<=0; spectrum_y2<=0; spectrum_y3<=0; spectrum_y4<=0;
            spectrum_border_active<=0; spectrum_levels_frame<=0;
        end else begin
            spectrum_src_x<=src_x_raw[9:0]; spectrum_src_y<=src_y_raw[8:0];
            spectrum_x1<=(VIDEO_MODE==1) ? timing_x[9:0] : spectrum_src_x;
            spectrum_y1<=(VIDEO_MODE==1) ? timing_y[8:0] : spectrum_src_y;
            spectrum_x2<=spectrum_x1; spectrum_y2<=spectrum_y1;
            spectrum_x3<=spectrum_x2; spectrum_y3<=spectrum_y2;
            spectrum_x4<=spectrum_x3; spectrum_y4<=spectrum_y3;
            // Both controls commit together, after the last active output pixel.
            if (frame_tick) begin
                spectrum_border_active <= (spectrum_border_en===1'b1);
                spectrum_levels_frame <= spectrum_levels;
            end
        end
    end

    // Filled 32-pixel rainbow tiles, with one-pixel transverse light seams.
    // FFT groups end on tile boundaries; opposite edges mirror inward.
    // Static diagonal hue, three small gain multipliers, no divider or BRAM.
    wire spectrum_horizontal = (spectrum_y4<9'd16) || (spectrum_y4>=9'd464);
    wire spectrum_outer4 = (spectrum_x4<10'd16) || (spectrum_x4>=10'd624) ||
                           spectrum_horizontal;
    wire spectrum_edge4 = (spectrum_x4==0) || (spectrum_x4==639) ||
                          (spectrum_y4==0) || (spectrum_y4==479);
    wire [2:0] spectrum_band_x = (spectrum_x4<10'd96) ? 3'd0 :
        (spectrum_x4<10'd160) ? 3'd1 : (spectrum_x4<10'd256) ? 3'd2 :
        (spectrum_x4<10'd320) ? 3'd3 : (spectrum_x4<10'd416) ? 3'd4 :
        (spectrum_x4<10'd480) ? 3'd5 : (spectrum_x4<10'd576) ? 3'd6 : 3'd7;
    wire [2:0] spectrum_band_y = (spectrum_y4<9'd64) ? 3'd0 :
        (spectrum_y4<9'd128) ? 3'd1 : (spectrum_y4<9'd192) ? 3'd2 :
        (spectrum_y4<9'd256) ? 3'd3 : (spectrum_y4<9'd320) ? 3'd4 :
        (spectrum_y4<9'd384) ? 3'd5 : (spectrum_y4<9'd448) ? 3'd6 : 3'd7;
    wire [2:0] spectrum_band = spectrum_horizontal ? spectrum_band_x : spectrum_band_y;
    reg [7:0] spectrum_level;
    always @(*) begin
        case (spectrum_band)
            0: spectrum_level=spectrum_levels_frame[7:0];
            1: spectrum_level=spectrum_levels_frame[15:8];
            2: spectrum_level=spectrum_levels_frame[23:16];
            3: spectrum_level=spectrum_levels_frame[31:24];
            4: spectrum_level=spectrum_levels_frame[39:32];
            5: spectrum_level=spectrum_levels_frame[47:40];
            6: spectrum_level=spectrum_levels_frame[55:48];
            default: spectrum_level=spectrum_levels_frame[63:56];
        endcase
    end
    wire [7:0] spectrum_clamped = (spectrum_level>120) ? 8'd120 : spectrum_level;
    // Music's usual 40..72 levels visibly modulate gain 36..52 / 64.
    // Silence remains filled at 1/4 gain; high energy saturates at 63 / 64.
    wire [6:0] spectrum_gain_raw = 7'd16 + {1'b0,spectrum_clamped[6:1]};
    wire [5:0] spectrum_gain = (spectrum_gain_raw>7'd63) ? 6'd63 : spectrum_gain_raw[5:0];
    wire [1:0] spectrum_glow_width = spectrum_clamped[6:5];
    wire [9:0] spectrum_depth = spectrum_horizontal ?
        ((spectrum_y4<16) ? {1'b0,spectrum_y4} : 10'd479-{1'b0,spectrum_y4}) :
        ((spectrum_x4<16) ? spectrum_x4 : 10'd639-spectrum_x4);
    wire spectrum_grid = spectrum_horizontal ? (spectrum_x4[4:0]==5'd0) :
                                               (spectrum_y4[4:0]==5'd0);
    wire spectrum_glow = (spectrum_depth>=10'd15-{8'd0,spectrum_glow_width}) &&
                         (spectrum_depth<10'd15);
    // The low eight bits implement ((x >> 1) + (y >> 1)) modulo 256.
    wire [7:0] spectrum_hue = spectrum_x4[8:1] + spectrum_y4[8:1];
    function [15:0] spectrum_tile_rgb;
        input [7:0] hue;
        input [5:0] gain;
        input glow;
        reg [10:0] phase;
        reg [7:0] ramp,fall,r,g,b;
        reg [13:0] product_r,product_g,product_b;
        reg [8:0] glow_r,glow_g,glow_b;
        begin
            // Six continuous RGB-wheel segments, computed with shifts/adds.
            phase={hue,2'b00}+{1'b0,hue,1'b0};
            ramp=phase[7:0];
            fall=8'd255-ramp;
            case (phase[10:8])
                3'd0: begin r=8'd255; g=ramp;   b=8'd0;   end
                3'd1: begin r=fall;   g=8'd255; b=8'd0;   end
                3'd2: begin r=8'd0;   g=8'd255; b=ramp;   end
                3'd3: begin r=8'd0;   g=fall;   b=8'd255; end
                3'd4: begin r=ramp;   g=8'd0;   b=8'd255; end
                default: begin r=8'd255; g=8'd0; b=fall; end
            endcase
            // Slightly soften saturation to match the luminous tiled frame.
            r=(r>>1)+(r>>2)+8'd7;
            g=(g>>1)+(g>>2)+8'd15;
            b=(b>>1)+(b>>2)+8'd7;
            // Exactly one gain per pixel and three 8x6-bit multiplications.
            product_r=r*gain; product_g=g*gain; product_b=b*gain;
            r=product_r[13:6]; g=product_g[13:6]; b=product_b[13:6];
            // FFT energy spreads a soft white glint inward from the pink rim.
            glow_r={1'b0,r}+9'd255;
            glow_g={1'b0,g}+9'd255;
            glow_b={1'b0,b}+9'd255;
            if (glow) begin
                r=glow_r[8:1]; g=glow_g[8:1]; b=glow_b[8:1];
            end
            spectrum_tile_rgb={r[7:3],g[7:2],b[7:3]};
        end
    endfunction
    wire [15:0] spectrum_body_rgb = spectrum_tile_rgb(spectrum_hue,spectrum_gain,spectrum_glow);
    // Priority: outside bevel, continuous inner rim, fine grid, filled tile.
    wire [15:0] spectrum_rgb4 = spectrum_edge4 ? 16'h1063 :
        (spectrum_depth==10'd15) ? 16'hfdd9 :
        spectrum_grid ? 16'hd71d : spectrum_body_rgb;
    reg spectrum_outer5;
    reg [15:0] spectrum_rgb5;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin spectrum_outer5<=0; spectrum_rgb5<=0; end
        else begin
            spectrum_outer5<=spectrum_outer4;
            // Preserve the existing S4 -> S5 color/coverage latency.
            spectrum_rgb5<=spectrum_rgb4;
        end
    end
    wire spectrum_replace = spectrum_border_active && !gal5 && spectrum_outer5;
    wire [15:0] spectrum_pix = spectrum_replace ? spectrum_rgb5 : pix;

    //---------------------------------------------------------
    // 诊断色条(仅 TEST_BARS=1 时): 8 条 100 像素宽, 绕过所有图层
    //   注意名字不能叫 bars —— 模块端口已经叫 bars(音频频谱柱高)
    //---------------------------------------------------------
    wire [15:0] tbars = (raster_x < BAR_W*1) ? 16'hFFFF :
                        (raster_x < BAR_W*2) ? 16'hFFE0 :
                        (raster_x < BAR_W*3) ? 16'h07FF :
                        (raster_x < BAR_W*4) ? 16'h07E0 :
                        (raster_x < BAR_W*5) ? 16'hF81F :
                        (raster_x < BAR_W*6) ? 16'hF800 :
                        (raster_x < BAR_W*7) ? 16'h001F : 16'h0000;

    // vid_timing.frame_start is active-frame start. Use delayed physical
    // coordinates here so the last active pixel has left the output pipeline.
    assign frame_tick = rst_n && (xd5 == 12'd0) && (yd5 == VIDEO_H);
    assign hs  = TEST_BARS ? hs_i : hs5;
    assign vs  = TEST_BARS ? vs_i : vs5;
    assign de  = TEST_BARS ? de_i : de5;
    assign rgb = TEST_BARS ? (de_i ? tbars : 16'h0000)
                           : !de5 ? 16'h0000 : full_gallery ?
                             {pix_full[23:19],pix_full[15:10],pix_full[7:3]} : spectrum_pix;
    assign rgb_full = TEST_BARS ? (de_i ? expand565(tbars) : 24'd0) :
                      !de5 ? 24'd0 : full_gallery ? pix_full : expand565(spectrum_pix);

endmodule

//=============================================================================
// photo_rom —— 已移除 (2026-10-30)
//   相册图片改由 TF 卡 BMP 提供 (赛题基础要求 01), 省下 21 块 BRAM
//   给 "游戏 + SD 读取" 并存使用。原 4 张内置海报的生成脚本
//   tools/make_photos.py 与 photo.hex 仍保留在仓库中作为演进说明。
//=============================================================================

//=============================================================================
// gal_layer —— 相册显示层 (图片轮播)
//
//   布局 (逻辑坐标 640x480, 输出端再被 1.25x 放大):
//     照片 256x192 两倍放大 = 512x384, 左上角 (64,44)
//     照片外 6 像素灰色画框
//     底部 4 个页码圆点 (当前张黄色), 右下角 3x5 字模的页号数字
//     其余像素黑底
//
//   流水线对齐: 地址用 x2/y2 (第 2 级) 发起, photo_rom 有 1 拍寄存,
//   数据返回时该像素恰好走到 x3/y3 (第 3 级), 与主流水线零错位。
//
//   淡入淡出: gal_fade 0..8, out = (c*f)>>3, 纯移位加法, 零乘法器。
//=============================================================================
module gal_layer #(parameter integer PIPELINE = 0, parameter integer VIDEO_MODE = 3) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        gal_on,
    input  wire [1:0]  gal_img,
    input  wire [3:0]  gal_fade,     // 0(黑)..8(全亮)
    input  wire [11:0] x2,           // 流水线第 2 级 x (发 ROM 地址)
    input  wire [11:0] y2,
    input  wire [11:0] x3,           // 第 3 级 x (输出对齐)
    input  wire [11:0] y3,
    // TF 卡图片: 相册全部页共用 (photo_rom 已移除, 相册图片由 TF 卡提供)
    input  wire        tf_valid,
    input  wire [1:0]  tf_err,       // 0无 1无卡 2无BMP 3格式不符 -> 诊断窗色
    input  wire [7:0]  diag,         // 里程碑: 0..4=SPI初始化步骤 5=找到BMP 6=图片写入
    input  wire [7:0]  diag2,        // 第二排: 轮询字节 (MSB 在左)
    input  wire        dfill,        // 第二排消隐
    input  wire [3:0]  tf_rdata,
    output wire [15:0] tf_raddr,     // 0..49151 = row*256 + col
    output wire [15:0] gal_rgb,
    input wire [1:0] media_mode,
    input wire media_auto, media_settings, media_loading, media_osd,
    input wire [5:0] media_index, media_count,
    input wire [63:0] media_name,
    input wire [3:0] media_brightness,
    input wire [1:0] media_contrast, media_view,
    input wire media_visual,
    input wire fb_front_valid, fb_pixel_valid,
    input wire [23:0] fb_pixel_rgb,
    output wire fb_pixel_req,
    output wire [23:0] gal_rgb_full
);
    localparam [11:0] GX0 = 12'd64, GY0 = 12'd44;   // 照片左上角 (逻辑坐标)

    //---------------------------------------------------------
    // S2: 发 tf_ram 读地址 (1 拍后数据到达, 对齐 S3)
    //     像素地址 = 源行*256 + 源列 = {py2, px2}, 16位, 0..49151
    //---------------------------------------------------------
    reg [1:0] view_sel, contrast_sel;
    reg [3:0] brightness_sel;
    always @(*) begin
        case (media_view)
            2'd1: view_sel = 2'd1;
            2'd2: view_sel = 2'd2;
            default: view_sel = 2'd0;
        endcase
        case (media_contrast)
            2'd0: contrast_sel = 2'd0;
            2'd2: contrast_sel = 2'd2;
            default: contrast_sel = 2'd1;
        endcase
        case (media_brightness)
            4'd0,4'd1,4'd2,4'd3,4'd4,4'd5,4'd6,4'd7,4'd8:
                brightness_sel = media_brightness;
            default: brightness_sel = 4'd4;
        endcase
    end
    wire front_valid = (fb_front_valid === 1'b1);
    wire full_pixel_valid = (fb_pixel_valid === 1'b1);
    localparam [11:0] FULL_X = (VIDEO_MODE==1) ? 12'd0 : 12'd80;
    localparam [11:0] FULL_Y = (VIDEO_MODE==1) ? 12'd0 : 12'd60;
    localparam [11:0] FRAME_H = (VIDEO_MODE==1) ? 12'd480 : 12'd600;
    localparam [11:0] HUD_RIGHT = (VIDEO_MODE==1) ? 12'd624 : 12'd784;
    localparam [11:0] FOOTER_Y = (VIDEO_MODE==1) ? 12'd420 : 12'd452;
    localparam [11:0] PARAM_Y = (VIDEO_MODE==1) ? 12'd440 : 12'd474;
    localparam [11:0] SETTINGS_Y = (VIDEO_MODE==1) ? 12'd460 : 12'd496;
    localparam [11:0] MARQUEE_Y = (VIDEO_MODE==1) ? 12'd44 : 12'd570;
    wire full_in2 = x2>=FULL_X && x2<FULL_X+12'd640 && y2>=FULL_Y && y2<FULL_Y+12'd480;
    wire full_in3 = x3>=FULL_X && x3<FULL_X+12'd640 && y3>=FULL_Y && y3<FULL_Y+12'd480;
    // No reads during blank or outside the native 640x480 image. View settings
    // never change this sequential consumption order. Loading writes the back.
    assign fb_pixel_req = rst_n && gal_on && front_valid && full_in2;
    wire loading = (media_loading === 1'b1);
    wire osd_on = (media_osd === 1'b1) || (media_settings === 1'b1);
    wire settings_on = (media_settings === 1'b1);
    wire [11:0] pic_x = (view_sel == 1) ? 12'd192 : GX0;
    wire [11:0] pic_y = (view_sel == 1) ? 12'd140 : GY0;
    wire [11:0] pic_w = (view_sel == 1) ? 12'd256 : 12'd512;
    wire [11:0] pic_h = (view_sel == 1) ? 12'd192 : 12'd384;
    wire in2 = (x2 >= pic_x) && (x2 < pic_x + pic_w) &&
               (y2 >= pic_y) && (y2 < pic_y + pic_h);
    wire [11:0] ax2 = x2 - pic_x;
    wire [11:0] ay2 = y2 - pic_y;
    wire [7:0] px2 = (view_sel == 1) ? ax2[7:0] :
                         (view_sel == 2) ? (8'd64 + {1'b0,ax2[8:2]}) : ax2[8:1];
    wire [7:0] py2 = (view_sel == 1) ? ay2[7:0] :
                         (view_sel == 2) ? (8'd48 + {1'b0,ay2[8:2]}) : ay2[8:1];
    // Loading masks the display immediately and parks the RAM read address.
    assign tf_raddr = (gal_on && !front_valid && in2 && !loading) ? {py2, px2} : 16'd0;

    //---------------------------------------------------------
    // S3: 调色板 + 淡入淡出
    //     photo_rom 已移除: tf_valid=1 显示 TF 卡图片, 否则诊断画面
    //---------------------------------------------------------
    wire [3:0] pnib = tf_rdata;

    function [15:0] ppal;                     // 与 anim_rom.pal_tbl 相同
        input [3:0] c;
        begin
            case (c)
                4'd0:  ppal = 16'h0000;
                4'd1:  ppal = 16'h0841;
                4'd2:  ppal = 16'h10A2;
                4'd3:  ppal = 16'h18E3;
                4'd4:  ppal = 16'h3186;
                4'd5:  ppal = 16'h4208;
                4'd6:  ppal = 16'h8000;
                4'd7:  ppal = 16'hC000;
                4'd8:  ppal = 16'hE800;
                4'd9:  ppal = 16'hFD20;
                4'd10: ppal = 16'hFE60;
                4'd11: ppal = 16'hFFE0;
                4'd12: ppal = 16'hFFFF;
                4'd13: ppal = 16'h7BEF;
                4'd14: ppal = 16'h39E7;
                default: ppal = 16'h0220;
            endcase
        end
    endfunction

    // Contrast about channel midpoint, then brightness offset. Signed nine-bit
    // add/shift arithmetic covers the complete range without multipliers.
    function [5:0] adjust_channel;
        input [5:0] c;
        input green;
        input [3:0] bright;
        input [1:0] contrast;
        reg signed [8:0] value, midpoint, offset, maximum;
        begin
            midpoint = green ? 9'sd32 : 9'sd16;
            maximum = green ? 9'sd63 : 9'sd31;
            value = $signed({3'b000,c}) - midpoint;
            case (contrast)
                2'd0: value = value >>> 1;
                2'd2: value = value + (value >>> 1);
                default: value = value;
            endcase
            offset = $signed({5'd0,bright}) - 9'sd4;
            offset = green ? (offset <<< 3) : (offset <<< 2);
            value = value + midpoint + offset;
            if (value < 0) adjust_channel = 6'd0;
            else if (value > maximum) adjust_channel = maximum[5:0];
            else adjust_channel = value[5:0];
        end
    endfunction
    wire [15:0] palette_rgb = ppal(pnib);
    wire [5:0] ar = adjust_channel({1'b0,palette_rgb[15:11]},1'b0,brightness_sel,contrast_sel);
    wire [5:0] ag = adjust_channel(palette_rgb[10:5],1'b1,brightness_sel,contrast_sel);
    wire [5:0] ab = adjust_channel({1'b0,palette_rgb[4:0]},1'b0,brightness_sel,contrast_sel);
    wire [15:0] pcol = {ar[4:0],ag,ab[4:0]};

    function [23:0] expand565;
        input [15:0] c;
        begin expand565={c[15:11],c[15:13],c[10:5],c[10:9],c[4:0],c[4:2]}; end
    endfunction
    // RGB888 source retains all eight channel bits. Contrast about 128, then
    // brightness +/-32 per step and saturation. All operations are add/shift.
    function [7:0] adjust8;
        input [7:0] c;
        input [3:0] bright;
        input [1:0] contrast;
        reg signed [10:0] v, offset;
        begin
            v=$signed({3'd0,c})-11'sd128;
            case(contrast)
                2'd0: v=v>>>1;
                2'd2: v=v+(v>>>1);
                default: v=v;
            endcase
            offset=($signed({7'd0,bright})-11'sd4)<<<5;
            v=v+11'sd128+offset;
            if(v<0) adjust8=8'd0;
            else if(v>255) adjust8=8'd255;
            else adjust8=v[7:0];
        end
    endfunction
    function [7:0] fade8;
        input [7:0] c;
        input [3:0] f;
        begin
            case(f)
                0:fade8=0;
                1:fade8=c>>3;
                2:fade8=c>>2;
                3:fade8=(c>>2)+(c>>3);
                4:fade8=c>>1;
                5:fade8=(c>>1)+(c>>3);
                6:fade8=(c>>1)+(c>>2);
                7:fade8=(c>>1)+(c>>2)+(c>>3);
                default:fade8=c;
            endcase
        end
    endfunction
    wire [23:0] full_adjusted={
        fade8(adjust8(fb_pixel_rgb[23:16],brightness_sel,contrast_sel),gal_fade),
        fade8(adjust8(fb_pixel_rgb[15:8],brightness_sel,contrast_sel),gal_fade),
        fade8(adjust8(fb_pixel_rgb[7:0],brightness_sel,contrast_sel),gal_fade)};

    // (c*f)>>3, f=0..8, 全移位加
    function [5:0] fmul;
        input [5:0] c;
        input [3:0] f;
        begin
            case (f)
                4'd0:    fmul = 6'd0;
                4'd1:    fmul = {3'b000, c[5:3]};
                4'd2:    fmul = {2'b00, c[5:2]};
                4'd3:    fmul = {2'b00, c[5:2]} + {3'b000, c[5:3]};
                4'd4:    fmul = {1'b0, c[5:1]};
                4'd5:    fmul = {1'b0, c[5:1]} + {3'b000, c[5:3]};
                4'd6:    fmul = {1'b0, c[5:1]} + {2'b00, c[5:2]};
                4'd7:    fmul = {1'b0, c[5:1]} + {2'b00, c[5:2]} + {3'b000, c[5:3]};
                default: fmul = c;
            endcase
        end
    endfunction

    wire [5:0] fcr = fmul({1'b0, pcol[15:11]}, gal_fade);
    wire [5:0] fcg = fmul(pcol[10:5], gal_fade);
    wire [5:0] fcb = fmul({1'b0, pcol[4:0]}, gal_fade);
    wire [15:0] pfade = {fcr[4:0], fcg[5:0], fcb[4:0]};

    //---------------------------------------------------------
    // 画框 / 页码圆点 / 页号数字 (都用第 3 级坐标, 组合逻辑)
    //---------------------------------------------------------
    wire in_p3 = (x3 >= pic_x) && (x3 < pic_x + pic_w) &&
                 (y3 >= pic_y) && (y3 < pic_y + pic_h);
    wire in_frm = (x3 >= pic_x - 12'd6) && (x3 < pic_x + pic_w + 12'd6) &&
                  (y3 >= pic_y - 12'd6) && (y3 < pic_y + pic_h + 12'd6);
    wire ring   = in_frm && !in_p3;

    // 圆点: x 从 286 起 4 个, 间距 20, 宽 8; y 434..441
    wire [11:0] dxo  = x3 - 12'd286;
    wire [1:0]  di   = (dxo < 12'd20) ? 2'd0 :
                       (dxo < 12'd40) ? 2'd1 :
                       (dxo < 12'd60) ? 2'd2 : 2'd3;
    wire [11:0] dmul = {6'd0, di, 4'b0000} + {8'd0, di, 2'b00};   // di*20
    wire [11:0] din  = dxo - dmul;
    wire in_dot = (dxo < 12'd68) && (y3 >= 12'd434) && (y3 < 12'd442) &&
                  (din < 12'd8);

    // 页号数字: 3x5 字模 3 倍放大, 右下角 (596,434)..(604,448)
    function [14:0] dgt;                      // 每行 3 位, 共 5 行
        input [3:0] n;
        begin
            case (n)
                4'd1:    dgt = 15'b010_110_010_010_111;
                4'd2:    dgt = 15'b111_001_111_100_111;
                4'd3:    dgt = 15'b111_001_011_001_111;
                4'd4:    dgt = 15'b101_101_111_001_001;
                default: dgt = 15'b000_000_000_000_000;
            endcase
        end
    endfunction

    wire [3:0]  dnum   = gal_img + 4'd1;      // 显示 1..4
    wire [14:0] dbits  = dgt(dnum);
    wire [11:0] ddx    = x3 - 12'd596;
    wire [11:0] ddy    = y3 - 12'd434;
    wire [2:0]  drow   = (ddy < 12'd3)  ? 3'd0 :
                         (ddy < 12'd6)  ? 3'd1 :
                         (ddy < 12'd9)  ? 3'd2 :
                         (ddy < 12'd12) ? 3'd3 : 3'd4;
    wire [2:0]  dcolx  = (ddx < 12'd3) ? 3'd0 :
                         (ddx < 12'd6) ? 3'd1 : 3'd2;
    wire        dbit   = dbits[14 - drow*3 - dcolx];
    wire in_dig  = (x3 >= 12'd596) && (x3 < 12'd605) &&
                   (y3 >= 12'd434) && (y3 < 12'd449) && dbit;

    //---------------------------------------------------------
    // 合成: 照片(带淡入淡出) > 画框 > 圆点 > 数字 > 黑底
    //   tf_valid=0 (没读到卡): 青色底 + 错误码着色的图片窗 —— 醒目诊断画面,
    //     红窗   = 无卡/初始化失败 (SPI 层, 查卡是否插好/兼容)
    //     黄窗   = 初始化成功但目录里没有 BMP (查文件名/是否在根目录)
    //     品红窗 = 找到 BMP 但格式不符 (查是否 24bit/是否 exFAT 卡)
    //   与"显示器无信号"和"读到图"都能一眼区分。
    //---------------------------------------------------------
    wire [15:0] errcol = (tf_err == 2'd3) ? 16'hF81F :   // 品红
                         (tf_err == 2'd2) ? 16'hFFE0 :   // 黄
                         16'hF800;                       // 红 (0/1)

    //---------------------------------------------------------
    // 诊断: 窗中央两排方块, 每排 8 个
    //   布局: 起点 ax3=128, 周期32px (16px方块+16px间隙), 共256px
    //         bx3=ax3-128; bx3[4:0]<16 命中, bx3[7:5] 为序号0..7
    //   第一排 (y 172..188): diag[0..7] 里程碑
    //     0:CMD0应答 1:CMD8应答 2:ACMD41就绪 3:CMD58(OCR) 4:CMD16/SDHC
    //     5:目录找到BMP 6:图片已写入  7:恒暗
    //   第二排 (y 200..216): 轮询字节 diag2 (MSB 在左)
    //---------------------------------------------------------
    wire [11:0] ax3 = x3 - GX0;
    wire [11:0] ay3 = y3 - GY0;

    wire [11:0] bx3 = ax3 - 12'd128;
    // 32px 周期, 每块16px, 八块共256px; 索引从窗口内128处重新计数。
    wire        in_x  = (ax3 >= 12'd128) && (ax3 < 12'd384);
    wire        in_blk= (bx3[4:0] < 5'd16);
    wire [2:0]  bidx  = bx3[7:5];

    wire        sq_on  = (ay3 >= 12'd172) && (ay3 < 12'd188) && in_x && in_blk;
    wire        sq2_on = (ay3 >= 12'd200) && (ay3 < 12'd216) && in_x && in_blk;

    wire [2:0]  sqi   = bidx;
    wire [2:0]  sqi2  = 3'd7 - bidx;                           // MSB 在左

    // 方块底色: 暗灰; 未到/未置 1 = 暗灰, 置 1 = 亮
    wire [15:0] blk1 = diag[sqi]   ? 16'hFFFF : 16'h2108;
    wire [15:0] blk2 = diag2[sqi2] ? 16'h07FF : 16'h2108;

    // Compact 5x7 ASCII, doubled to 10x14 pixels in a 12x16 cell.
    // Combinational case logic deliberately avoids a font ROM/BRAM.
    function [34:0] ascii5x7;
        input [7:0] ch;
        reg [7:0] c;
        begin
            c = ((ch >= "a") && (ch <= "z")) ? ch - 8'd32 : ch;
            case (c)
                "A": ascii5x7=35'b01110_10001_10001_11111_10001_10001_10001;
                "B": ascii5x7=35'b11110_10001_10001_11110_10001_10001_11110;
                "C": ascii5x7=35'b01111_10000_10000_10000_10000_10000_01111;
                "D": ascii5x7=35'b11110_10001_10001_10001_10001_10001_11110;
                "E": ascii5x7=35'b11111_10000_10000_11110_10000_10000_11111;
                "F": ascii5x7=35'b11111_10000_10000_11110_10000_10000_10000;
                "G": ascii5x7=35'b01111_10000_10000_10111_10001_10001_01111;
                "H": ascii5x7=35'b10001_10001_10001_11111_10001_10001_10001;
                "I": ascii5x7=35'b11111_00100_00100_00100_00100_00100_11111;
                "J": ascii5x7=35'b00111_00010_00010_00010_10010_10010_01100;
                "K": ascii5x7=35'b10001_10010_10100_11000_10100_10010_10001;
                "L": ascii5x7=35'b10000_10000_10000_10000_10000_10000_11111;
                "M": ascii5x7=35'b10001_11011_10101_10101_10001_10001_10001;
                "N": ascii5x7=35'b10001_11001_10101_10011_10001_10001_10001;
                "O": ascii5x7=35'b01110_10001_10001_10001_10001_10001_01110;
                "P": ascii5x7=35'b11110_10001_10001_11110_10000_10000_10000;
                "Q": ascii5x7=35'b01110_10001_10001_10001_10101_10010_01101;
                "R": ascii5x7=35'b11110_10001_10001_11110_10100_10010_10001;
                "S": ascii5x7=35'b01111_10000_10000_01110_00001_00001_11110;
                "T": ascii5x7=35'b11111_00100_00100_00100_00100_00100_00100;
                "U": ascii5x7=35'b10001_10001_10001_10001_10001_10001_01110;
                "V": ascii5x7=35'b10001_10001_10001_10001_10001_01010_00100;
                "W": ascii5x7=35'b10001_10001_10001_10101_10101_11011_10001;
                "X": ascii5x7=35'b10001_10001_01010_00100_01010_10001_10001;
                "Y": ascii5x7=35'b10001_10001_01010_00100_00100_00100_00100;
                "Z": ascii5x7=35'b11111_00001_00010_00100_01000_10000_11111;
                "0": ascii5x7=35'b01110_10001_10011_10101_11001_10001_01110;
                "1": ascii5x7=35'b00100_01100_00100_00100_00100_00100_01110;
                "2": ascii5x7=35'b01110_10001_00001_00010_00100_01000_11111;
                "3": ascii5x7=35'b11110_00001_00001_01110_00001_00001_11110;
                "4": ascii5x7=35'b00010_00110_01010_10010_11111_00010_00010;
                "5": ascii5x7=35'b11111_10000_10000_11110_00001_00001_11110;
                "6": ascii5x7=35'b01110_10000_10000_11110_10001_10001_01110;
                "7": ascii5x7=35'b11111_00001_00010_00100_01000_01000_01000;
                "8": ascii5x7=35'b01110_10001_10001_01110_10001_10001_01110;
                "9": ascii5x7=35'b01110_10001_10001_01111_00001_00001_01110;
                "/": ascii5x7=35'b00001_00010_00010_00100_01000_01000_10000;
                "-": ascii5x7=35'b00000_00000_00000_11111_00000_00000_00000;
                ":": ascii5x7=35'b00000_00100_00100_00000_00100_00100_00000;
                ".": ascii5x7=35'b00000_00000_00000_00000_00000_00110_00110;
                "=": ascii5x7=35'b00000_00000_11111_00000_11111_00000_00000;
                "_": ascii5x7=35'b00000_00000_00000_00000_00000_00000_11111;
                default: ascii5x7=35'd0;
            endcase
        end
    endfunction
    function [7:0] hex_ascii;
        input [3:0] n;
        begin hex_ascii = (n < 10) ? 8'd48 + n : 8'd65 + (n-4'd10); end
    endfunction
    reg [1:0] mode_sel;
    reg [5:0] index_sel, count_sel;
    always @(*) begin
        case(media_mode)
            2'd1: mode_sel=1; 2'd2: mode_sel=2; default: mode_sel=0;
        endcase
        case (^media_index)
            1'b0,1'b1: index_sel=media_index;
            default: index_sel={4'd0,gal_img};
        endcase
        case (^media_count)
            1'b0,1'b1: count_sel=media_count;
            default: count_sel=6'd4;
        endcase
    end
    wire [6:0] frame_number = {1'b0,index_sel} + 7'd1;
    reg [8:0] scroll;
    reg [1:0] scroll_div;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin scroll<=0; scroll_div<=0; end
        else if ((x3==0) && (y3==FRAME_H)) begin
            scroll_div <= scroll_div+1'b1;
            if (scroll_div==3) scroll <= (scroll==383) ? 9'd0 : scroll+1'b1;
        end
    end

    reg [2:0] text_row;
    reg [11:0] text_y;
    reg text_area;
    always @(*) begin
        text_row=0; text_y=0; text_area=0;
        if (y3>=8 && y3<24) begin text_row=0; text_y=y3-12'd8; text_area=1; end
        else if (y3>=26 && y3<42) begin text_row=1; text_y=y3-12'd26; text_area=1; end
        else if (y3>=FOOTER_Y && y3<FOOTER_Y+12'd16) begin text_row=2; text_y=y3-FOOTER_Y; text_area=1; end
        else if (y3>=PARAM_Y && y3<PARAM_Y+12'd16) begin text_row=3; text_y=y3-PARAM_Y; text_area=1; end
        else if (y3>=SETTINGS_Y && y3<SETTINGS_Y+12'd16) begin text_row=4; text_y=y3-SETTINGS_Y; text_area=1; end
        else if (y3>=MARQUEE_Y && y3<MARQUEE_Y+12'd16) begin text_row=5; text_y=y3-MARQUEE_Y; text_area=1; end
    end
    wire [11:0] text_x = x3-12'd16;
    wire [11:0] marquee_sum = text_x + {3'd0,scroll};
    wire [11:0] marquee_x = (marquee_sum>=768) ? marquee_sum-12'd768 :
                                           (marquee_sum>=384) ? marquee_sum-12'd384 : marquee_sum;
    wire [11:0] cell_x = (text_row==5) ? marquee_x : text_x;
    wire [6:0] text_column = cell_x / 12;
    wire [3:0] glyph_x = (cell_x % 12) >> 1;
    wire [2:0] glyph_y = text_y[3:1];
    reg [511:0] text_line;
    reg [6:0] text_length;
    reg [7:0] text_char;
    always @(*) begin
        text_line=0; text_length=0;
        case (text_row)
            0: begin
                text_line = {(mode_sel==1 ? "GALLERY " : mode_sel==2 ? "GAME    " : "SEQUENCE"),
                    "  ", ((media_auto===1'b1) ? "AUTO  " : "PAUSED"),
                    "  FRAME HEX ",hex_ascii({1'b0,frame_number[6:4]}),hex_ascii(frame_number[3:0]),
                    "/",hex_ascii({2'b0,count_sel[5:4]}),hex_ascii(count_sel[3:0])};
                text_length=33;
            end
            1: begin
                text_line={"FILE ",media_name,".BMP  STATUS ",
                     (loading ? "LOADING" : (tf_err!=0) ? "ERROR  " : (front_valid || tf_valid) ? "READY  " : "WAIT   ")};
                text_length=33;
            end
            2: begin text_line="K1 PREV  K2 NEXT  K3 AUTO/PAUSE  K4 MODE"; text_length=40; end
            3: begin
                if (front_valid) begin
                    text_line={"BRIGHT ",hex_ascii(brightness_sel),"/8  CONTRAST ",
                        (contrast_sel==0 ? "LOW   " : contrast_sel==2 ? "HIGH  " : "NORMAL"),
                        "  VIEW ",(view_sel==1 ? "2XCENTER" : view_sel==2 ? "4XCENTER" : "FULL640 "),
                        " BARS ",((media_visual===1'b0) ? "OFF" : "ON ")};
                    text_length=51;
                end else begin
                    text_line={"BRIGHT ",hex_ascii(brightness_sel),"/8  CONTRAST ",
                        (contrast_sel==0 ? "LOW   " : contrast_sel==2 ? "HIGH  " : "NORMAL"),
                        "  VIEW ",(view_sel==1 ? "NATIVE" : view_sel==2 ? "ZOOM  " : "NORMAL"),
                        "  BARS ",((media_visual===1'b0) ? "OFF" : "ON ")};
                    text_length=50;
                end
            end
            4: begin
                if (settings_on) begin
                    text_line=front_valid ? "SETTINGS: K1 BRIGHT K2 CONTRAST K3 ZOOM K4 EXIT" :
                               "SETTINGS: K1 BRIGHT K2 CONTRAST K3 VIEW K4 EXIT"; text_length=47;
                end else begin
                    text_line="HOLD K1 HUD K2 BARS K3 MUTE K4 SETTINGS"; text_length=39;
                end
            end
            5: begin text_line="FPGA MULTIMEDIA - TF BMP PLAYER "; text_length=32; end
            default: begin text_line=0; text_length=0; end
        endcase
        text_char=8'h20;
        if (text_column<text_length)
            text_char = text_line[((text_length-text_column)*8)-1 -: 8];
    end
    wire [34:0] glyph_bits = ascii5x7(text_char);
    wire text_pixel = text_area && x3>=16 && x3<HUD_RIGHT && glyph_x<5 && glyph_y<7 &&
                      glyph_bits[34-glyph_y*5-glyph_x];
    wire [15:0] text_color = (text_row==0) ? 16'hFFE0 :
                             ((text_row==1) && (loading || tf_err!=0)) ? 16'hFD20 :
                             (text_row==3 || text_row==4 || text_row==5) ? 16'h07FF : 16'hFFFF;
    // Preserve all eight diagnostic bits and legacy unconnected behavior.
    // A reported error takes precedence over stale valid RAM contents.
    wire show_error = !loading && ((!tf_valid) || (tf_err!=0));
    wire [15:0] image_rgb = loading ? 16'h0000 :
                     in_p3 ? (show_error ? (sq_on ? blk1 :
                                (sq2_on && !dfill) ? blk2 : errcol) : pfade) :
                     show_error ? 16'h07FF :
                     ring ? 16'h39E7 :
                     (!osd_on && in_dot) ? ((di==gal_img) ? 16'hFFE0 : 16'h39E7) :
                     (!osd_on && in_dig) ? 16'hFFFF : 16'h0000;
    wire full_ring = (VIDEO_MODE!=1) && x3>=12'd74 && x3<12'd726 && y3>=12'd54 && y3<12'd546 && !full_in3;
    // A committed front image remains visible through back-buffer loading and
    // errors. Invalid returned pixels are black, never stale FIFO contents.
    wire [23:0] image_full = front_valid ?
             (full_in3 ? (full_pixel_valid ? full_adjusted : 24'd0) :
              full_ring ? expand565(16'h39e7) : 24'd0) : expand565(image_rgb);
    wire [23:0] rgb_full_comb = !gal_on ? 24'd0 :
                              (osd_on && text_pixel) ? expand565(text_color) : image_full;
    wire [15:0] full565_comb={rgb_full_comb[23:19],rgb_full_comb[15:10],rgb_full_comb[7:3]};
    wire [15:0] rgb_comb = front_valid ? full565_comb : !gal_on ? 16'h0000 :
                           (osd_on && text_pixel) ? text_color : image_rgb;
    generate if (PIPELINE != 0) begin : g_osd_pipeline
        // P1 ends coordinate division, text selection and picture adjustment.
        // P2 isolates font decoding/compositing from the downstream bar/TMDS path.
        reg [7:0] char_p1;
        reg [3:0] gx_p1;
        reg [2:0] gy_p1;
        reg area_p1, osd_p1, gal_p1;
        reg [15:0] color_p1, image_p1, rgb_p2;
        reg front_p1, front_p2;
        reg [23:0] image_full_p1, rgb_full_p2;
        wire [34:0] bits_p1 = ascii5x7(char_p1);
        wire pixel_p1 = area_p1 && gx_p1<5 && gy_p1<7 &&
                        bits_p1[34-gy_p1*5-gx_p1];
        always @(posedge clk or negedge rst_n) begin
            if (!rst_n) begin
                char_p1<=8'h20; gx_p1<=0; gy_p1<=0;
                area_p1<=0; osd_p1<=0; gal_p1<=0;
                color_p1<=0; image_p1<=0; rgb_p2<=0;
                front_p1<=0; front_p2<=0; image_full_p1<=0; rgb_full_p2<=0;
            end else begin
                char_p1<=text_char; gx_p1<=glyph_x; gy_p1<=glyph_y;
                area_p1<=text_area && x3>=16 && x3<HUD_RIGHT;
                osd_p1<=osd_on; gal_p1<=gal_on;
                color_p1<=text_color; image_p1<=image_rgb;
                front_p1<=front_valid; front_p2<=front_p1; image_full_p1<=image_full;
                rgb_full_p2<=!gal_p1 ? 24'd0 :
                        (osd_p1 && pixel_p1) ? expand565(color_p1) : image_full_p1;
                rgb_p2<=!gal_p1 ? 16'h0000 :
                        (osd_p1 && pixel_p1) ? color_p1 : image_p1;
            end
        end
        assign gal_rgb = front_p2 ? {rgb_full_p2[23:19],rgb_full_p2[15:10],rgb_full_p2[7:3]} : rgb_p2;
        assign gal_rgb_full = rgb_full_p2;
    end else begin : g_osd_combinational
        assign gal_rgb = rgb_comb;
        assign gal_rgb_full = rgb_full_comb;
    end endgenerate

endmodule

//=============================================================================
// tf_ram —— TF 卡 BMP 缩略图 (256x192, 4bpp = 24576 字节)
//
//   写侧在 50MHz 时钟域 (sd_img 解码填充), 读侧在 40MHz 视频时钟域。
//   双时钟简单双口 RAM; 视频只在 tf_valid=1 后读取, 此时写入早已结束。
//=============================================================================
module tf_ram (
    input  wire        wclk,         // 50MHz (sd 域)
    input  wire [15:0] waddr,        // 0..49151 = row*256 + col (16位)
    input  wire        wren,
    input  wire [3:0]  wdata,
    input  wire        rclk,         // 40MHz (视频域)
    input  wire [15:0] raddr,        // 16位!
    output wire [3:0]  rdata
);
    // TD rounds a single 49152-deep array up to65536, wasting one quarter.
    // Three power-of-two banks keep the full256x192 image while reserving
    // memory for the file catalog. Read latency stays exactly one clock.
    reg [3:0] bank0 [0:16383];
    reg [3:0] bank1 [0:16383];
    reg [3:0] bank2 [0:16383];
    reg [3:0] q0,q1,q2;
    reg [1:0] read_bank;
    always @(posedge wclk) if(wren) begin
        case(waddr[15:14])
            2'd0: bank0[waddr[13:0]]<=wdata;
            2'd1: bank1[waddr[13:0]]<=wdata;
            2'd2: bank2[waddr[13:0]]<=wdata;
            default: ;
        endcase
    end
    always @(posedge rclk) begin
        q0<=bank0[raddr[13:0]];
        q1<=bank1[raddr[13:0]];
        q2<=bank2[raddr[13:0]];
        read_bank<=raddr[15:14];
    end
    assign rdata=(read_bank==0)?q0:(read_bank==1)?q1:(read_bank==2)?q2:4'd0;

endmodule
