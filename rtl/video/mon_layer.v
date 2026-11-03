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
    input  wire [1:0]  rotation,    // clockwise quarter turns; open/X/Z -> 0
    input  wire        mirror,      // horizontal reflection AFTER rotation
    input  wire signed [4:0] jx,    // 受击抖动，逻辑像素，正值让图往右偏
    input  wire signed [4:0] jy,    // 正值让图往下偏
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
    // 抖动只挪取样点，窗口仍钉在原处，文字和边框的混层不用改。
    wire signed [12:0] axj = $signed({1'b0, ax}) - $signed(jx);
    wire signed [12:0] ayj = $signed({1'b0, ay}) - $signed(jy);
    wire [11:0] axc = axj[12] ? 12'd0 : ((axj > 13'sd143) ? 12'd143 : axj[11:0]);
    wire [11:0] ayc = ayj[12] ? 12'd0 : ((ayj > 13'sd143) ? 12'd143 : ayj[11:0]);
    // 注意: 乘法必须显式给足位宽。写成 (ax * 12'd171) 时按 Verilog 规则
    // 结果只有 12 位, 乘积会被截断 —— 实测图像直接跑飞。
    wire [31:0] sxm = axc * 32'd171;                   // ax/3 = (ax*171)>>9
    wire [31:0] sym = ayc * 32'd171;
    // Clamp blanking reads to the first byte of this monster. The transform
    // itself is only six-bit subtracts/muxes; retain the existing /3 scaler.
    wire [5:0] u = in_win0 ? sxm[14:9] : 6'd0;
    wire [5:0] v = in_win0 ? sym[14:9] : 6'd0;
    reg [1:0] rotation_safe;
    reg mirror_safe;
    always @* begin
        case (rotation)
            2'd0: rotation_safe = 2'd0;
            2'd1: rotation_safe = 2'd1;
            2'd2: rotation_safe = 2'd2;
            2'd3: rotation_safe = 2'd3;
            default: rotation_safe = 2'd0;
        endcase
        case (mirror)
            1'b1: mirror_safe = 1'b1;
            default: mirror_safe = 1'b0;
        endcase
    end
    wire [5:0] unmirror_u = mirror_safe ? 6'd47 - u : u;
    reg [5:0] sx, sy;
    always @* begin
        // Inverse lookup: undo display mirror, then undo clockwise rotation.
        case (rotation_safe)
            2'd1: begin sx = v; sy = 6'd47 - unmirror_u; end
            2'd2: begin sx = 6'd47 - unmirror_u; sy = 6'd47 - v; end
            2'd3: begin sx = 6'd47 - v; sy = unmirror_u; end
            default: begin sx = unmirror_u; sy = v; end
        endcase
    end
    wire [11:0] spix = sy * 12'd48 + sx;               // 0..2303
    wire [11:0] byte_offset = in_win0 ? (spix >> 1) : 12'd0;
    wire [14:0] maddr = mon_id * FRM + byte_offset;     // 字节地址

    wire [7:0]  mbyte;

    //---------------------------------------------------------
    // 调色板：mon_id 或 fade 变了就重算 16 项
    //---------------------------------------------------------
    reg [15:0] pal_reg [0:15];
    reg [4:0]  last_id;
    reg [3:0]  last_fade;
    reg [4:0]  pcnt;      // 地址计数
    reg [4:0]  wcnt;      // 写入索引(pal_q 比地址晚一拍)
    reg        pload;

    // ★ 声明必须放在 mon_rom 例化之前: 否则 Verilog 会把 pal_rd_addr /
    //   pal_q 隐式当成 1bit wire, 后面再显式声明就是"重复声明",
    //   TD / iverilog 严格模式下会直接报错。
    wire [9:0]  pal_rd_addr = {mon_id, pcnt[3:0]};
    wire [15:0] pal_q;

    mon_rom u_mon (
        .clk   (clk),
        .addr  (maddr),
        .data  (mbyte),
        .paddr (pal_rd_addr),
        .pal   (pal_q)
    );

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
                // Drain the synchronous ROM: at pcnt=16 the pending wcnt=15
                // finally writes color 15. Stopping at 15 left it undefined.
                if (pcnt == 5'd16) begin
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
    reg        win1, win2;
    reg        nib1;
    reg [15:0] rgb2;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            win1 <= 0; win2 <= 0;
            nib1 <= 0; rgb2 <= 0;
            rgb  <= 0; valid <= 0;
        end else begin
            // P1: mon_rom registers mbyte from this pixel's address.
            win1  <= in_win0;
            nib1  <= spix[0];
            // P2: consume that byte with its matching nibble selector.
            win2  <= win1;
            rgb2  <= pal_reg[nib1 ? mbyte[3:0] : mbyte[7:4]];
            // P3: RGB and validity align with rpg_video.de3.
            rgb   <= rgb2;
            valid <= win2;
        end
    end

    assign in_win = in_win0;

endmodule
