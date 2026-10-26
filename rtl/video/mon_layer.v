//=============================================================================
// mon_layer.v —— 怪物立绘层（48x48 源图，3 倍放大到 144x144）
//
//   每只怪物有独立的 16 色调色板；淡入淡出直接作用在调色板上：
//   只有 16 个色项要缩放，怪物切换或亮度变化时重算一遍即可，
//   逐像素通路完全不变 —— 比逐像素乘 alpha 省太多了。
//
//   窗口固定在 (240,48)，正好 9x9 个字符格（144x144），
//   这样和字符层的混层规则（该格没字形才出图）才能对齐。
//
//   放大用定点乘: src = (dst * 171) >> 9，等价于 /3（0..143 范围内无误差）
//=============================================================================
`timescale 1ns/1ps
module mon_layer (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [4:0]  mon_id,      // 0..24
    input  wire [3:0]  fade,        // 0=全黑 .. 8=原色
    input  wire [11:0] x,           // 当前像素坐标(与 rpg_video 同一拍)
    input  wire [11:0] y,
    output wire        in_win,      // 该像素在立绘窗口内
    output reg  [15:0] rgb,         // 立绘颜色(已对齐到输出级)
    output reg         valid        // 与 rgb 同拍
);

    //---------------------------------------------------------
    // 窗口与源像素地址
    //---------------------------------------------------------
    localparam [11:0] X0 = 12'd240, Y0 = 12'd48;
    localparam integer SW = 48, SH = 48;               // 源图尺寸
    localparam integer FRM = SW * SH / 2;              // 每只 1152 字节

    wire in_win0 = (x >= X0) && (x < X0 + 12'd144) &&
                   (y >= Y0) && (y < Y0 + 12'd144);

    wire [11:0] ax = x - X0;                           // 0..143
    wire [11:0] ay = y - Y0;
    // 注意: 乘法必须显式给足位宽。写成 (ax * 12'd171) 时按 Verilog 规则
    // 结果只有 12 位, 乘积会被截断 —— 实测图像直接跑飞。
    wire [31:0] sxm = ax * 32'd171;                    // ax/3 = (ax*171)>>9
    wire [31:0] sym = ay * 32'd171;
    wire [11:0] sx = sxm[20:9];                        // 0..47
    wire [11:0] sy = sym[20:9];
    wire [11:0] spix = sy * 12'd48 + sx;               // 0..2303

    wire [14:0] maddr = mon_id * FRM + (spix >> 1);    // 字节地址

    wire [7:0]  mbyte;

    mon_rom u_mon (
        .clk   (clk),
        .addr  (maddr),
        .data  (mbyte),
        .paddr (pal_rd_addr),
        .pal   (pal_q)
    );

    //---------------------------------------------------------
    // 调色板：mon_id 或 fade 变了就重算 16 项
    //---------------------------------------------------------
    reg [15:0] pal_reg [0:15];
    reg [4:0]  last_id;
    reg [3:0]  last_fade;
    reg [4:0]  pcnt;      // 地址计数
    reg [4:0]  wcnt;      // 写入索引(pal_q 比地址晚一拍)
    reg        pload;

    wire [9:0] pal_rd_addr = {mon_id, pcnt[3:0]};
    wire [15:0] pal_q;

    // 把一个色项按 fade 缩放（fade=0 -> 全黑, 8 -> 原色）
    function [15:0] fade_rgb;
        input [15:0] c;
        input [3:0]  f;
        // 中间量必须比通道宽: 声明成 5 位的话 5bit*4bit 的乘积按最大操作数
        // 截断, 颜色会暗成 1/3 —— 实测踩过。
        reg [9:0] r, g, b;
        begin
            r = c[15:11] * f;          // 最大 31*8 = 248
            g = c[10:5]  * f;          // 最大 63*8 = 504
            b = c[4:0]   * f;
            fade_rgb = {r[7:3], g[8:3], b[7:3]};
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            last_id   <= 5'd31;
            last_fade <= 4'd15;
            pcnt      <= 5'd0;
            wcnt      <= 5'd0;
            pload     <= 1'b0;
        end else begin
            if (!pload) begin
                // 需要就重新装载
                if (mon_id != last_id || fade != last_fade) begin
                    pcnt  <= 5'd0;
                    pload <= 1'b1;
                end
            end else begin
                wcnt <= pcnt;                       // pal_q 对应当前 wcnt 的地址
                pal_reg[wcnt[3:0]] <= fade_rgb(pal_q, fade);
                if (pcnt == 5'd15) begin
                    pload     <= 1'b0;
                    last_id   <= mon_id;
                    last_fade <= fade;
                end else begin
                    pcnt <= pcnt + 5'd1;
                end
            end
        end
    end

    //---------------------------------------------------------
    // 像素流水：t1 取字节 -> t2 查色 -> t3 与字符层对齐
    //---------------------------------------------------------
    reg        win1, win2, win3;
    reg        nib1;
    reg [15:0] rgb2;
    reg [7:0]  byte1;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            win1 <= 0; win2 <= 0; win3 <= 0;
            nib1 <= 0; rgb2 <= 0; byte1 <= 0;
            rgb  <= 0; valid <= 0;
        end else begin
            // t0 -> t1
            win1  <= in_win0;
            nib1  <= spix[0];
            byte1 <= mbyte;
            // t1 -> t2
            win2  <= win1;
            rgb2  <= pal_reg[nib1 ? byte1[3:0] : byte1[7:4]];
            // t2 -> t3
            win3  <= win2;
            rgb   <= rgb2;
            valid <= win3;
        end
    end

    assign in_win = in_win0;

endmodule
