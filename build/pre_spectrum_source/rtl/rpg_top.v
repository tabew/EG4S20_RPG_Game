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
    parameter integer MODE = 1,
    parameter integer CEA_COMPAT = 1
)(
    input  wire       clk50,
    input  wire       rst_key_n,
    input  wire [3:0] key_n,

    // 真差分: 只引出 P 端, N 端由 TD 按 LVDS 约束自动配对
    // 本底板 HDMI 只接 3 对数据线
    output wire [2:0] hdmi_d_p,
    output wire       hdmi_clk_p,
    output wire [3:0] key_row,
    output wire [7:0] led,            // 8 位 R-2R DAC 输出（复用 LED0~7，接音箱）
    output wire       buzzer_n,       // 无源蜂鸣器(H11): 音频 PWM 输出
    output wire       pwm_audio,      // MO底板 Audio_PWM(F3): 底板功放 -> 扬声器/OUT 口

    // TF 卡 (扩展底板 SPI): CS=F13 CLK=F15 MOSI=F14 MISO=D14。
    // 底板原理图4.6节已确认; 板载10k上拉, 保持现有ADC约束。
    output wire       sd_sclk,
    output wire       sd_mosi,
    output wire       sd_cs_n,
    input  wire       sd_miso
);

    //---------------------------------------------------------
    // 时钟 / 复位
    //---------------------------------------------------------
    wire clk_pix, clk_p5x,clk_mem50,clk_sdram50,locked;

    localparam integer PIXEL_HZ = CEA_COMPAT ? 25200000 : 40000000;
    clk_gen #(.CEA_COMPAT(CEA_COMPAT)) u_clk (
        .clk_in  (clk50),
        .rst_n   (rst_key_n),
        .clk_pix (clk_pix),
        .clk_p5x (clk_p5x),
        .clk_mem50(clk_mem50),.clk_sdram50(clk_sdram50),
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

    wire [3:0] kpress, klong;

    // 板上矩阵键盘列序与逻辑位序相反(实测): 最左列=key_n[3], 最右列=key_n[0]
    // 此处交换映射, 使最左列 = 游戏键1
    wire [3:0] key_swap = {key_n[0], key_n[1], key_n[2], key_n[3]};

    key_debounce #(.CLK_KHZ(PIXEL_HZ/1000)) u_k0 (.clk(clk_pix), .rst_n(rst_n), .key_n(key_swap[0]), .click(kpress[0]), .press(), .long_press(klong[0]));
    key_debounce #(.CLK_KHZ(PIXEL_HZ/1000)) u_k1 (.clk(clk_pix), .rst_n(rst_n), .key_n(key_swap[1]), .click(kpress[1]), .press(), .long_press(klong[1]));
    key_debounce #(.CLK_KHZ(PIXEL_HZ/1000)) u_k2 (.clk(clk_pix), .rst_n(rst_n), .key_n(key_swap[2]), .click(kpress[2]), .press(), .long_press(klong[2]));
    key_debounce #(.CLK_KHZ(PIXEL_HZ/1000)) u_k3 (.clk(clk_pix), .rst_n(rst_n), .key_n(key_swap[3]), .click(kpress[3]), .press(), .long_press(klong[3]));

    // Player boots directly into sequence mode. Original RPG remains available.
    wire gal_on, gal_block;
    wire [1:0] gal_img;
    wire [3:0] gal_fade;
    wire frame_tick,media_req,media_req_ready,media_cancel;
    wire [5:0] media_req_index;
    wire [1:0] media_mode;
    wire media_auto,media_settings,media_osd,media_visual,media_mute,media_loading;
    wire [3:0] media_brightness;
    wire [1:0] media_contrast,media_view,fb_view_active;
    wire m_cat_ready,m_busy,m_valid,m_done;
    wire fb_front_valid,fb_pixel_valid,fb_pixel_req;
    wire [23:0] fb_pixel_rgb;
    wire [1:0] m_error;
    wire [5:0] m_count,m_seq_count,m_shown;
    wire [63:0] m_name;
    assign gal_img=m_shown[1:0];
    media_ctrl #(.VISUAL_DEFAULT(0)) u_media (
        .clk(clk_pix),.rst_n(rst_n),.frame_tick(frame_tick),.keys(kpress),.longs(klong),
        .cat_ready(m_cat_ready),.image_busy(m_busy),.image_valid(m_valid),.load_done(m_done),
        .image_error(m_error),.file_count(m_count),.seq_count(m_seq_count),.shown_index(m_shown),
        .req_ready(media_req_ready),.fb_front_valid(fb_front_valid),.load_req(media_req),.cancel_req(media_cancel),.load_index(media_req_index),
        .media_mode(media_mode),.media_auto(media_auto),.media_settings(media_settings),
        .media_osd(media_osd),.media_visual(media_visual),.media_mute(media_mute),
        .media_brightness(media_brightness),.media_contrast(media_contrast),.media_view(media_view),
        .gal_fade(gal_fade),.gal_on(gal_on),.gal_block(gal_block),.media_loading(media_loading)
    );
    wire [3:0] key_core = gal_block ? 4'd0 : kpress;

    //---------------------------------------------------------
    // TF读取链路: SPI -> FAT32/BMP RGB888 -> SDRAM双缓存 -> HDMI
    //   读出的 BMP 缩略图写入 tf_ram, 占用相册第 1 页显示,
    //   作为"SPI 读取 TF 卡中 BMP"的可视化验证 (赛题基础要求 01)。
    //---------------------------------------------------------
    wire rst_n50,sd_rst_n,fb_ready;
    reset_sync u_sd_release(.clk(clk_mem50),.arst_n(rst_n50&&fb_ready),.rst_n(sd_rst_n));
    reset_sync u_rst50 (.clk(clk_mem50), .arst_n(arst_n), .rst_n(rst_n50));

    wire        sd_init_go, sd_init_done, sd_init_err;
    wire        sd_rd_go;
    wire [31:0] sd_rd_addr;
    wire [7:0]  sd_dout;
    wire        sd_dvalid, sd_blk_done;
    wire [4:0]  sd_step50;
    wire [7:0]  sd_r1b50;
    wire [1:0]  tf_fdiag50;

    sd_spi u_sdspi (
        .clk       (clk_mem50),
        .rst_n     (sd_rst_n),
        .sd_sclk   (sd_sclk),
        .sd_mosi   (sd_mosi),
        .sd_cs_n   (sd_cs_n),
        .sd_miso   (sd_miso),
        .init_go   (sd_init_go),
        .rd_go     (sd_rd_go),
        .rd_addr   (sd_rd_addr),
        .init_done (sd_init_done),
        .ccs       (),
        .err       (sd_init_err),
        .dout      (sd_dout),
        .dvalid    (sd_dvalid),
        .blk_done  (sd_blk_done),
        .step      (sd_step50),
        .r1b       (sd_r1b50)
    );

    wire [7:0]  sd_dbus50;    // 诊断轮询字节 (sd_img 输出)

    // 诊断轮询: 每项 0.5 秒, 最后 0.1 秒消隐; 一轮 8 项共 4 秒
    reg [24:0] ds_cnt;
    reg [2:0] ds_sel;
    always @(posedge clk_mem50 or negedge rst_n50) begin
        if (!rst_n50) begin
            ds_cnt <= 25'd0;
            ds_sel <= 3'd0;
        end else if (ds_cnt == 25'd24_999_999) begin
            ds_cnt <= 25'd0;
            ds_sel <= ds_sel + 3'd1;
        end else ds_cnt <= ds_cnt + 25'd1;
    end

    wire [15:0] tf_waddr;     // 49152 像素需16位地址 (0..49151)
    wire [3:0]  tf_wdata;
    wire        tf_wren;
    wire        tf_valid50;
    wire [1:0]  tf_err50;

    wire sd_load_go,sd_cancel_go,sd_load_cancelled,sd_cat_ready,sd_image_busy,sd_load_done;
    wire [5:0] sd_load_index,sd_file_count,sd_seq_count,sd_shown_index;
    wire [63:0] sd_shown_name;
    wire fb_start,fb_raw_valid,fb_raw_ready,fb_frame_done,fb_frame_ok,fb_s_front_valid,fb_busy,fb_underrun;
    wire [18:0] fb_raw_addr;
    wire [23:0] fb_raw_data;
    wire [3:0] fb_errors;
    wire fb_frame_end,fb_frame_abort,publication_pending,published_valid,published_done;
    wire [1:0] published_error;
    wire [5:0] published_index;
    wire [63:0] published_name;
    wire sd_decode_go,cache_swap_only,cache_transaction_busy;
    wire [5:0] cache_decode_index;
    wire [1:0] cache_write_bank,cache_swap_bank,fb_front_bank;
    sd_img #(.FULL_FRAME(1)) u_sdimg (
        .clk       (clk_mem50),
        .rst_n     (sd_rst_n),
        .load_go(sd_decode_go),.load_index(cache_decode_index),.cancel_go(sd_cancel_go),.load_cancelled(sd_load_cancelled),
        .file_count(sd_file_count),.seq_count(sd_seq_count),.shown_index(sd_shown_index),
        .shown_name(sd_shown_name),.cat_ready(sd_cat_ready),.busy(sd_image_busy),.load_done(sd_load_done),
        .src_width(),.src_height(),
        .fb_start(fb_start),.fb_pixel_valid(fb_raw_valid),.fb_pixel_addr(fb_raw_addr),.fb_pixel_data(fb_raw_data),
        .init_go   (sd_init_go),
        .init_done (sd_init_done),
        .init_err  (sd_init_err),
        .rd_go     (sd_rd_go),
        .rd_addr   (sd_rd_addr),
        .dout      (sd_dout),
        .dvalid    (sd_dvalid),
        .blk_done  (sd_blk_done),
        .tw_addr   (tf_waddr),
        .tw_data   (tf_wdata),
        .tw_wren   (tf_wren),
        .tf_valid  (tf_valid50),
        .tf_err    (tf_err50),
        .fdiag     (tf_fdiag50),
        .dsel      (ds_sel),
        .dbg       (sd_dbus50)
    );


    wire [15:0] tf_raddr;     // 16位: 256x192
    wire [3:0]  tf_rdata;

    // Complete640x480 RGB888 lives in the dedicated external die SDRAM.
    // The former quantized thumbnail RAM is not instantiated in this build.
    assign tf_rdata=4'd0;
    media_framebuffer u_framebuffer(
        .sclk(clk_mem50),.phy_clk(clk_sdram50),.srst_n(rst_n50),.pclk(clk_pix),.prst_n(rst_n),
        .cache_mode(1'b1),.write_bank(cache_write_bank),.swap_only(cache_swap_only),.swap_bank(cache_swap_bank),.s_front_bank(fb_front_bank),
        .view_mode(media_view),.view_active(fb_view_active),
        .frame_begin(fb_start),.pixel_wr_valid(fb_raw_valid),.pixel_wr_addr(fb_raw_addr),.pixel_wr_data(fb_raw_data),
        .pixel_wr_ready(fb_raw_ready),.frame_end(fb_frame_end),.frame_abort(fb_frame_abort),
        .s_ready(fb_ready),.frame_done(fb_frame_done),.frame_ok(fb_frame_ok),.s_front_valid(fb_s_front_valid),
        .busy(fb_busy),.error_flags(fb_errors),.frame_tick(frame_tick),.pixel_req(fb_pixel_req),
        .pixel_rgb(fb_pixel_rgb),.pixel_valid(fb_pixel_valid),.front_valid(fb_front_valid),.underrun(fb_underrun)
    );
    // Four recently used full frames reside in the dedicated8MiB SDRAM.
    // Hits select an existing bank at vblank without a TF read or image rewrite.
    media_frame_cache u_frame_cache(
        .clk(clk_mem50),.rst_n(rst_n50),.request_go(sd_load_go),.request_index(sd_load_index),.cancel_go(sd_cancel_go),
        .cat_ready(sd_cat_ready),.raw_busy(sd_image_busy),.raw_done(sd_load_done),.raw_cancelled(sd_load_cancelled),
        .raw_valid(tf_valid50),.raw_error(tf_err50),.raw_index(sd_shown_index),.raw_name(sd_shown_name),
        .frame_begin(fb_start),.frame_done(fb_frame_done),.frame_ok(fb_frame_ok),.front_valid(fb_s_front_valid),.front_bank(fb_front_bank),
        .decode_go(sd_decode_go),.decode_index(cache_decode_index),.write_bank(cache_write_bank),
        .swap_only(cache_swap_only),.swap_bank(cache_swap_bank),.frame_end(fb_frame_end),.frame_abort(fb_frame_abort),
        .publication_pending(publication_pending),.transaction_busy(cache_transaction_busy),
        .published_valid(published_valid),.published_done(published_done),.published_error(published_error),
        .published_index(published_index),.published_name(published_name),.cache_hits(),.cache_misses()
    );

    // All status including diagnostics crosses as a coherent held snapshot.
    wire [7:0] diag50={fb_ready,fb_s_front_valid,tf_fdiag50[0],sd_step50};
    wire [7:0] panel2=sd_step50[4] ? sd_dbus50 : sd_r1b50;
    wire fill=sd_step50[4] && (ds_cnt>=25'd20_000_000);
    wire [7:0] dgs2,r1s2;
    wire fl2;
    media_cdc u_media_cdc (
        .pclk(clk_pix),.prst_n(rst_n),.sclk(clk_mem50),.srst_n(rst_n50),
        .p_req(media_req),.p_cancel(media_cancel),.p_index(media_req_index),.p_req_ready(media_req_ready),
        .s_load_go(sd_load_go),.s_cancel_go(sd_cancel_go),.s_load_index(sd_load_index),
        .s_cat_ready(sd_cat_ready),.s_busy(sd_image_busy||publication_pending||cache_transaction_busy),.s_valid(published_valid),.s_done(published_done),
        .s_error(sd_cat_ready?published_error:tf_err50),.s_count(sd_file_count),.s_seq_count(sd_seq_count),
        .s_shown(published_index),.s_name(published_name),
        .s_diag(diag50),.s_panel(panel2),.s_fill(fill),.p_diag(dgs2),.p_panel(r1s2),.p_fill(fl2),
        .p_cat_ready(m_cat_ready),.p_busy(m_busy),.p_valid(m_valid),.p_done(m_done),
        .p_error(m_error),.p_count(m_count),.p_seq_count(m_seq_count),.p_shown(m_shown),.p_name(m_name)
    );
    wire tf_valid_pix=m_valid;
    wire [1:0] err_sync=m_error;

    //---------------------------------------------------------
    // 换图音效: 按当前显示的图号发一个专属音
    //   m_shown 与 sound 同在 clk_pix 域, 直接接即可, 无需跨时钟
    //   每张图的音高表在 img_chime 里 (25 个音, 乱序排布)
    //---------------------------------------------------------
    wire        img_chime_trig;
    wire [23:0] img_chime_step;
    wire [15:0] img_chime_len;

    img_chime #(.CLK_HZ(PIXEL_HZ)) u_chime (
        .clk   (clk_pix),
        .rst_n (rst_n),
        .index (m_shown),
        .count (m_count),
        .ready (m_cat_ready),
        .trig  (img_chime_trig),
        .step  (img_chime_step),
        .len   (img_chime_len)
    );

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
    wire [3:0]  sfx_id;
    wire        sfx_trig;
    wire [3:0]  ui_state;          // 当前场景: 0标题 1选职业 2地图 3战斗 4商店 5死亡 6通关 7插图 8二页商店
    wire [1:0] mon_rotation;
    wire mon_mirror;
    wire mon_transform_enabled = !gal_on && !gal_block && mon_on && ui_state==4'd3;
    mon_transform_ctrl u_mon_transform (
        .clk(clk_pix),.rst_n(rst_n),.frame_tick(frame_tick),
        .battle_active(mon_transform_enabled),.rotate_step(klong[0]),.mirror_toggle(klong[1]),
        .rotation(mon_rotation),.mirror(mon_mirror)
    );

    rpg_core u_core (
        .clk   (clk_pix),
        .rst_n (rst_n),
        .key   (key_core),
        .we    (we),
        .waddr (waddr),
        .wdata (wdata),
        .anim_on    (anim_on),
        .anim_frame (anim_frame),
        .mon_on     (mon_on),
        .mon_id     (mon_id),
        .mon_fade   (mon_fade),
        .sfx_id     (sfx_id),
        .sfx_trig   (sfx_trig),
        .dbg_scene  (ui_state)
    );

    wire        vga_hs, vga_vs, vga_de;
    wire [15:0] vga_rgb;
    wire [23:0] vga_rgb_full;
    wire [63:0] spec;              // 8 根彩条高度, 每根 8 位
    wire [7:0] snd_dac;
    // Existing PSG mixes BGM, RPG effects and image chimes at its native32kHz.
    // All audio logic shares clk_pix. HDMI samples this held mix at exact48kHz.
    // Offset-binary8 -> signed16, gain64: peak7680 preserves test-tone loudness.
    wire signed [15:0] hdmi_pcm_sample = {{3{~snd_dac[7]}},snd_dac[6:0],6'd0};
    assign led=media_mute ? 8'd128 : snd_dac;
    wire [6:0]  snd_n0, snd_n1, snd_n2;   // 三个声部的音号
    wire [7:0]  snd_g0, snd_g1, snd_g2;   // 三个声部的包络

    rpg_video #(.TEST_BARS(0),.VIDEO_MODE(CEA_COMPAT?1:3)) u_vid (
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
        .mon_rotation(mon_rotation),.mon_mirror(mon_mirror),
        .bars       (media_mute ? 64'd0 : spec),
        .gal_on     (gal_on),
        .media_mode(media_mode),.media_auto(media_auto),.media_settings(media_settings),
        .media_loading(media_loading),.media_osd(media_osd),.media_visual(media_visual),
        .media_index(m_shown),.media_count(m_count),.media_name(m_name),
        .media_brightness(media_brightness),.media_contrast(media_contrast),.media_view(fb_view_active),
        .frame_tick(frame_tick),
        .gal_img    (gal_img),
        .gal_fade   (gal_fade),
        .tf_valid   (tf_valid_pix),
        .tf_err     (err_sync),
        .diag       (dgs2),
        .diag2      (r1s2),
        .dfill      (fl2),
        .tf_rdata   (tf_rdata),
        .tf_raddr   (tf_raddr),
        .fb_front_valid(fb_front_valid),.fb_pixel_valid(fb_pixel_valid),.fb_pixel_rgb(fb_pixel_rgb),.fb_pixel_req(fb_pixel_req),
        .rgb_full(vga_rgb_full),
        .hs    (vga_hs),
        .vs    (vga_vs),
        .de    (vga_de),
        .rgb   (vga_rgb)
    );

    //---------------------------------------------------------
    // HDMI: CEA640x480/VIC1 compatibility, with legacy800x600 profile retained
    //---------------------------------------------------------
    // Separate display compositing from encrypted TMDS encoder logic.
    // RGB and all timing controls share the same one-pixel register delay.
    reg [15:0] hdmi_rgb;
    reg [23:0] hdmi_rgb_full;
    reg hdmi_hs,hdmi_vs,hdmi_de;
    always @(posedge clk_pix or negedge rst_n) begin
        if(!rst_n) begin hdmi_rgb<=0;hdmi_rgb_full<=0;hdmi_hs<=0;hdmi_vs<=0;hdmi_de<=0;end
        else begin hdmi_rgb<=vga_rgb;hdmi_rgb_full<=vga_rgb_full;hdmi_hs<=vga_hs;hdmi_vs<=vga_vs;hdmi_de<=vga_de;end
    end
    hdmi_tx #(
        .H_ACTIVE    (CEA_COMPAT?640:800),
        .H_TOTAL     (CEA_COMPAT?800:1056),
        .PIXEL_HZ    (PIXEL_HZ),.VIDEO_ID(CEA_COMPAT?1:0),
        .AUDIO_DI_EN (1),.AUDIO_PCM_EN(1)
    ) u_hdmi (
        .clk_pix    (clk_pix),
        .clk_p5x    (clk_p5x),
        .rst_pix_n  (rst_n),
        .rgb        (hdmi_rgb),
        .rgb_full(hdmi_rgb_full),.full_rgb_en(1'b1),.mute(media_mute),.pcm_sample(hdmi_pcm_sample),
        .hs         (hdmi_hs),
        .vs         (hdmi_vs),
        .de         (hdmi_de),
        .aud_pkt    (56'd0),
        .aud_req    (1'b0),
        .aud_got    (),
        .hdmi_d_p   (hdmi_d_p),
        .hdmi_clk_p (hdmi_clk_p)
    );

    //---------------------------------------------------------
    // 音频: PSG 合成 -> 两路同时输出
    //   1) led[7:0] = 8 位 R-2R DAC (模拟量, 需接 DAC_VOUT 才进音箱)
    //   2) buzzer_n = 同一音频做 156kHz PWM -> 板载无源蜂鸣器直接发声
    //      (H11 是唯一确认连通的发声器件, 不依赖任何外接接线)
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
    wire [3:0]  buzz_id   = boot_trig ? 4'd7 : sfx_id;

    // 8 位 PWM 载波: 40MHz / 256 = 156.25kHz, 远超可听频段
    reg [7:0] pwm_cnt;
    always @(posedge clk_pix or negedge rst_n) begin
        if (!rst_n) pwm_cnt <= 8'd0;
        else        pwm_cnt <= pwm_cnt + 8'd1;
    end

    //---------------------------------------------------------
    // 已实测打通: F3 -> 底板 RC -> 运放 -> 耳机口 J3, 音箱能正常出声。
    //   两路同时输出:
    //     1) pwm_audio(F3) -> 底板耳机口/功放 -> 外部音箱  ← 赛题要求的"音箱"
    //     2) buzzer_n(H11) -> 板载无源蜂鸣器            ← 保险, 音箱没接也能听到
    //   PWM 空闲 50% 占空比 = 1.65V, 正好是底板单电源运放的中间偏置,
    //   156kHz 载波被底板两级 RC(约 1kHz)滤掉, 只剩音频包络。
    //---------------------------------------------------------
    assign pwm_audio = (pwm_cnt < led);                    // 高有效: 占空比 = dac/256
    assign buzzer_n  = (pwm_cnt < led) ? 1'b0 : 1'b1;      // PNP 低有效

    //---------------------------------------------------------
    // BGM 选曲: 跟随游戏场景自动切换
    //   战斗(3)         -> 轨 1 战斗曲
    //   通关(6)/死亡(5) -> 轨 2 胜利曲
    //   其余(标题/地图/商店/插图) -> 轨 0 探索曲
    //---------------------------------------------------------
    reg [1:0] mus_sel;
    always @(*) begin
        if (gal_on)                                   mus_sel = (media_mode==0) ? 2'd1 : 2'd0;
        else if (ui_state == 4'd3)                       mus_sel = 2'd1;
        else if (ui_state == 4'd6 || ui_state == 4'd5) mus_sel = 2'd2;
        else                                        mus_sel = 2'd0;
    end

    sound #(
        .CLK_HZ    (PIXEL_HZ),
        .SAMPLE_HZ (32000),
        .BPM       (120),
        .LOOP_END  (63)
    ) u_snd (
        .clk      (clk_pix),
        .rst_n    (rst_n),
        .sfx_id   (buzz_id),
        .sfx_trig (buzz_trig),
        .chime_step (img_chime_step),
        .chime_len  (img_chime_len),
        .chime_trig (img_chime_trig),
        .mus_on   (~media_mute),
        .mus_sel  (mus_sel),
        .dac      (snd_dac),
        .note0    (snd_n0),
        .note1    (snd_n1),
        .note2    (snd_n2),
        .lev0     (snd_g0),
        .lev1     (snd_g1),
        .lev2     (snd_g2)
    );

    //---------------------------------------------------------
    // 彩条: 由三个声部的音号决定柱子位置, 包络决定柱高
    //   位置随音高左右移动 (不是整排一起跳), 结果送 rpg_video 叠在底部
    //   注: 这不是频谱分析, 详见 note_bars 模块头的说明
    //---------------------------------------------------------
    note_bars u_bars (
        .clk   (clk_pix),
        .rst_n (rst_n),
        .n0    (snd_n0),
        .n1    (snd_n1),
        .n2    (snd_n2),
        .g0    (snd_g0),
        .g1    (snd_g1),
        .g2    (snd_g2),
        .bars  (spec)
    );

    //---------------------------------------------------------
    // 指示灯已取消: led[7:0] 现在全部给 R-2R DAC 做音频输出,
    // 上板看到 8 个 LED 随音乐闪烁属正常现象, 不是故障。
    // 若需要看"视频是否在输出", 以显示器有无画面为准。
    //---------------------------------------------------------

endmodule

// MEDIA_FRAME_CACHE_BEGIN
// Four logical2MiB SDRAM slots, each holds307200 RGB888 words.
// Metadata is committed only after the framebuffer pixel-domain acknowledgement.
module media_frame_cache #(
    parameter integer ENABLE_CACHE=1
)(
    input wire clk,rst_n,
    input wire request_go,input wire[5:0]request_index,input wire cancel_go,
    input wire cat_ready,raw_busy,raw_done,raw_cancelled,raw_valid,
    input wire[1:0]raw_error,input wire[5:0]raw_index,input wire[63:0]raw_name,
    input wire frame_begin,frame_done,frame_ok,front_valid,input wire[1:0]front_bank,
    output reg decode_go,output reg[5:0]decode_index,
    output reg[1:0]write_bank,output reg swap_only,output reg[1:0]swap_bank,
    output reg frame_end,frame_abort,
    output reg publication_pending,output wire transaction_busy,
    output reg published_valid,published_done,output reg[1:0]published_error,
    output reg[5:0]published_index,output reg[63:0]published_name,
    output reg[15:0]cache_hits,cache_misses
);
    reg[3:0]valid_slot;
    reg[5:0]slot_index[0:3];reg[63:0]slot_name[0:3];reg[1:0]slot_age[0:3];
    reg active,active_hit,completion_seen,completion_ok,cancelled;
    reg[1:0]active_bank,pending_error;
    reg hit;reg[1:0]hit_bank,victim;reg found_free;reg[1:0]oldest;
    integer i,j;
    assign transaction_busy=active;
    always @* begin
        hit=0;hit_bank=0;victim=front_bank+2'd1;found_free=0;oldest=0;
        for(i=0;i<4;i=i+1) begin
            if(ENABLE_CACHE!=0 && cat_ready && valid_slot[i] && slot_index[i]==request_index) begin hit=1;hit_bank=i;end
            if(i!=front_bank && !valid_slot[i] && !found_free) begin victim=i;found_free=1;end
        end
        if(!found_free) begin
            for(i=0;i<4;i=i+1) begin
                if(i!=front_bank && slot_age[i]>=oldest) begin victim=i;oldest=slot_age[i];end
            end
        end
    end
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            valid_slot<=0;active<=0;active_hit<=0;active_bank<=1;write_bank<=1;
            completion_seen<=0;completion_ok<=0;cancelled<=0;pending_error<=0;
            decode_go<=0;decode_index<=0;swap_only<=0;swap_bank<=0;
            frame_end<=0;frame_abort<=0;publication_pending<=0;
            published_valid<=0;published_done<=0;published_error<=0;published_index<=0;published_name<=0;
            cache_hits<=0;cache_misses<=0;
            for(j=0;j<4;j=j+1) begin slot_index[j]<=0;slot_name[j]<=0;slot_age[j]<=3;end
        end else begin
            decode_go<=0;swap_only<=0;frame_end<=0;frame_abort<=0;published_done<=0;
            if(!cat_ready) begin
                valid_slot<=0;
                for(j=0;j<4;j=j+1) slot_age[j]<=3;
                if(!active && !publication_pending) write_bank<=front_bank+2'd1;
            end
            // Boot autoload has no external request. Header arrival reserves its
            // already-selected non-front slot; normal misses reserve at request.
            if(frame_begin) begin
                completion_seen<=0;completion_ok<=0;
                if(ENABLE_CACHE!=0) valid_slot[write_bank]<=0;
                if(!active) begin
                    active<=1;active_hit<=0;active_bank<=write_bank;cancelled<=0;
                    cache_misses<=cache_misses+1'b1;
                end
            end
            if(frame_done) begin completion_seen<=1;completion_ok<=frame_ok;end
            if(cancel_go) begin
                cancelled<=1;
                if(publication_pending && !completion_seen && !frame_done) frame_abort<=1;
            end
            if(raw_done) begin
                publication_pending<=1;pending_error<=raw_error;
                if(raw_cancelled) cancelled<=1;
                if(!(completion_seen||frame_done)) begin
                    if(raw_error==0 && raw_valid && !cancelled && !cancel_go && !raw_cancelled) frame_end<=1;
                    else frame_abort<=1;
                end
            end
            if(publication_pending && completion_seen &&
               (!completion_ok || ENABLE_CACHE==0 || (front_valid && front_bank==active_bank))) begin
                publication_pending<=0;completion_seen<=0;active<=0;published_done<=1;
                published_valid<=front_valid;
                published_error<=completion_ok?0:((cancelled||cancel_go||raw_cancelled)?0:((pending_error!=0)?pending_error:2'd3));
                if(completion_ok) begin
                    if(active_hit && ENABLE_CACHE!=0) begin
                        published_index<=slot_index[front_bank];published_name<=slot_name[front_bank];
                    end else begin
                        published_index<=raw_index;published_name<=raw_name;
                        if(ENABLE_CACHE!=0 && cat_ready) begin
                            valid_slot[front_bank]<=1;slot_index[front_bank]<=raw_index;slot_name[front_bank]<=raw_name;
                        end
                    end
                    if(ENABLE_CACHE!=0 && cat_ready) begin
                        for(j=0;j<4;j=j+1) begin
                            if(j==front_bank) slot_age[j]<=0;
                            else if(valid_slot[j] && slot_age[j]<slot_age[front_bank]) begin
                                if(slot_age[j]!=3) slot_age[j]<=slot_age[j]+1'b1;
                            end
                        end
                    end
                end
                active_hit<=0;
            end
            if(request_go && !active && !publication_pending) begin
                active<=1;cancelled<=0;completion_seen<=0;completion_ok<=0;pending_error<=0;
                decode_index<=request_index;
                if(hit) begin
                    active_hit<=1;active_bank<=hit_bank;swap_bank<=hit_bank;swap_only<=1;
                    publication_pending<=1;cache_hits<=cache_hits+1'b1;
                end else begin
                    active_hit<=0;active_bank<=victim;write_bank<=victim;decode_go<=1;
                    cache_misses<=cache_misses+1'b1;
                end
            end
        end
    end
endmodule

// MEDIA_FRAME_CACHE_END

// MON_TRANSFORM_CTRL_BEGIN
// Only battle-long-key events update the requested monster orientation.
// The displayed orientation changes atomically at vertical blank. Preferences
// survive scene changes, while disabled-scene key events have no effect.
module mon_transform_ctrl (
    input wire clk, rst_n,
    input wire frame_tick,
    input wire battle_active,
    input wire rotate_step,
    input wire mirror_toggle,
    output reg [1:0] rotation,
    output reg mirror
);
    reg [1:0] requested_rotation;
    reg requested_mirror;
    reg [1:0] next_rotation;
    reg next_mirror;
    always @* begin
        next_rotation=requested_rotation;
        next_mirror=requested_mirror;
        if(battle_active) begin
            if(rotate_step) next_rotation=requested_rotation+2'd1;
            if(mirror_toggle) next_mirror=!requested_mirror;
        end
    end
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            requested_rotation<=0;requested_mirror<=0;
            rotation<=0;mirror<=0;
        end else begin
            requested_rotation<=next_rotation;
            requested_mirror<=next_mirror;
            // Use the newly requested value when a key and blank share a clock.
            if(frame_tick) begin rotation<=next_rotation;mirror<=next_mirror;end
        end
    end
endmodule
// MON_TRANSFORM_CTRL_END
