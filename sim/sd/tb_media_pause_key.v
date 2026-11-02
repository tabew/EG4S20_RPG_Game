`timescale 1ns/1ps
// Real top, real physical raw-key mapping; only debounce milliseconds accelerated.
module tb_media_pause_key;
 reg clk=0;always #5 clk=~clk;
 reg rst=0;reg[3:0]keys=15;
 wire[7:0]led;wire pwm,bz,sc,mo,cs;wire[2:0]hd;wire hc;wire[3:0]rows;
 rpg_top dut(.clk50(clk),.rst_key_n(rst),.key_n(keys),.hdmi_d_p(hd),.hdmi_clk_p(hc),.key_row(rows),.led(led),.buzzer_n(bz),.pwm_audio(pwm),.sd_sclk(sc),.sd_mosi(mo),.sd_cs_n(cs),.sd_miso(1'b1));
 defparam dut.u_k2.CLK_KHZ=20,dut.u_k2.DEB_MS=1;
 task short_k3;begin
  @(negedge clk);keys[1]=0;repeat(120)@(negedge clk);
  keys[1]=1;repeat(200)@(negedge clk);
 end endtask
 initial begin
  repeat(10)@(negedge clk);rst=1;repeat(500)@(negedge clk);
  if(dut.u_media.media_auto!==1)$fatal(1,"sequence must startAUTO");
  short_k3;if(dut.u_media.media_auto!==0)$fatal(1,"physical shortK3 failed to pause duringBOOT");
  repeat(1000)@(negedge clk);if(dut.u_media.media_auto!==0)$fatal(1,"pause did not persist");
  short_k3;if(dut.u_media.media_auto!==1)$fatal(1,"physical shortK3 failed to resume");
  @(negedge clk);keys[1]=0;repeat(25000)@(negedge clk);keys[1]=1;repeat(200)@(negedge clk);
  if(dut.u_media.media_mute!==1 || dut.u_media.media_auto!==1)$fatal(1,"longK3 must mute without accidental short pause");
  $display("PASS media_pause_key real raw key_n[1], shortpause/resume whileBOOT andlongmuteisolation");$finish;
 end
endmodule
