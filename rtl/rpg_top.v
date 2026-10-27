//=============================================================================
// rpg_top.v —— 《字界远征》顶层
//
//   时钟:  clk_pix = 40.000MHz (800x600p60 像素时钟)
//          clk_p5x = 200.000MHz (TMDS 串行化, DDR 后 400Mbps)
//
//   数据流:
//     按键 x4 -> 消抖 -> rpg_core(游戏逻辑 + 指令解释)
//                            | 写格子 {bg,fg,glyph}
//                            v
//                        rpg_video(40x30 字符屏 + 插图层 + 立绘层)
//                            | 640x480 逻辑 -> 1.25x 缩放 -> 800x600
//                            v
//                        hdmi_tx(官方 DVITransmitter IP) -> 4 对差分
//
//   不需要 SDRAM: 整屏只占 1200 个格子(2.5KB), 全在 BRAM 里。
//
//   ★ 本文件 = "GitHub 最新功能版" + "本板上板适配版" 的合并结果:
//     - 功能跟随仓库最新(动态插图/25 种怪物立绘/两页商店/区域文案)
//     - 保留本底板适配: 按键列序交换、消抖 25MHz 参数、
//       HDMI 3 对数据线只出 P 端、800x600 输出参数
//=============================================================================
`timescale 1ns/1ps
module rpg_top #(
    parameter integer MODE = 1
)(
    input  wire       clk50,
    input  wire       rst_key_n,
    input  wire [3:0] key_n,

    // 真差分: 只引出 P 端, N 端由 TD 按 LVDS 约束自动配对
    // 本底板 HDMI 只接 3 对数据线
    output wire [2:0] hdmi_d_p,
    output wire       hdmi_clk_p,
    output wire [3:0] key_row,
    output wire [3:0] led,
    output wire       buzzer_n        // 无源蜂鸣器(PNP 驱动, 低有效)
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

    // 板上矩阵键盘列序与逻辑位序相反(实测): 最左列=key_n[3], 最右列=key_n[0]
    // 此处交换映射, 使最左列 = 游戏键1
    wire [3:0] key_swap = {key_n[0], key_n[1], key_n[2], key_n[3]};

    key_debounce #(.CLK_KHZ(40000)) u_k0 (.clk(clk_pix), .rst_n(rst_n), .key_n(key_swap[0]), .click(kpress[0]), .press(), .long_press());
    key_debounce #(.CLK_KHZ(40000)) u_k1 (.clk(clk_pix), .rst_n(rst_n), .key_n(key_swap[1]), .click(kpress[1]), .press(), .long_press());
    key_debounce #(.CLK_KHZ(40000)) u_k2 (.clk(clk_pix), .rst_n(rst_n), .key_n(key_swap[2]), .click(kpress[2]), .press(), .long_press());
    key_debounce #(.CLK_KHZ(40000)) u_k3 (.clk(clk_pix), .rst_n(rst_n), .key_n(key_swap[3]), .click(kpress[3]), .press(), .long_press());

    //---------------------------------------------------------
    // 游戏核心 -> 字符屏
    //---------------------------------------------------------
    wire        we;
    wire        anim_on;
    wire [2:0]  anim_frame;
    wire        mon_on;
    wire [4:0]  mon_id;
    wire [3:0]  mon_fade;
    wire [10:0] waddr;
    wire [16:0] wdata;
    wire [2:0]  sfx_id;
    wire        sfx_trig;

    rpg_core u_core (
        .clk   (clk_pix),
        .rst_n (rst_n),
        .key   (kpress),
        .we    (we),
        .waddr (waddr),
        .wdata (wdata),
        .anim_on    (anim_on),
        .anim_frame (anim_frame),
        .mon_on     (mon_on),
        .mon_id     (mon_id),
        .mon_fade   (mon_fade),
        .sfx_id     (sfx_id),
        .sfx_trig   (sfx_trig)
    );

    wire        vga_hs, vga_vs, vga_de;
    wire [15:0] vga_rgb;

    rpg_video #(.TEST_BARS(0)) u_vid (
        .clk   (clk_pix),
        .rst_n (rst_n),
        .we    (we),
        .waddr (waddr),
        .wdata (wdata),
        .anim_on    (anim_on),
        .anim_frame (anim_frame),
        .mon_on     (mon_on),
        .mon_id     (mon_id),
        .mon_fade   (mon_fade),
        .hs    (vga_hs),
        .vs    (vga_vs),
        .de    (vga_de),
        .rgb   (vga_rgb)
    );

    //---------------------------------------------------------
    // HDMI (官方 DVITransmitter IP, 800x600)
    //---------------------------------------------------------
    hdmi_tx #(
        .H_ACTIVE    (800),
        .H_TOTAL     (1056),
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
        .hdmi_clk_p (hdmi_clk_p)
    );

    //---------------------------------------------------------
    // 蜂鸣器音效: 游戏事件 -> buzzer 模块 -> H11(低有效)
    //   上电后约 1.6ms 先"滴"一声, 既是自检也验证蜂鸣器引脚
    //---------------------------------------------------------
    reg [15:0] boot_cnt;
    reg        boot_done;

    always @(posedge clk_pix or negedge rst_n) begin
        if (!rst_n) begin
            boot_cnt  <= 16'd0;
            boot_done <= 1'b0;
        end else if (!boot_done) begin
            if (boot_cnt >= 16'hFFFF) boot_done <= 1'b1;
            else                      boot_cnt  <= boot_cnt + 16'd1;
        end
    end

    wire boot_trig = (!boot_done) && (boot_cnt == 16'hFFFF);
    wire        buzz_trig = boot_trig | sfx_trig;
    wire [2:0]  buzz_id   = boot_trig ? 3'd7 : sfx_id;

    buzzer u_buzz (
        .clk    (clk_pix),
        .rst_n  (rst_n),
        .id     (buzz_id),
        .trig   (buzz_trig),
        .buzz_n (buzzer_n)
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
