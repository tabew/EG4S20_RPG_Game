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
    parameter integer AUDIO_DI_EN = 0,      // 1: HDMI with 48kHz LPCM; 0: legacy DVI
    parameter integer AUDIO_PCM_EN = 0,     // 1: external mono PCM; 0: diagnostic 1kHz tone
    parameter integer PIXEL_HZ    = 40000000, // actual clk_pix rate; controls sample divider/ACR
    parameter integer VIDEO_ID    = 0        // AVI VIC: 0=custom/IT, 1=640x480p60
)(
    input  wire        clk_pix,
    input  wire        clk_p5x,
    input  wire        rst_pix_n,           // 低有效

    input  wire [15:0] rgb,                 // legacy RGB565 input
    input  wire [23:0] rgb_full,            // optional full-depth RGB888 input
    input  wire        full_rgb_en,         // 1 selects rgb_full; omitted port keeps RGB565
    input  wire        mute,                // 1 silences newly captured audio samples
    input  wire signed [15:0] pcm_sample,    // held clk_pix-domain mono PCM, sampled at 48kHz
    input  wire        hs,
    input  wire        vs,
    input  wire        de,

    // Legacy packet inputs remain inactive; HDMI captures PCM or generates a diagnostic tone.
    input  wire [55:0] aud_pkt,
    input  wire        aud_req,
    output wire        aud_got,
    output wire        audio_sample_tick, // exact encoder48kHz capture enable, clk_pix

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
            assign audio_sample_tick = tone_tick;
            hdmi_audio_encoder #(.H_ACTIVE(H_ACTIVE),.H_TOTAL(H_TOTAL),
                .PIXEL_HZ(PIXEL_HZ),.VIDEO_ID(VIDEO_ID),
                .PCM_INPUT_EN(AUDIO_PCM_EN)) u_encoder (
                .clk_pix(clk_pix),.rst_n(rst_pix_n),.rgb(rgb888),
                .hs(hs),.vs(vs),.de(de),.mute(mute === 1'b1),.pcm_sample(pcm_sample),
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
            assign audio_sample_tick = 1'b0;
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
    parameter integer VIDEO_ID=0,
    parameter integer PCM_INPUT_EN=0 // 1: external held PCM; 0: diagnostic 1kHz tone
)(
    input wire clk_pix, rst_n,
    input wire [23:0] rgb,
    input wire hs, vs, de, mute,
    input wire signed [15:0] pcm_sample,
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
    // Capture held PCM at 48kHz without changing the source synth's own rate.
    // Constant PCM_INPUT_EN lets synthesis remove the diagnostic tone logic.
    wire signed [15:0] audio_sample = PCM_INPUT_EN != 0 ? pcm_sample : tone;
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
                    fifo[wrptr] <= mute ? 24'd0 : {audio_sample,8'd0};
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


// 256 real PCM samples, 48 kHz: 187.5 Hz/bin, rectangular window.
// Eight normalized radix-2 DIT stages, single scheduled signed 18x16 product.
// Capture and work RAMs have synchronous reads and no reset loops. No audio
// backpressure: overflow is sticky diagnostics only. Two capture banks allow
// the previous block to be copied while the next is continuously recorded.
`timescale 1ns/1ps
// STAGED ONLY. NOT IN THE NATIVE PROJECT. Compile without hdmi_tx.v.
module audio_spectrum_fft (
    input wire clk,
    input wire rst_n,
    input wire sample_tick,
    input wire signed [15:0] pcm_sample,
    output reg [63:0] levels,
    output reg frame_valid,
    output reg overflow
);
    localparam IDLE=0, COPY_READ=1, COPY_WRITE=2,
        READ_A=3, LATCH_A=4, READ_B=5, LATCH_B=6,
        MUL0=7, MUL1=8, MUL2=9, MUL3=10, MUL4=11,
        WRITE_A=12, WRITE_B=13, SCAN_READ=14, SCAN_BIN=15,
        LEVEL_BAND=16, PUBLISH=17;
    reg [4:0] state;
    reg [15:0] capture_mem [0:511];
    reg [35:0] work_mem [0:255];
    reg [15:0] capture_q;
    reg [35:0] work_q;
    reg capture_bank, ready_bank, copy_bank, block_ready;
    reg [7:0] capture_index, copy_index;
    reg [2:0] stage;
    reg [7:0] half_span, group_base, butterfly_j;
    wire [8:0] next_group = {1'b0,group_base}+{half_span,1'b0};
    wire [7:0] address_a = group_base + butterfly_j;
    wire [7:0] address_b = address_a + half_span;
    reg [7:0] scan_index;
    reg [2:0] publish_band;
    reg [63:0] pending_levels;
    reg [18:0] band_peak [0:7];
    reg signed [17:0] ar, ai, br, bi;
    reg signed [15:0] wr, wi;
    reg signed [17:0] mul_a;
    reg signed [15:0] mul_b;
    reg signed [33:0] product;
    reg signed [34:0] product_acc;
    reg signed [18:0] tr, ti;
    wire signed [34:0] product_ext = {product[33],product};
    wire signed [19:0] ar_ext = {{2{ar[17]}},ar};
    wire signed [19:0] ai_ext = {{2{ai[17]}},ai};
    wire signed [19:0] tr_ext = {tr[18],tr};
    wire signed [19:0] ti_ext = {ti[18],ti};
    wire signed [19:0] sum_re = (ar_ext+tr_ext) >>> 1;
    wire signed [19:0] sum_im = (ai_ext+ti_ext) >>> 1;
    wire signed [19:0] dif_re = (ar_ext-tr_ext) >>> 1;
    wire signed [19:0] dif_im = (ai_ext-ti_ext) >>> 1;
    wire [17:0] abs_re = work_q[35] ? (~work_q[35:18]+18'd1) : work_q[35:18];
    wire [17:0] abs_im = work_q[17] ? (~work_q[17:0]+18'd1) : work_q[17:0];
    wire [18:0] magnitude = {1'b0,abs_re}+{1'b0,abs_im};
    wire [2:0] scan_band = (scan_index==1) ? 0 :
        (scan_index==2) ? 1 : (scan_index<=4) ? 2 :
        (scan_index<=8) ? 3 : (scan_index<=16) ? 4 :
        (scan_index<=32) ? 5 : (scan_index<=64) ? 6 : 7;
    wire [7:0] target_level = compress(band_peak[publish_band]);
    wire [7:0] old_level = levels >> {publish_band,3'b000};
    wire [7:0] falling_level = (old_level>8'd2) ? old_level-8'd2 : 8'd0;
    wire [7:0] next_level = (target_level>=falling_level) ? target_level : falling_level;
    integer reset_band;

    function [7:0] bit_reverse;
        input [7:0] value;
        begin bit_reverse={value[0],value[1],value[2],value[3],value[4],value[5],value[6],value[7]}; end
    endfunction
    function [31:0] twiddle;
        input [6:0] index;
        begin case(index)
            7'd0: twiddle = 32'h7fff0000;
            7'd1: twiddle = 32'h7ff6fcdc;
            7'd2: twiddle = 32'h7fd9f9b8;
            7'd3: twiddle = 32'h7fa7f695;
            7'd4: twiddle = 32'h7f62f374;
            7'd5: twiddle = 32'h7f0af055;
            7'd6: twiddle = 32'h7e9ded38;
            7'd7: twiddle = 32'h7e1eea1e;
            7'd8: twiddle = 32'h7d8ae707;
            7'd9: twiddle = 32'h7ce4e3f4;
            7'd10: twiddle = 32'h7c2ae0e6;
            7'd11: twiddle = 32'h7b5ddddc;
            7'd12: twiddle = 32'h7a7ddad8;
            7'd13: twiddle = 32'h798ad7d9;
            7'd14: twiddle = 32'h7885d4e1;
            7'd15: twiddle = 32'h776cd1ef;
            7'd16: twiddle = 32'h7642cf04;
            7'd17: twiddle = 32'h7505cc21;
            7'd18: twiddle = 32'h73b6c946;
            7'd19: twiddle = 32'h7255c673;
            7'd20: twiddle = 32'h70e3c3a9;
            7'd21: twiddle = 32'h6f5fc0e9;
            7'd22: twiddle = 32'h6dcabe32;
            7'd23: twiddle = 32'h6c24bb85;
            7'd24: twiddle = 32'h6a6eb8e3;
            7'd25: twiddle = 32'h68a7b64c;
            7'd26: twiddle = 32'h66d0b3c0;
            7'd27: twiddle = 32'h64e9b140;
            7'd28: twiddle = 32'h62f2aecc;
            7'd29: twiddle = 32'h60ecac65;
            7'd30: twiddle = 32'h5ed7aa0a;
            7'd31: twiddle = 32'h5cb4a7bd;
            7'd32: twiddle = 32'h5a82a57e;
            7'd33: twiddle = 32'h5843a34c;
            7'd34: twiddle = 32'h55f6a129;
            7'd35: twiddle = 32'h539b9f14;
            7'd36: twiddle = 32'h51349d0e;
            7'd37: twiddle = 32'h4ec09b17;
            7'd38: twiddle = 32'h4c409930;
            7'd39: twiddle = 32'h49b49759;
            7'd40: twiddle = 32'h471d9592;
            7'd41: twiddle = 32'h447b93dc;
            7'd42: twiddle = 32'h41ce9236;
            7'd43: twiddle = 32'h3f1790a1;
            7'd44: twiddle = 32'h3c578f1d;
            7'd45: twiddle = 32'h398d8dab;
            7'd46: twiddle = 32'h36ba8c4a;
            7'd47: twiddle = 32'h33df8afb;
            7'd48: twiddle = 32'h30fc89be;
            7'd49: twiddle = 32'h2e118894;
            7'd50: twiddle = 32'h2b1f877b;
            7'd51: twiddle = 32'h28278676;
            7'd52: twiddle = 32'h25288583;
            7'd53: twiddle = 32'h222484a3;
            7'd54: twiddle = 32'h1f1a83d6;
            7'd55: twiddle = 32'h1c0c831c;
            7'd56: twiddle = 32'h18f98276;
            7'd57: twiddle = 32'h15e281e2;
            7'd58: twiddle = 32'h12c88163;
            7'd59: twiddle = 32'h0fab80f6;
            7'd60: twiddle = 32'h0c8c809e;
            7'd61: twiddle = 32'h096b8059;
            7'd62: twiddle = 32'h06488027;
            7'd63: twiddle = 32'h0324800a;
            7'd64: twiddle = 32'h00008000;
            7'd65: twiddle = 32'hfcdc800a;
            7'd66: twiddle = 32'hf9b88027;
            7'd67: twiddle = 32'hf6958059;
            7'd68: twiddle = 32'hf374809e;
            7'd69: twiddle = 32'hf05580f6;
            7'd70: twiddle = 32'hed388163;
            7'd71: twiddle = 32'hea1e81e2;
            7'd72: twiddle = 32'he7078276;
            7'd73: twiddle = 32'he3f4831c;
            7'd74: twiddle = 32'he0e683d6;
            7'd75: twiddle = 32'hdddc84a3;
            7'd76: twiddle = 32'hdad88583;
            7'd77: twiddle = 32'hd7d98676;
            7'd78: twiddle = 32'hd4e1877b;
            7'd79: twiddle = 32'hd1ef8894;
            7'd80: twiddle = 32'hcf0489be;
            7'd81: twiddle = 32'hcc218afb;
            7'd82: twiddle = 32'hc9468c4a;
            7'd83: twiddle = 32'hc6738dab;
            7'd84: twiddle = 32'hc3a98f1d;
            7'd85: twiddle = 32'hc0e990a1;
            7'd86: twiddle = 32'hbe329236;
            7'd87: twiddle = 32'hbb8593dc;
            7'd88: twiddle = 32'hb8e39592;
            7'd89: twiddle = 32'hb64c9759;
            7'd90: twiddle = 32'hb3c09930;
            7'd91: twiddle = 32'hb1409b17;
            7'd92: twiddle = 32'haecc9d0e;
            7'd93: twiddle = 32'hac659f14;
            7'd94: twiddle = 32'haa0aa129;
            7'd95: twiddle = 32'ha7bda34c;
            7'd96: twiddle = 32'ha57ea57e;
            7'd97: twiddle = 32'ha34ca7bd;
            7'd98: twiddle = 32'ha129aa0a;
            7'd99: twiddle = 32'h9f14ac65;
            7'd100: twiddle = 32'h9d0eaecc;
            7'd101: twiddle = 32'h9b17b140;
            7'd102: twiddle = 32'h9930b3c0;
            7'd103: twiddle = 32'h9759b64c;
            7'd104: twiddle = 32'h9592b8e3;
            7'd105: twiddle = 32'h93dcbb85;
            7'd106: twiddle = 32'h9236be32;
            7'd107: twiddle = 32'h90a1c0e9;
            7'd108: twiddle = 32'h8f1dc3a9;
            7'd109: twiddle = 32'h8dabc673;
            7'd110: twiddle = 32'h8c4ac946;
            7'd111: twiddle = 32'h8afbcc21;
            7'd112: twiddle = 32'h89becf04;
            7'd113: twiddle = 32'h8894d1ef;
            7'd114: twiddle = 32'h877bd4e1;
            7'd115: twiddle = 32'h8676d7d9;
            7'd116: twiddle = 32'h8583dad8;
            7'd117: twiddle = 32'h84a3dddc;
            7'd118: twiddle = 32'h83d6e0e6;
            7'd119: twiddle = 32'h831ce3f4;
            7'd120: twiddle = 32'h8276e707;
            7'd121: twiddle = 32'h81e2ea1e;
            7'd122: twiddle = 32'h8163ed38;
            7'd123: twiddle = 32'h80f6f055;
            7'd124: twiddle = 32'h809ef374;
            7'd125: twiddle = 32'h8059f695;
            7'd126: twiddle = 32'h8027f9b8;
            7'd127: twiddle = 32'h800afcdc;
            default: twiddle=32'h7fff0000;
        endcase end
    endfunction
    // Piecewise log2 compression: eight steps per octave. A small magnitude
    // floor removes fixed-point roundoff; monotonically increasing, 0..120.
    function [7:0] compress;
        input [18:0] mag;
        integer e, k;
        reg [18:0] shifted;
        reg [7:0] value;
        begin
            e=0;
            for(k=0;k<19;k=k+1) if(mag[k]) e=k;
            if(mag<19'd8) compress=0;
            else begin
                shifted=mag>>(e-3);
                value=((e-2)<<3)+{5'd0,shifted[2:0]};
                compress=(value>120) ? 8'd120 : value;
            end
        end
    endfunction

    // Exactly one multiplier expression, shared by all four real products.
    always @* begin
        mul_a=br; mul_b=wr;
        case(state)
            MUL1: begin mul_a=bi; mul_b=wi; end
            MUL2: begin mul_a=br; mul_b=wi; end
            MUL3: begin mul_a=bi; mul_b=wr; end
            default: begin mul_a=br; mul_b=wr; end
        endcase
    end
    // Optional inference candidate: addresses are selected before the RAM
    // access, exposing exactly one synchronous read and one write port.
    reg [7:0] work_read_addr, work_write_addr;
    reg [35:0] work_write_data;
    reg work_write_en;
    always @* begin
        work_read_addr=address_a;
        if(state==SCAN_READ || state==SCAN_BIN) work_read_addr=scan_index;
        else if(state==READ_B || state==LATCH_B) work_read_addr=address_b;
        work_write_en=1'b0;
        work_write_addr=address_a;
        work_write_data={sum_re[17:0],sum_im[17:0]};
        case(state)
            COPY_WRITE: begin
                work_write_en=1'b1;
                work_write_addr=bit_reverse(copy_index);
                work_write_data={{2{capture_q[15]}},capture_q,18'd0};
            end
            WRITE_A: begin
                work_write_en=1'b1;
                work_write_addr=address_a;
                work_write_data={sum_re[17:0],sum_im[17:0]};
            end
            WRITE_B: begin
                work_write_en=1'b1;
                work_write_addr=address_b;
                work_write_data={dif_re[17:0],dif_im[17:0]};
            end
            default: begin end
        endcase
    end
    always @(posedge clk) begin
        product <= mul_a * mul_b;
        if(sample_tick && rst_n) capture_mem[{capture_bank,capture_index}] <= pcm_sample;
        capture_q <= capture_mem[{copy_bank,copy_index}];
        if(work_write_en) work_mem[work_write_addr] <= work_write_data;
        work_q <= work_mem[work_read_addr];
    end

    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state<=IDLE; capture_bank<=0; capture_index<=0;
            ready_bank<=0; copy_bank<=0; block_ready<=0; copy_index<=0;
            stage<=0; half_span<=1; group_base<=0; butterfly_j<=0;
            scan_index<=1; publish_band<=0; pending_levels<=0;
            levels<=0; frame_valid<=0; overflow<=0;
            ar<=0; ai<=0; br<=0; bi<=0; wr<=0; wi<=0;
            product_acc<=0; tr<=0; ti<=0;
            for(reset_band=0;reset_band<8;reset_band=reset_band+1) band_peak[reset_band]<=0;
        end else begin
            frame_valid<=0;
            // More than one block arriving during computation is invalid.
            // Copy-bank collision is checked separately for pathological ticks.
            if(sample_tick) begin
                capture_index<=capture_index+1'b1;
                if((state==COPY_READ || state==COPY_WRITE) && capture_bank==copy_bank)
                    overflow<=1;
                if(capture_index==8'd255) begin
                    if(block_ready || state!=IDLE) overflow<=1;
                    ready_bank<=capture_bank;
                    block_ready<=1;
                    capture_bank<=~capture_bank;
                end
            end
            case(state)
                IDLE: if(block_ready) begin
                    block_ready<=0; copy_bank<=ready_bank; copy_index<=0;
                    state<=COPY_READ;
                    for(reset_band=0;reset_band<8;reset_band=reset_band+1) band_peak[reset_band]<=0;
                end
                COPY_READ: state<=COPY_WRITE;
                COPY_WRITE: begin
                    if(copy_index==255) begin
                        stage<=0; half_span<=1; group_base<=0; butterfly_j<=0;
                        state<=READ_A;
                    end else begin copy_index<=copy_index+1'b1; state<=COPY_READ; end
                end
                READ_A: begin
                    {wr,wi}<=twiddle(butterfly_j << (3'd7-stage));
                    state<=LATCH_A;
                end
                LATCH_A: begin ar<=work_q[35:18]; ai<=work_q[17:0]; state<=READ_B; end
                READ_B: state<=LATCH_B;
                LATCH_B: begin br<=work_q[35:18]; bi<=work_q[17:0]; state<=MUL0; end
                MUL0: state<=MUL1;
                MUL1: begin product_acc<=product_ext; state<=MUL2; end
                MUL2: begin tr<=(product_acc-product_ext) >>> 15; state<=MUL3; end
                MUL3: begin product_acc<=product_ext; state<=MUL4; end
                MUL4: begin ti<=(product_acc+product_ext) >>> 15; state<=WRITE_A; end
                WRITE_A: state<=WRITE_B;
                WRITE_B: begin
                    if(butterfly_j==half_span-1'b1) begin
                        butterfly_j<=0;
                        if(next_group>=9'd256) begin
                            group_base<=0;
                            if(stage==7) begin scan_index<=1; state<=SCAN_READ; end
                            else begin stage<=stage+1'b1; half_span<=half_span<<1; state<=READ_A; end
                        end else begin group_base<=next_group[7:0]; state<=READ_A; end
                    end else begin butterfly_j<=butterfly_j+1'b1; state<=READ_A; end
                end
                SCAN_READ: state<=SCAN_BIN;
                SCAN_BIN: begin
                    if(magnitude>band_peak[scan_band]) band_peak[scan_band]<=magnitude;
                    if(scan_index==127) begin publish_band<=0; state<=LEVEL_BAND; end
                    else begin scan_index<=scan_index+1'b1; state<=SCAN_READ; end
                end
                LEVEL_BAND: begin
                    pending_levels[{publish_band,3'b000} +: 8]<=next_level;
                    if(publish_band==7) state<=PUBLISH;
                    else publish_band<=publish_band+1'b1;
                end
                PUBLISH: begin levels<=pending_levels; frame_valid<=1; state<=IDLE; end
                default: state<=IDLE;
            endcase
        end
    end
endmodule
