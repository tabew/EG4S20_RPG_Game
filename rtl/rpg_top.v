//=============================================================================
// rpg_top.v —— 《字界远征》顶层
//
//   时钟:  clk_pix = 25.175MHz (640x480p60 像素时钟)
//          clk_p5x = 125.875MHz (TMDS 串行化, DDR 后 251.75Mbps)
//
//   数据流:
//     按键 x4 -> 消抖 -> rpg_core(游戏逻辑 + 指令解释)
//                            | 写格子 {bg,fg,glyph}
//                            v
//                        rpg_video(40x30 字符屏) -> rgb565
//                            v
//                        hdmi_tx(TMDS) -> 4 对差分
//
//   不需要 SDRAM: 整屏只占 1200 个格子(2.4KB), 全在 BRAM 里。
//=============================================================================
`timescale 1ns/1ps
module rpg_top #(
    parameter integer MODE = 1          // 1 = 640x480p60
)(
    input  wire       clk50,
    input  wire       rst_key_n,
    input  wire [3:0] key_n,

    output wire [3:0] key_row,        // 矩阵键盘行扫描, 恒为低电平
    output wire [3:0] hdmi_d_p,
    output wire [3:0] hdmi_d_n,
    output wire       hdmi_clk_p,
    output wire       hdmi_clk_n,

    output wire [3:0] led
);

    //---------------------------------------------------------
    // 时钟 / 复位
    //---------------------------------------------------------
    wire clk_pix, clk_p5x, locked;

    clk_gen u_clk (
        .clk_in  (clk50),
        .rst_n   (rst_key_n),
        .clk_pix (clk_pix),
        .clk_p5x (clk_p5x),
        .locked  (locked)
    );

    wire arst_n = locked & rst_key_n;
    wire rst_n;

    reset_sync u_rst (.clk(clk_pix), .arst_n(arst_n), .rst_n(rst_n));

    //---------------------------------------------------------
    // 按键
    // 板上是 4x4 矩阵键盘: 列经 1k 上拉到 3.3V, 行做扫描输出。
    // 4 行全部驱动为低 -> 按下任意键把对应列拉低, 恰好匹配
    // 低有效的 key_n, 消抖逻辑无需修改 (同一列的 4 个键等价)。
    //---------------------------------------------------------
    assign key_row = 4'b0000;

    wire [3:0] kpress;

    key_debounce #(.CLK_KHZ(25000)) u_k0 (.clk(clk_pix), .rst_n(rst_n), .key_n(key_n[0]), .click(kpress[0]), .press(), .long_press());
    key_debounce #(.CLK_KHZ(25000)) u_k1 (.clk(clk_pix), .rst_n(rst_n), .key_n(key_n[1]), .click(kpress[1]), .press(), .long_press());
    key_debounce #(.CLK_KHZ(25000)) u_k2 (.clk(clk_pix), .rst_n(rst_n), .key_n(key_n[2]), .click(kpress[2]), .press(), .long_press());
    key_debounce #(.CLK_KHZ(25000)) u_k3 (.clk(clk_pix), .rst_n(rst_n), .key_n(key_n[3]), .click(kpress[3]), .press(), .long_press());

    //---------------------------------------------------------
    // 游戏核心 -> 字符屏
    //---------------------------------------------------------
    wire        we;
    wire [10:0] waddr;
    wire [15:0] wdata;

    rpg_core u_core (
        .clk   (clk_pix),
        .rst_n (rst_n),
        .key   (kpress),
        .we    (we),
        .waddr (waddr),
        .wdata (wdata)
    );

    wire        vga_hs, vga_vs, vga_de;
    wire [15:0] vga_rgb;

    rpg_video u_vid (
        .clk   (clk_pix),
        .rst_n (rst_n),
        .we    (we),
        .waddr (waddr),
        .wdata (wdata),
        .hs    (vga_hs),
        .vs    (vga_vs),
        .de    (vga_de),
        .rgb   (vga_rgb)
    );

    //---------------------------------------------------------
    // HDMI
    //---------------------------------------------------------
    hdmi_tx #(
        .H_ACTIVE    (640),
        .H_TOTAL     (800),
        .AUDIO_DI_EN (0)
    ) u_hdmi (
        .clk_pix    (clk_pix),
        .clk_p5x    (clk_p5x),
        .rst_pix_n  (rst_n),
        .rgb        (vga_rgb),
        .hs         (vga_hs),
        .vs         (vga_vs),
        .de         (vga_de),
        .aud_pkt    (56'd0),
        .aud_req    (1'b0),
        .aud_got    (),
        .hdmi_d_p   (hdmi_d_p),
        .hdmi_d_n   (hdmi_d_n),
        .hdmi_clk_p (hdmi_clk_p),
        .hdmi_clk_n (hdmi_clk_n)
    );

    //---------------------------------------------------------
    // 指示灯: de 亮 = 视频正在输出
    //---------------------------------------------------------
    reg [23:0] hb;
    always @(posedge clk_pix or negedge rst_n) begin
        if (!rst_n) hb <= 24'd0;
        else        hb <= hb + 24'd1;
    end

    assign led = {vga_vs, vga_de, hb[23], locked};

endmodule
