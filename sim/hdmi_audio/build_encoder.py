from pathlib import Path
import math
root=Path(__file__).resolve().parents[2]
ref=Path(__file__).parent/'reference_hdl_util'
# The upstream channel code is translated to Verilog-2001 for TD 5.6.
s=(ref/'src/tmds_channel.sv').read_text()
s=s.replace('module tmds_channel','module hdmi_audio_channel').replace('parameter int CN','parameter integer CN').replace('input logic','input wire').replace('output logic [9:0] tmds = 10\'b1101010100','output reg [9:0] tmds')
s=s.replace('logic signed','reg signed').replace('logic [','reg [').replace("acc = 5'sd0",'acc').replace('always_comb','always @*').replace('always_ff','always').replace('unique case','case').replace('i++','i = i + 1')
# Assigned combinational guard outputs must be nets in Verilog.
s=s.replace('reg [9:0] video_guard_band','wire [9:0] video_guard_band').replace('reg [9:0] data_guard_band','wire [9:0] data_guard_band').replace('reg [9:0] video_coding','wire [9:0] video_coding')
s=s.replace('input wire clk_pixel,','input wire clk_pixel,\n    input wire rst_n,')
s=s.replace("always @(posedge clk_pixel) acc <= mode != 3'd1 ? 5'sd0 : acc + acc_add;", "always @(posedge clk_pixel or negedge rst_n)\n    if (!rst_n) acc <= 0; else acc <= mode != 3'd1 ? 5'sd0 : acc + acc_add;")
s=s.replace('always @(posedge clk_pixel)\nbegin\n    case (mode)', "always @(posedge clk_pixel or negedge rst_n)\nbegin\n    if (!rst_n) tmds <= 10'b1101010100;\n    else case (mode)")
tone='\n'.join(f"            6'd{i}: tone = 16'sd{round(8192*math.sin(2*math.pi*i/48))};" if math.sin(2*math.pi*i/48)>=0 else f"            6'd{i}: tone = -16'sd{-round(8192*math.sin(2*math.pi*i/48))};" for i in range(48))
body=r'''// HDMI packet/audio backend, 40 MHz pixel clock, external HS/VS/DE timing.
// Packet formats, BCH and channel coding adapted from hdl-util/hdmi,
// Copyright Sameer Puri and contributors, MIT license; see sim/hdmi_audio/LICENSE-MIT.
// All logic is in clk_pix. The ten pixel delay provides eight preamble + two
// guard pixels before each DE rising edge. Channel encoding adds one register.
module hdmi_audio_encoder #(
    parameter integer H_ACTIVE=800, H_TOTAL=1056,
    parameter integer PIXEL_HZ=40000000
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
    // Fractional divider: intervals 833, 833, 834 clocks, exactly 48 kHz average.
    reg [31:0] sample_acc;
    assign sample_tick = sample_acc >= PIXEL_HZ-48000;
    reg [5:0] tone_phase;
    reg signed [15:0] tone;
    always @* begin
        case(tone_phase)
TONE_TABLE
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
    localparam [19:0] ACR_N=6144, ACR_CTS=PIXEL_HZ/1000;
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
                // AVI: RGB, IT timing (VIC=0), full quantization, no scaling.
                header=24'h0d0282;
                payload[0]=56'h0000000808005f;
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
'''.replace('TONE_TABLE',tone)
(root/'sim/hdmi_audio/encoder_staging.v').write_text(body+'\n'+s,encoding='utf-8')
(ref/'LICENSE-MIT').read_text()
(root/'sim/hdmi_audio/LICENSE-MIT').write_text((ref/'LICENSE-MIT').read_text(),encoding='utf-8')
print('Created encoder staging file')
