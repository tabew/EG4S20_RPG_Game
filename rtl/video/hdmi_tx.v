//=============================================================================
// hdmi_tx.v —— HDMI/DVI 发送端(3 数据通道 + 1 时钟通道)
//
// 分两个阶段推进(强烈建议按这个顺序调试):
//   【阶段1】参数 AUDIO_DI_EN = 0: 只发视频, 消隐期发控制字。这就是标准 DVI,
//            任何带 HDMI 输入的显示器都能点亮 —— 先把画面调出来。
//   【阶段2】AUDIO_DI_EN = 1: 在行消隐里插入数据岛(Data Island), 把音频
//            采样打包成 Audio Sample Packet 塞进去。
//            ⚠ 数据岛内 HB0/HB1/HB2 与 4 个 subpacket 的字段映射、
//              前导码(preamble)取值、BCH(64,56) 生成多项式,
//              必须对照 HDMI 1.4b 表 5-9 / 5-12 逐位校准, 本文件把
//              帧结构、调度时序和 BCH 计算框架搭好, 位域请按规范填。
//
// 时序安排(720p60, 行消隐 370 像素, 足够放下一个数据岛):
//   |<-- 1280 有效像素 -->|<-FP 110->|<-SYNC 40->|<-BP 220->|
//                                     ↑ hs_rise 后开始:
//   前导码 8px + guard 2px + 数据岛 32px + guard 2px = 44px
//   为稳妥起见, 数据岛放在行同步之后(避开 FP), 由状态机自行定位。
//=============================================================================
`timescale 1ns/1ps
module hdmi_tx #(
    parameter integer H_ACTIVE    = 1280,
    parameter integer H_TOTAL     = 1650,
    parameter integer AUDIO_DI_EN = 0
)(
    input  wire        clk_pix,
    input  wire        clk_p5x,
    input  wire        rst_pix_n,

    input  wire [15:0] rgb,
    input  wire        hs,
    input  wire        vs,
    input  wire        de,

    // 音频(已在本时钟域: 由 clk_sys 侧异步 FIFO 送过来)
    input  wire [55:0] aud_pkt,      // 56 位负载(24 头 + 4x8 子包)
    input  wire        aud_req,      // 有新包待发
    output reg         aud_got,      // 已取走该包(上层可继续投递)

    output wire [3:0]  hdmi_d_p,
    output wire [3:0]  hdmi_d_n,
    output wire        hdmi_clk_p,
    output wire        hdmi_clk_n
);

    //---------------------------------------------------------
    // BCH(64,56) 校验位
    //   这里给出可综合的串行除法框架, 生成多项式默认 x^8+x^4+x^3+x^2+1,
    //   ⚠ 请按 HDMI 1.4b 表 5-12 核对多项式与位序后再上板验证
    //---------------------------------------------------------
    function [7:0] bch8;
        input [55:0] din;
        integer i;
        reg [7:0] c;
        reg       fb;
        begin
            c = 8'h00;
            for (i = 55; i >= 0; i = i - 1) begin
                fb  = c[7] ^ din[i];
                c[7] = c[6];
                c[6] = c[5];
                c[5] = c[4] ^ fb;
                c[4] = c[3] ^ fb;
                c[3] = c[2] ^ fb;
                c[2] = c[1];
                c[1] = c[0];
                c[0] = fb;
            end
            bch8 = c;
        end
    endfunction

    //---------------------------------------------------------
    // 数据岛调度状态机
    //---------------------------------------------------------
    localparam [2:0] DI_OFF     = 3'd0,   // 控制期
                     DI_PRE     = 3'd1,   // 前导码 8px
                     DI_GB1     = 3'd2,   // 引导带 2px
                     DI_ISLAND  = 3'd3,   // 数据岛 32px
                     DI_GB2     = 3'd4;   // 引导带 2px

    reg [2:0]  di_st;
    reg [5:0]  di_cnt;
    reg [55:0] pkt_r;
    reg [7:0]  bch_r;
    reg        want_di;
    reg        de_d;
    // 数据岛必须放在"有效像素结束之后、行同步之前"的空档里
    wire       de_fall = de_d & ~de;

    wire [63:0] island = {pkt_r, bch_r};     // 56 + 8 = 64 位 = 32px x 2bit

    always @(posedge clk_pix or negedge rst_pix_n) begin
        if (!rst_pix_n) begin
            di_st   <= DI_OFF;
            di_cnt  <= 6'd0;
            pkt_r   <= 56'd0;
            bch_r   <= 8'd0;
            want_di <= 1'b0;
            aud_got <= 1'b0;
            de_d    <= 1'b0;
        end else begin
            aud_got <= 1'b0;
            de_d    <= de;
            // 有效像素结束时把音频包排进数据岛队列
            if (de_fall && AUDIO_DI_EN && aud_req && !want_di) begin
                pkt_r   <= aud_pkt;
                bch_r   <= bch8(aud_pkt);
                want_di <= 1'b1;
                aud_got <= 1'b1;
            end

            case (di_st)
            DI_OFF: begin
                if (!de && want_di) begin
                    di_st  <= DI_PRE;
                    di_cnt <= 6'd0;
                end
            end

            DI_PRE: begin
                if (di_cnt == 6'd7) begin
                    di_st  <= DI_GB1;
                    di_cnt <= 6'd0;
                end else di_cnt <= di_cnt + 6'd1;
            end

            DI_GB1: begin
                if (di_cnt == 6'd1) begin
                    di_st  <= DI_ISLAND;
                    di_cnt <= 6'd0;
                end else di_cnt <= di_cnt + 6'd1;
            end

            DI_ISLAND: begin
                if (di_cnt == 6'd31) begin
                    di_st  <= DI_GB2;
                    di_cnt <= 6'd0;
                end else di_cnt <= di_cnt + 6'd1;
            end

            DI_GB2: begin
                want_di <= 1'b0;
                if (di_cnt == 6'd1) begin
                    di_st  <= DI_OFF;
                    di_cnt <= 6'd0;
                end else di_cnt <= di_cnt + 6'd1;
            end

            default: di_st <= DI_OFF;
            endcase
        end
    end

    //---------------------------------------------------------
    // 每通道 10bit 编码前的 8bit + 2bit 控制选择
    //---------------------------------------------------------
    reg [7:0] ch0_8, ch1_8, ch2_8;
    reg [1:0] ch0_c, ch1_c, ch2_c;
    reg       d_en;               // 送编码器的 de(1=数据, 0=控制字)

    wire [5:0] pix_idx = di_cnt[5:0];

    always @(*) begin
        ch0_8 = 8'h00;
        ch1_8 = 8'h00;
        ch2_8 = 8'h00;
        ch0_c = {vs, hs};
        ch1_c = 2'b00;
        ch2_c = 2'b00;
        d_en  = de;

        if (de) begin
            ch0_8 = {rgb[15:11], rgb[10:8]};    // R
            ch1_8 = {rgb[7:2],   rgb[4:3]};     // G
            ch2_8 = {rgb[4:0],   rgb[7:5]};     // B
        end else if (AUDIO_DI_EN != 0) begin
            case (di_st)
            DI_PRE: begin
                d_en  = 1'b0;
                ch0_c = 2'b01;               // 音频采样包前导码
                ch1_c = 2'b00;
                ch2_c = 2'b00;
            end
            DI_GB1, DI_GB2: begin
                d_en  = 1'b0;
                ch0_c = 2'b10;               // 引导带 0b101100
                ch1_c = 2'b10;
                ch2_c = 2'b10;
            end
            DI_ISLAND: begin
                d_en  = 1'b1;
                ch0_8 = island[pix_idx*2 +: 8];     // ⚠ 位序按规范核对
                ch1_8 = 8'h00;
                ch2_8 = 8'h00;
            end
            default: begin
                d_en  = 1'b0;
            end
            endcase
        end
    end

    //---------------------------------------------------------
    // 三个数据通道 + 时钟通道
    //---------------------------------------------------------
    wire [9:0] q0, q1, q2;

    tmds_encoder u_enc0 (.clk(clk_pix), .rst_n(rst_pix_n), .din(ch0_8), .ctl(ch0_c), .de(d_en), .dout(q0));
    tmds_encoder u_enc1 (.clk(clk_pix), .rst_n(rst_pix_n), .din(ch1_8), .ctl(ch1_c), .de(d_en), .dout(q1));
    tmds_encoder u_enc2 (.clk(clk_pix), .rst_n(rst_pix_n), .din(ch2_8), .ctl(ch2_c), .de(d_en), .dout(q2));

    tmds_serdes u_ser0 (.clk_pix(clk_pix), .clk_p5x(clk_p5x), .rst_n(rst_pix_n),
                        .din(q0), .dout_p(hdmi_d_p[0]), .dout_n(hdmi_d_n[0]));
    tmds_serdes u_ser1 (.clk_pix(clk_pix), .clk_p5x(clk_p5x), .rst_n(rst_pix_n),
                        .din(q1), .dout_p(hdmi_d_p[1]), .dout_n(hdmi_d_n[1]));
    tmds_serdes u_ser2 (.clk_pix(clk_pix), .clk_p5x(clk_p5x), .rst_n(rst_pix_n),
                        .din(q2), .dout_p(hdmi_d_p[2]), .dout_n(hdmi_d_n[2]));

    // 时钟通道: 固定 10bit 图形 1111100000，串行后就是 1/10 频率 = 像素时钟
    tmds_serdes u_serclk (.clk_pix(clk_pix), .clk_p5x(clk_p5x), .rst_n(rst_pix_n),
                          .din(10'b1111100000),
                          .dout_p(hdmi_clk_p), .dout_n(hdmi_clk_n));

    assign hdmi_d_p[3] = 1'b0;
    assign hdmi_d_n[3] = 1'b1;

endmodule
