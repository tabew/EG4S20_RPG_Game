`timescale 1ns/1ps
// Interface-only stubs. These intentionally make NO claim about physical serial
// timing; TD must elaborate the actual protected entities for that validation.
module Serial_N_1_lvds_dat(input [9:0] DP_I,input PCLK,SCLK,output DSP_O);
 assign DSP_O=DP_I[0];
endmodule
module Serial_N_1_lvds(input [9:0] DP_I,input PCLK,SCLK,output DSP_O);
 assign DSP_O=DP_I[0];
endmodule
module DVITransmitter #(parameter FAMILY="EG4")(
 input [7:0] RED_I,GREEN_I,BLUE_I,input HS_I,VS_I,VDE_I,RST_I,PCLK_I,PCLK_X5_I,
 output TMDS_TX_CLK_P,TMDS_TX_2_P,TMDS_TX_1_P,TMDS_TX_0_P);
 assign {TMDS_TX_CLK_P,TMDS_TX_2_P,TMDS_TX_1_P,TMDS_TX_0_P}={PCLK_I,RED_I[0],GREEN_I[0],BLUE_I[0]};
endmodule
module tb_hdmi_wrapper;
 reg clk=0,clk5=0,rst_n=0;
 always #12.5 clk=~clk;
 always #2.5 clk5=~clk5;
 reg [15:0] rgb=16'ha53c;
 reg [23:0] rgb_full=24'h123456;
 reg full_rgb_en=1,mute=0;
 wire [2:0] data_p,old_data;
 wire clock_p,got;
 hdmi_tx #(.AUDIO_DI_EN(1)) audio (
  .clk_pix(clk),.clk_p5x(clk5),.rst_pix_n(rst_n),.rgb(rgb),.rgb_full(rgb_full),
  .full_rgb_en(full_rgb_en),.mute(mute),.hs(1'b0),.vs(1'b0),.de(1'b1),
  .aud_pkt(56'd0),.aud_req(1'b0),.aud_got(got),.hdmi_d_p(data_p),.hdmi_clk_p(clock_p));
 // Legacy ports deliberately omit rgb_full/full_rgb_en/mute.
 hdmi_tx old (.clk_pix(clk),.clk_p5x(clk5),.rst_pix_n(rst_n),.rgb(rgb),
  .hs(1'b0),.vs(1'b0),.de(1'b1),.aud_pkt(56'd0),.aud_req(1'b0),
  .aud_got(),.hdmi_d_p(old_data),.hdmi_clk_p());
 wire [23:0] expanded={rgb[15:11],rgb[15:13],rgb[10:5],rgb[10:9],rgb[4:0],rgb[4:2]};
 initial begin
  repeat(4) @(negedge clk); rst_n=1;
  repeat(30) @(negedge clk);
  if(audio.rgb888!==rgb_full || audio.g_hdmi_audio.u_encoder.rgb_out!==rgb_full) $fatal(1,"full RGB route");
  if(audio.g_hdmi_audio.u_blue_serializer.DP_I!==audio.g_hdmi_audio.tmds0 ||
     audio.g_hdmi_audio.u_green_serializer.DP_I!==audio.g_hdmi_audio.tmds1 ||
     audio.g_hdmi_audio.u_red_serializer.DP_I!==audio.g_hdmi_audio.tmds2) $fatal(1,"data routing");
  if(audio.g_hdmi_audio.u_clock_serializer.DP_I!==10'b0000011111) $fatal(1,"clock word");
  if(old.rgb888!==expanded || old.g_legacy_dvi.u_dvi.RED_I!==expanded[23:16]) $fatal(1,"legacy compatibility");
  if(got!==0) $fatal(1,"legacy audio request handshake");
  full_rgb_en=0; mute=1;
  repeat(30) @(negedge clk);
  if(audio.g_hdmi_audio.u_encoder.rgb_out!==expanded) $fatal(1,"RGB565 route");
  if(audio.g_hdmi_audio.u_encoder.mute!==1'b1) $fatal(1,"mute route");
  $display("PASS wrapper routing: RGB888/RGB565/mute, vendor clock/data ports, legacy fallback");
  $finish;
 end
endmodule
