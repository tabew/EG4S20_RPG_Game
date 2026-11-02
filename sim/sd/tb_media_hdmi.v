`timescale 1ns/1ps
// Verify real top-level RGB/HS/VS/DE are registered together before vendor IP.
// Encrypted TMDS internals are not simulated by Icarus.
module tb_media_hdmi;
 reg clk=0;always #5 clk=~clk;
 reg rst=0;wire[2:0]hd;wire hc,sc,mo,cs,pwm,bz;wire[3:0]rows;wire[7:0]led;
 rpg_top dut(.clk50(clk),.rst_key_n(rst),.key_n(4'b1111),.hdmi_d_p(hd),.hdmi_clk_p(hc),.key_row(rows),.led(led),.buzzer_n(bz),.pwm_audio(pwm),.sd_sclk(sc),.sd_mosi(mo),.sd_cs_n(cs),.sd_miso(1'b1));
 reg[15:0]want_rgb;reg want_hs,want_vs,want_de;integer i,active=0,sync_changes=0;reg oldhs;
 initial begin
  repeat(10)@(negedge clk);rst=1;repeat(20)@(negedge clk);oldhs=dut.u_vid.hs;
  for(i=0;i<700000;i=i+1)begin
   @(negedge clk);want_rgb=dut.u_vid.rgb;want_hs=dut.u_vid.hs;want_vs=dut.u_vid.vs;want_de=dut.u_vid.de;
   @(posedge clk);#1;
   if(dut.u_hdmi.rgb!==want_rgb || dut.u_hdmi.hs!==want_hs || dut.u_hdmi.vs!==want_vs || dut.u_hdmi.de!==want_de)
    $fatal(1,"HDMI input pixel/sync register misalignment at%0d",i);
   if(want_de)active=active+1;if(want_hs!=oldhs)sync_changes=sync_changes+1;oldhs=want_hs;
  end
  if(active<400000 || sync_changes<100)$fatal(1,"insufficient raster coverage");
  $display("PASS media_hdmi700000 cycles pixel/sync aligned active=%0d HSedges=%0d",active,sync_changes);$finish;
 end
endmodule
