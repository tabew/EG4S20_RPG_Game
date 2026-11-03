//=============================================================================
// hdmi_tx.v —— HDMI 48kHz LPCM + video, original Anlogic LVDS serializers
// AUDIO_DI_EN=1: open packet/TMDS encoder + original protected serializers.
// AUDIO_DI_EN=0: original protected DVITransmitter fallback.
// The serializer interfaces are verified by TD metadata; board audio is untested.
// Historical serializer/DVI bring-up notes follow:
//
// ★ 历史教训：手写 TMDS 编码 + EG_LOGIC_ODDR 串化在 25/125MHz(640x480) 下
//   能出画面，但升到 40/200MHz(800x600) 后花屏（竖条纹/行错位/颜色错乱），
//   色条诊断模式同样花屏 → 排除游戏逻辑，锁定串化链路。
//
//   本版改用安路官方加密 IP（来自官方 HDMI 参考工程，同芯片 EG4S20BG256、
//   该工程以 537.5MHz 串行时钟验证过）：
//     DVITransmitter（加密 VHDL）内部含 TMDSEncoder x3 + SerializerN_1_lvds x4，
//     只需 24bit RGB + HS/VS/DE + PCLK + PCLK_X5。
//
//   参考工程 ref_hdmi/HDMII 已验证：
//     - Verilog 顶层直接例化 VHDL 实体（混合语言编译可用）
//     - RST_I 为【高有效】复位
//     - FAMILY 泛型默认即 "EG4"
//
//   引脚仍用本底板实测映射（640x480 曾验证通过）：
//     hdmi_clk_p = P1, hdmi_d_p[0] = N1, [1] = P4, [2] = J3 (LVDS33)
//=============================================================================
`timescale 1ns/1ps
module hdmi_tx #(
    parameter integer H_ACTIVE    = 800,
    parameter integer H_TOTAL     = 1056,
    parameter integer AUDIO_DI_EN = 0,      // 1: HDMI with 48kHz test tone; 0: legacy DVI
    parameter integer PIXEL_HZ    = 40000000, // actual clk_pix rate; controls sample divider/ACR
    parameter integer VIDEO_ID    = 0        // AVI VIC: 0=custom/IT, 1=640x480p60
)(
    input  wire        clk_pix,
    input  wire        clk_p5x,
    input  wire        rst_pix_n,           // 低有效

    input  wire [15:0] rgb,                 // legacy RGB565 input
    input  wire [23:0] rgb_full,            // optional full-depth RGB888 input
    input  wire        full_rgb_en,         // 1 selects rgb_full; omitted port keeps RGB565
    input  wire        mute,                // 1 silences newly generated test-tone samples
    input  wire        hs,
    input  wire        vs,
    input  wire        de,

    // Legacy packet input retained; the HDMI path generates its own 48kHz tone.
    input  wire [55:0] aud_pkt,
    input  wire        aud_req,
    output wire        aud_got,

    // 真差分输出: 只引出 P 端, N 端由 TD 根据 LVDS 约束自动配对
    output wire [2:0]  hdmi_d_p,
    output wire        hdmi_clk_p
);

    assign aud_got = 1'b0;

    //---------------------------------------------------------
    // RGB565 -> RGB888（低位用自身最高位复制, 与原灰度校准一致）
    //---------------------------------------------------------
    wire [23:0] rgb565_expanded = {
        rgb[15:11], rgb[15:13],     // R: 5bit + 3bit 复制
        rgb[10:5],  rgb[10:9],      // G: 6bit + 2bit 复制
        rgb[4:0],   rgb[4:2]        // B: 5bit + 3bit 复制
    };
    wire [23:0] rgb888 = (full_rgb_en === 1'b1) ? rgb_full : rgb565_expanded;

    generate
        if (AUDIO_DI_EN != 0) begin : g_hdmi_audio
            wire [9:0] tmds0, tmds1, tmds2;
            wire tone_tick, audio_overflow;
            hdmi_audio_encoder #(.H_ACTIVE(H_ACTIVE),.H_TOTAL(H_TOTAL),
                .PIXEL_HZ(PIXEL_HZ),.VIDEO_ID(VIDEO_ID)) u_encoder (
                .clk_pix(clk_pix),.rst_n(rst_pix_n),.rgb(rgb888),
                .hs(hs),.vs(vs),.de(de),.mute(mute === 1'b1),
                .tmds0(tmds0),.tmds1(tmds1),.tmds2(tmds2),
                .sample_tick(tone_tick),.overflow(audio_overflow),
                .mode_out(),.hs_out(),.vs_out(),.de_out(),.rgb_out()
            );
            // These are the original protected Anlogic serializer entities.
            // Ports/clock word verified from TD's original DVITransmitter model:
            // sim/hardware_reference_probe/DVI_serializer_public_pins.txt.
            // No reset port exists on these entities. SCLK=5*PCLK, DDR.
            Serial_N_1_lvds_dat u_blue_serializer (
                .DP_I(tmds0),.PCLK(clk_pix),.SCLK(clk_p5x),.DSP_O(hdmi_d_p[0])
            );
            Serial_N_1_lvds_dat u_green_serializer (
                .DP_I(tmds1),.PCLK(clk_pix),.SCLK(clk_p5x),.DSP_O(hdmi_d_p[1])
            );
            Serial_N_1_lvds_dat u_red_serializer (
                .DP_I(tmds2),.PCLK(clk_pix),.SCLK(clk_p5x),.DSP_O(hdmi_d_p[2])
            );
            Serial_N_1_lvds u_clock_serializer (
                .DP_I(10'b0000011111),.PCLK(clk_pix),.SCLK(clk_p5x),.DSP_O(hdmi_clk_p)
            );
        end else begin : g_legacy_dvi
            DVITransmitter #(.FAMILY("EG4")) u_dvi (
                .RED_I(rgb888[23:16]),.GREEN_I(rgb888[15:8]),.BLUE_I(rgb888[7:0]),
                .HS_I(hs),.VS_I(vs),.VDE_I(de),.RST_I(~rst_pix_n),
                .PCLK_I(clk_pix),.PCLK_X5_I(clk_p5x),
                .TMDS_TX_CLK_P(hdmi_clk_p),.TMDS_TX_2_P(hdmi_d_p[2]),
                .TMDS_TX_1_P(hdmi_d_p[1]),.TMDS_TX_0_P(hdmi_d_p[0])
            );
        end
    endgenerate

endmodule

// HDMI packet/audio backend, parameterized pixel clock, external HS/VS/DE timing.
// 640x480p60 profile: H_ACTIVE=640,H_TOTAL=800,PIXEL_HZ=25200000,VIDEO_ID=1.
// Timing/PLL generation is external; VIDEO_ID must describe the actual input.
// Packet formats, BCH and channel coding adapted from hdl-util/hdmi,
// Copyright Sameer Puri and contributors, MIT license; see sim/hdmi_audio/LICENSE-MIT.
// All logic is in clk_pix. The ten pixel delay provides eight preamble + two
// guard pixels before each DE rising edge. Channel encoding adds one register.
module hdmi_audio_encoder #(
    parameter integer H_ACTIVE=800, H_TOTAL=1056,
    parameter integer PIXEL_HZ=40000000,
    parameter integer VIDEO_ID=0
)(
    input wire clk_pix, rst_n,
    input wire [23:0] rgb,
    input wire hs, vs, de, mute,
    output wire [9:0] tmds0, tmds1, tmds2,
    output wire sample_tick,
    output reg overflow,
    output reg [2:0] mode_out,
    output reg hs_out, vs_out, de_out,
    output reg [23:0] rgb_out
);
    reg [23:0] pixels[0:9];
    reg [9:0] hp, vp, dp;
    reg prev_de;
    reg [11:0] xpos;
    integer j;
    wire video_guard = !dp[9] && (dp[8] || dp[7]);
    wire video_pre = !dp[9] && !video_guard && ((|dp[6:0]) || de);
    wire island_pre = xpos >= H_ACTIVE+4 && xpos < H_ACTIVE+12;
    wire island_guard = (xpos >= H_ACTIVE+12 && xpos < H_ACTIVE+14) ||
                        (xpos >= H_ACTIVE+142 && xpos < H_ACTIVE+144);
    wire island_data = xpos >= H_ACTIVE+14 && xpos < H_ACTIVE+142;
    wire [11:0] island_offset = xpos-(H_ACTIVE+14);
    wire [1:0] slot = island_offset[6:5];
    wire [4:0] bitpos = island_offset[4:0];
    reg [2:0] mode;
    always @* begin
        if (dp[9]) mode=1;
        else if (video_guard) mode=2;
        else if (island_guard) mode=4;
        else if (island_data) mode=3;
        else mode=0;
    end
    always @(posedge clk_pix or negedge rst_n) begin
        if (!rst_n) begin
            hp<=0; vp<=0; dp<=0; prev_de<=0; xpos<=0;
            mode_out<=0; hs_out<=0; vs_out<=0; de_out<=0; rgb_out<=0;
            for(j=0;j<10;j=j+1) pixels[j]<=0;
        end else begin
            hp<={hp[8:0],hs}; vp<={vp[8:0],vs}; dp<={dp[8:0],de};
            pixels[0]<=rgb;
            for(j=1;j<10;j=j+1) pixels[j]<=pixels[j-1];
            prev_de<=dp[9];
            if (dp[9] && !prev_de) xpos<=1;
            else if (!dp[9] && prev_de) xpos<=H_ACTIVE+1;
            else xpos <= xpos==H_TOTAL-1 ? 0 : xpos+1'b1;
            mode_out<=mode; hs_out<=hp[9]; vs_out<=vp[9]; de_out<=dp[9]; rgb_out<=pixels[9];
        end
    end
    // 48 kHz divider: 833/834 clocks at 40M; exactly 525 clocks at 25.2M.
    reg [31:0] sample_acc;
    assign sample_tick = sample_acc >= PIXEL_HZ-48000;
    reg [5:0] tone_phase;
    reg signed [15:0] tone;
    always @* begin
        case(tone_phase)
            6'd0: tone = 16'sd0;
            6'd1: tone = 16'sd1069;
            6'd2: tone = 16'sd2120;
            6'd3: tone = 16'sd3135;
            6'd4: tone = 16'sd4096;
            6'd5: tone = 16'sd4987;
            6'd6: tone = 16'sd5793;
            6'd7: tone = 16'sd6499;
            6'd8: tone = 16'sd7094;
            6'd9: tone = 16'sd7568;
            6'd10: tone = 16'sd7913;
            6'd11: tone = 16'sd8122;
            6'd12: tone = 16'sd8192;
            6'd13: tone = 16'sd8122;
            6'd14: tone = 16'sd7913;
            6'd15: tone = 16'sd7568;
            6'd16: tone = 16'sd7094;
            6'd17: tone = 16'sd6499;
            6'd18: tone = 16'sd5793;
            6'd19: tone = 16'sd4987;
            6'd20: tone = 16'sd4096;
            6'd21: tone = 16'sd3135;
            6'd22: tone = 16'sd2120;
            6'd23: tone = 16'sd1069;
            6'd24: tone = 16'sd0;
            6'd25: tone = -16'sd1069;
            6'd26: tone = -16'sd2120;
            6'd27: tone = -16'sd3135;
            6'd28: tone = -16'sd4096;
            6'd29: tone = -16'sd4987;
            6'd30: tone = -16'sd5793;
            6'd31: tone = -16'sd6499;
            6'd32: tone = -16'sd7094;
            6'd33: tone = -16'sd7568;
            6'd34: tone = -16'sd7913;
            6'd35: tone = -16'sd8122;
            6'd36: tone = -16'sd8192;
            6'd37: tone = -16'sd8122;
            6'd38: tone = -16'sd7913;
            6'd39: tone = -16'sd7568;
            6'd40: tone = -16'sd7094;
            6'd41: tone = -16'sd6499;
            6'd42: tone = -16'sd5793;
            6'd43: tone = -16'sd4987;
            6'd44: tone = -16'sd4096;
            6'd45: tone = -16'sd3135;
            6'd46: tone = -16'sd2120;
            6'd47: tone = -16'sd1069;
            default: tone=0;
        endcase
    end
    reg [23:0] fifo[0:15];
    reg [3:0] wrptr, rdptr;
    reg [4:0] count;
    wire take = xpos==H_ACTIVE+1;
    wire [2:0] take_count = count>=4 ? 3'd4 : count[2:0];
    reg [23:0] samples[0:3];
    reg [3:0] present;
    reg [7:0] frame_index, packet_frame;
    integer n;
    always @(posedge clk_pix or negedge rst_n) begin
        if (!rst_n) begin
            sample_acc<=0; tone_phase<=0; wrptr<=0; rdptr<=0; count<=0;
            overflow<=0; present<=0; frame_index<=0; packet_frame<=0;
            for(n=0;n<4;n=n+1) samples[n]<=0;
        end else begin
            sample_acc<=sample_tick ? sample_acc+48000-PIXEL_HZ : sample_acc+48000;
            if(sample_tick) begin
                tone_phase<=tone_phase==47 ? 0 : tone_phase+1'b1;
                if(count<16) begin
                    fifo[wrptr] <= mute ? 24'd0 : {tone,8'd0};
                    wrptr<=wrptr+1'b1;
                end else overflow<=1;
            end
            if(take) begin
                packet_frame<=frame_index;
                frame_index<=frame_index+take_count>=192 ? frame_index+take_count-192 : frame_index+take_count;
                for(n=0;n<4;n=n+1) begin
                    present[n]<=n<take_count;
                    samples[n]<=n<take_count ? fifo[(rdptr+n)&15] : 24'd0;
                end
                rdptr<=rdptr+take_count;
            end
            case({sample_tick && count<16,take})
                2'b10: count<=count+1'b1;
                2'b01: count<=count-take_count;
                2'b11: count<=count+1'b1-take_count;
                default: count<=count;
            endcase
        end
    end
    reg [23:0] header;
    reg [55:0] payload[0:3];
    reg [7:0] fi;
    reg cl,cr,pl,pr;
    // IEC60958: consumer LPCM, copyright not asserted, 48kHz, 24-bit word.
    localparam [191:0] CS_LEFT  = (192'hb<<32) | (192'h2<<24) | (192'h1<<20) | 192'h4;
    localparam [191:0] CS_RIGHT = (192'hb<<32) | (192'h2<<24) | (192'h2<<20) | 192'h4;
    // N=6144 gives exact 48 kHz when CTS=f_pixel/1000 (40M or 25.2M).
    localparam [19:0] ACR_N=6144, ACR_CTS=PIXEL_HZ/1000;
    localparam [7:0] AVI_VIC = VIDEO_ID;
    localparam [7:0] AVI_CHECKSUM = 8'h5f - AVI_VIC;
    integer k;
    always @* begin
        header=0; fi=0; cl=0; cr=0; pl=0; pr=0;
        for(k=0;k<4;k=k+1) payload[k]=0;
        case(slot)
            0: begin
                header=24'h000002;
                header[11:8]=present;
                for(k=0;k<4;k=k+1) begin
                    fi=packet_frame+k>=192 ? packet_frame+k-192 : packet_frame+k;
                    header[20+k]=present[k] && fi==0;
                    cl=CS_LEFT[fi]; cr=CS_RIGHT[fi];
                    pl=^{cl,samples[k]}; pr=^{cr,samples[k]};
                    if(present[k]) payload[k]={{pr,cr,2'b00,pl,cl,2'b00},samples[k],samples[k]};
                end
            end
            1: begin
                header=24'h000001;
                for(k=0;k<4;k=k+1)
                    payload[k]={ACR_N[7:0],ACR_N[15:8],4'b0,ACR_N[19:16],ACR_CTS[7:0],ACR_CTS[15:8],4'b0,ACR_CTS[19:16],8'b0};
            end
            2: begin
                // AVI: RGB, selected VIC, full quantization, no scaling.
                header=24'h0d0282;
                payload[0]={8'h00,8'h00,AVI_VIC,8'h08,8'h08,8'h00,AVI_CHECKSUM};
            end
            3: begin
                // Audio InfoFrame: two channels; frequency/size refer to stream.
                header=24'h0a0184;
                payload[0]=56'h00000000000170;
            end
        endcase
    end
    function [7:0] ecc_next;
        input [7:0] ecc;
        input b;
        begin ecc_next=(ecc>>1)^((ecc[0]^b)?8'h83:8'h00); end
    endfunction
    reg [7:0] parity[0:4];
    wire [31:0] hb={parity[4],header};
    wire [63:0] sb0={parity[0],payload[0]}, sb1={parity[1],payload[1]};
    wire [63:0] sb2={parity[2],payload[2]}, sb3={parity[3],payload[3]};
    wire [5:0] bp0={bitpos,1'b0}, bp1={bitpos,1'b1};
    wire [3:0] nib1={sb3[bp0],sb2[bp0],sb1[bp0],sb0[bp0]};
    wire [3:0] nib2={sb3[bp1],sb2[bp1],sb1[bp1],sb0[bp1]};
    integer e;
    always @(posedge clk_pix or negedge rst_n) begin
        if(!rst_n) for(e=0;e<5;e=e+1) parity[e]<=0;
        else if(!island_data || bitpos==31) for(e=0;e<5;e=e+1) parity[e]<=0;
        else begin
            if(bitpos<24) parity[4]<=ecc_next(parity[4],header[bitpos]);
            if(bitpos<28) for(e=0;e<4;e=e+1)
                parity[e]<=ecc_next(ecc_next(parity[e],payload[e][bp0]),payload[e][bp1]);
        end
    end
    hdmi_audio_channel #(.CN(0)) ch0(.clk_pixel(clk_pix),.rst_n(rst_n),.video_data(pixels[9][7:0]),
        .data_island_data({1'b1,hb[bitpos],vp[9],hp[9]}),.control_data({vp[9],hp[9]}),.mode(mode),.tmds(tmds0));
    hdmi_audio_channel #(.CN(1)) ch1(.clk_pixel(clk_pix),.rst_n(rst_n),.video_data(pixels[9][15:8]),
        .data_island_data(nib1),.control_data({1'b0,video_pre||island_pre}),.mode(mode),.tmds(tmds1));
    hdmi_audio_channel #(.CN(2)) ch2(.clk_pixel(clk_pix),.rst_n(rst_n),.video_data(pixels[9][23:16]),
        .data_island_data(nib2),.control_data({1'b0,island_pre}),.mode(mode),.tmds(tmds2));
endmodule

// Implementation of HDMI Spec v1.4a Section 5.4: Encoding, Section 5.2.2.1: Video Guard Band, Section 5.2.3.3: Data Island Guard Bands.
// By Sameer Puri https://github.com/sameer

module hdmi_audio_channel
#(
    // TMDS Channel number.
    // There are only 3 possible channel numbers in HDMI 1.4a: 0, 1, 2.
    parameter integer CN = 0
)
(
    input wire clk_pixel,
    input wire rst_n,
    input wire [7:0] video_data,
    input wire [3:0] data_island_data,
    input wire [1:0] control_data,
    input wire [2:0] mode,  // Mode select (0 = control, 1 = video, 2 = video guard, 3 = island, 4 = island guard)
    output reg [9:0] tmds
);

// See Section 5.4.4.1
// Below is a direct implementation of Figure 5-7, using the same variable names.

reg signed [4:0] acc;

reg [8:0] q_m;
reg [9:0] q_out;
wire [9:0] video_coding;
assign video_coding = q_out;

reg [3:0] N1D;
reg signed [4:0] N1q_m07;
reg signed [4:0] N0q_m07;
always @*
begin
    N1D = video_data[0] + video_data[1] + video_data[2] + video_data[3] + video_data[4] + video_data[5] + video_data[6] + video_data[7];
    case(q_m[0] + q_m[1] + q_m[2] + q_m[3] + q_m[4] + q_m[5] + q_m[6] + q_m[7])
        4'b0000: N1q_m07 = 5'sd0;
        4'b0001: N1q_m07 = 5'sd1;
        4'b0010: N1q_m07 = 5'sd2;
        4'b0011: N1q_m07 = 5'sd3;
        4'b0100: N1q_m07 = 5'sd4;
        4'b0101: N1q_m07 = 5'sd5;
        4'b0110: N1q_m07 = 5'sd6;
        4'b0111: N1q_m07 = 5'sd7;
        4'b1000: N1q_m07 = 5'sd8;
        default: N1q_m07 = 5'sd0;
    endcase
    N0q_m07 = 5'sd8 - N1q_m07;
end

reg signed [4:0] acc_add;

integer i;

always @*
begin
    if (N1D > 4'd4 || (N1D == 4'd4 && video_data[0] == 1'd0))
    begin
        q_m[0] = video_data[0];
        for(i = 0; i < 7; i = i + 1)
            q_m[i + 1] = q_m[i] ~^ video_data[i + 1];
        q_m[8] = 1'b0;
    end
    else
    begin
        q_m[0] = video_data[0];
        for(i = 0; i < 7; i = i + 1)
            q_m[i + 1] = q_m[i] ^ video_data[i + 1];
        q_m[8] = 1'b1;
    end
    if (acc == 5'sd0 || (N1q_m07 == N0q_m07))
    begin
        if (q_m[8])
        begin
            acc_add = N1q_m07 - N0q_m07;
            q_out = {~q_m[8], q_m[8], q_m[7:0]};
        end
        else
        begin
            acc_add = N0q_m07 - N1q_m07;
            q_out = {~q_m[8], q_m[8], ~q_m[7:0]};
        end
    end
    else
    begin
        if ((acc > 5'sd0 && N1q_m07 > N0q_m07) || (acc < 5'sd0 && N1q_m07 < N0q_m07))
        begin
            q_out = {1'b1, q_m[8], ~q_m[7:0]};
            acc_add = (N0q_m07 - N1q_m07) + (q_m[8] ? 5'sd2 : 5'sd0);
        end
        else
        begin
            q_out = {1'b0, q_m[8], q_m[7:0]};
            acc_add = (N1q_m07 - N0q_m07) - (~q_m[8] ? 5'sd2 : 5'sd0);
        end
    end
end

always @(posedge clk_pixel or negedge rst_n)
    if (!rst_n) acc <= 0; else acc <= mode != 3'd1 ? 5'sd0 : acc + acc_add;

// See Section 5.4.2
reg [9:0] control_coding;
always @*
begin
    case(control_data)
        2'b00: control_coding = 10'b1101010100;
        2'b01: control_coding = 10'b0010101011;
        2'b10: control_coding = 10'b0101010100;
        2'b11: control_coding = 10'b1010101011;
    endcase
end

// See Section 5.4.3
reg [9:0] terc4_coding;
always @*
begin
    case(data_island_data)
        4'b0000 : terc4_coding = 10'b1010011100;
        4'b0001 : terc4_coding = 10'b1001100011;
        4'b0010 : terc4_coding = 10'b1011100100;
        4'b0011 : terc4_coding = 10'b1011100010;
        4'b0100 : terc4_coding = 10'b0101110001;
        4'b0101 : terc4_coding = 10'b0100011110;
        4'b0110 : terc4_coding = 10'b0110001110;
        4'b0111 : terc4_coding = 10'b0100111100;
        4'b1000 : terc4_coding = 10'b1011001100;
        4'b1001 : terc4_coding = 10'b0100111001;
        4'b1010 : terc4_coding = 10'b0110011100;
        4'b1011 : terc4_coding = 10'b1011000110;
        4'b1100 : terc4_coding = 10'b1010001110;
        4'b1101 : terc4_coding = 10'b1001110001;
        4'b1110 : terc4_coding = 10'b0101100011;
        4'b1111 : terc4_coding = 10'b1011000011;
    endcase
end

// See Section 5.2.2.1
wire [9:0] video_guard_band;
generate
    if (CN == 0 || CN == 2)
        assign video_guard_band = 10'b1011001100;
    else
        assign video_guard_band = 10'b0100110011;
endgenerate

// See Section 5.2.3.3
wire [9:0] data_guard_band;
generate
    if (CN == 1 || CN == 2)
        assign data_guard_band = 10'b0100110011;
    else
        assign data_guard_band = control_data == 2'b00 ? 10'b1010001110
            : control_data == 2'b01 ? 10'b1001110001
            : control_data == 2'b10 ? 10'b0101100011
            : 10'b1011000011;
endgenerate

// Apply selected mode.
always @(posedge clk_pixel or negedge rst_n)
begin
    if (!rst_n) tmds <= 10'b1101010100;
    else case (mode)
        3'd0: tmds <= control_coding;
        3'd1: tmds <= video_coding;
        3'd2: tmds <= video_guard_band;
        3'd3: tmds <= terc4_coding;
        3'd4: tmds <= data_guard_band;
    endcase
end

endmodule
