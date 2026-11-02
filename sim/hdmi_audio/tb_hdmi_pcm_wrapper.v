`timescale 1ns/1ps
// Reuse interface-only serializer stubs from tb_hdmi_wrapper.v.
module tb_hdmi_pcm_wrapper;
reg clk=0,rst=0; always #5 clk=~clk;
integer c=0,x=0;
wire hs=!(x>=656 && x<752), de=x<640;
wire signed [15:0] pcm=(c*173)^16'h93ad;
wire [23:0] rgb=c*982451653;
wire [2:0] pins; wire clock_pin,got;
wire [9:0] a,b,e;
hdmi_tx #(.AUDIO_DI_EN(1),.AUDIO_PCM_EN(1),.H_ACTIVE(640),.H_TOTAL(800),.PIXEL_HZ(25200000),.VIDEO_ID(1)) dut(
 .clk_pix(clk),.clk_p5x(clk),.rst_pix_n(rst),.rgb(16'hx),.rgb_full(rgb),.full_rgb_en(1'b1),
 .mute(1'b0),.pcm_sample(pcm),.hs(hs),.vs(1'b1),.de(de),
 .aud_pkt(56'habcdef01234567),.aud_req(1'b1),.aud_got(got),.hdmi_d_p(pins),.hdmi_clk_p(clock_pin));
hdmi_audio_encoder #(.PCM_INPUT_EN(1),.H_ACTIVE(640),.H_TOTAL(800),.PIXEL_HZ(25200000),.VIDEO_ID(1)) expected(
 .clk_pix(clk),.rst_n(rst),.rgb(rgb),.hs(hs),.vs(1'b1),.de(de),.mute(1'b0),.pcm_sample(pcm),
 .tmds0(a),.tmds1(b),.tmds2(e),.sample_tick(),.overflow(),.mode_out(),.hs_out(),.vs_out(),.de_out(),.rgb_out());
initial begin repeat(4) @(negedge clk); rst=1; end
always @(posedge clk) if(rst) begin
 x<=x==799?0:x+1;
 #1;
 if(pins !== {e[0],b[0],a[0]} || clock_pin!==1'b1 || got!==1'b0) $fatal(1,"PCM wrapper route or inactive legacy handshake");
 c=c+1;
 if(c==24000) begin $display("PASS PCM wrapper parameter/port/serializer routing; legacy aud_req remains inactive"); $finish; end
end
endmodule
