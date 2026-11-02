`timescale 1ns/1ps
// Real top-level audio and physical key input. Speed up only key debounce timing.
module tb_media_audio;
 reg clk=0;always #5 clk=~clk;
 reg rst=0;reg[3:0]keys=15;
 wire[7:0]dac;wire pwm,buzzer,sc,mo,cs;wire[2:0]hd;wire hc;wire[3:0]rows;
 rpg_top dut(.clk50(clk),.rst_key_n(rst),.key_n(keys),.hdmi_d_p(hd),.hdmi_clk_p(hc),
 .key_row(rows),.led(dac),.buzzer_n(buzzer),.pwm_audio(pwm),.sd_sclk(sc),.sd_mosi(mo),.sd_cs_n(cs),.sd_miso(1'b1));
 defparam dut.u_k2.CLK_KHZ=20,dut.u_k2.DEB_MS=1,dut.u_k2.HOLD_MS=2;
 integer i,lo=255,hi=0,highs=0,changes=0;reg[7:0]lastdac;
 task hold_k3;begin
  @(negedge clk);keys[1]=0;repeat(500)@(negedge clk);keys[1]=1;repeat(200)@(negedge clk);
 end endtask
 initial begin
  repeat(10)@(negedge clk);rst=1;
  repeat(10000)@(negedge clk);
  lastdac=dac;
  for(i=0;i<50000;i=i+1)begin
   @(negedge clk);if(dac<lo)lo=dac;if(dac>hi)hi=dac;
   if(dac!=lastdac)changes=changes+1;lastdac=dac;
   if(buzzer !== !pwm)$fatal(1,"buzzer/PWM polarity inconsistent");
  end
  if(hi-lo<8 || changes<8)$fatal(1,"no audible PCM activity min%0d max%0d changes%0d",lo,hi,changes);
  hold_k3;
  for(i=0;i<512;i=i+1)begin @(negedge clk);
   if(dac!==128)$fatal(1,"longK3 did not mute top-level DAC (got%0d)",dac);
   if(pwm)highs=highs+1;
  end
  if(highs!=256)$fatal(1,"mute PWM not50percent: %0d/512",highs);
  hold_k3;repeat(4000)@(negedge clk);
  lo=255;hi=0;
  for(i=0;i<50000;i=i+1)begin @(negedge clk);if(dac<lo)lo=dac;if(dac>hi)hi=dac;end
  if(hi-lo<8)$fatal(1,"audio did not resume after second longK3");
  $display("PASS media_audio real top PCM, longK3 mute/resume and50percent silent PWM");$finish;
 end
 initial begin #10000000;$fatal(1,"audio timeout");end
endmodule
