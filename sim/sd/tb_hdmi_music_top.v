`timescale 1ns/1ps
// Passive scoreboard of the real top's PSG -> HDMI FIFO -> packet sample path.
// Key timing and mode lock only are accelerated; source/HDMI sample clocks remain.
module tb_hdmi_music_top;
 reg clk=0;always #19.84127 clk=~clk;
 reg rst=0;reg[3:0]keys=15;
 wire[7:0]dac;wire pwm,buzzer,sc,mo,cs;wire[2:0]hd;wire hc;wire[3:0]rows;
 rpg_top dut(.clk50(clk),.rst_key_n(rst),.key_n(keys),.hdmi_d_p(hd),.hdmi_clk_p(hc),.key_row(rows),.led(dac),.buzzer_n(buzzer),.pwm_audio(pwm),.sd_sclk(sc),.sd_mosi(mo),.sd_cs_n(cs),.sd_miso(1'b1));
 defparam dut.u_k0.CLK_KHZ=20,dut.u_k0.DEB_MS=1,dut.u_k0.HOLD_MS=4;
 defparam dut.u_k1.CLK_KHZ=20,dut.u_k1.DEB_MS=1,dut.u_k1.HOLD_MS=4;
 defparam dut.u_k2.CLK_KHZ=20,dut.u_k2.DEB_MS=1,dut.u_k2.HOLD_MS=4;
 defparam dut.u_k3.CLK_KHZ=20,dut.u_k3.DEB_MS=1,dut.u_k3.HOLD_MS=4;
 defparam dut.u_media.LOCK_FRAMES=0;
 `define ENC dut.u_hdmi.g_hdmi_audio.u_encoder
 reg[23:0]expected_queue[0:4095];reg[23:0]expected_samples[0:3];reg[23:0]word;
 reg[15:0]last48[0:47];reg[3:0]wanted_present;
 integer written=0,readout=0,pending=0,pushes=0,packets=0,nonzero=0,mute_samples=0,resume_samples=0,difference48=0;
 integer take_n,j,wp,pcm_value,cycles=0,last_tick=-1,tick_gap,sfx_events=0;
 reg push,take;reg[1:0]saved_view;reg saved_auto,saved_mute;integer stage=0;
 always @(posedge clk)if(dut.rst_n)begin
  cycles=cycles+1;
  if(dut.sfx_trig && !dut.gal_on)sfx_events=sfx_events+1;
  push=`ENC.sample_tick;take=`ENC.take;
  take_n=(pending>=4)?4:pending;wanted_present=0;
  pcm_value=($signed({1'b0,dut.snd_dac})-128)*64;
  if($signed(dut.hdmi_pcm_sample)!==pcm_value)$fatal(1,"top8bitPSG to signed16 scaling expected%0d got%0d",pcm_value,$signed(dut.hdmi_pcm_sample));
  if($signed(`ENC.audio_sample)!==$signed(dut.hdmi_pcm_sample))$fatal(1,"production encoder selected fixed tone instead of PSG");
  if(`ENC.overflow)$fatal(1,"music48k FIFO overflow");
  if(take)begin
   for(j=0;j<4;j=j+1)begin
    expected_samples[j]=(j<take_n)?expected_queue[(readout+j)&4095]:0;
    wanted_present[j]=(j<take_n);
   end
   readout=readout+take_n;packets=packets+1;
  end
  if(push)begin
   if(pending>=16)$fatal(1,"scoreboard overflow");
   if(last_tick>=0 && cycles-last_tick!=525)$fatal(1,"HDMI no longer48k at25.2M");last_tick=cycles;
   word=dut.media_mute?24'd0:{dut.hdmi_pcm_sample,8'd0};wp=`ENC.wrptr;
   expected_queue[written&4095]=word;written=written+1;pushes=pushes+1;
   if(word!=0)nonzero=nonzero+1;
   if(pushes>48 && word[23:8]!=last48[pushes%48])difference48=difference48+1;
   last48[pushes%48]=word[23:8];
   if(stage==1)begin if(word!=0)$fatal(1,"muted HDMI input nonzero");mute_samples=mute_samples+1;end
   if(stage==2 && word!=0)resume_samples=resume_samples+1;
  end
  pending=written-readout;
  #1;
  if(push && `ENC.fifo[wp]!==word)$fatal(1,"HDMI FIFO sample differs from actual PSG/mute reference");
  if(take)begin
   if(`ENC.present!==wanted_present)$fatal(1,"HDMI sample presence/count mismatch");
   for(j=0;j<4;j=j+1)if(`ENC.samples[j]!==expected_samples[j])$fatal(1,"packet sample mismatch slot%0d",j);
  end
 end
 task physical_key;input integer logical;input integer duration;
 begin @(negedge clk);keys[3-logical]=0;repeat(duration)@(negedge clk);keys[3-logical]=1;repeat(200)@(negedge clk);end endtask
 initial begin
  for(j=0;j<48;j=j+1)last48[j]=0;
  repeat(10)@(negedge clk);rst=1;repeat(10000)@(negedge clk);
  if(dut.u_hdmi.AUDIO_PCM_EN!=1 || `ENC.PCM_INPUT_EN!=1)$fatal(1,"top production PCM parameter disabled");
  repeat(90000)@(negedge clk);if(nonzero<40 || difference48<10)$fatal(1,"HDMI stream is silence or unchanged1k tone");
  saved_view=dut.media_view;saved_mute=dut.media_mute;
  physical_key(2,60);if(dut.media_auto || dut.media_mute!==saved_mute || dut.media_view!==saved_view)$fatal(1,"shortK3 imagepause changed music/view");
  repeat(60000)@(negedge clk);saved_auto=dut.media_auto;
  physical_key(2,500);if(!dut.media_mute || dut.media_auto!==saved_auto || dut.media_view!==saved_view)$fatal(1,"longK3 failed music-only mute");
  repeat(5000)@(negedge clk);stage=1;
  repeat(50000)@(negedge clk);
  for(j=0;j<4;j=j+1)if(`ENC.present[j] && `ENC.samples[j]!=0)$fatal(1,"mute did not drain packet queue to zero");
  physical_key(2,60);if(!dut.media_auto || !dut.media_mute)$fatal(1,"shortK3 resume incorrectly unmutes music");
  stage=0;physical_key(2,500);if(dut.media_mute || !dut.media_auto)$fatal(1,"longK3 failed resume independently");stage=2;
  repeat(70000)@(negedge clk);if(resume_samples<20 || mute_samples<40)$fatal(1,"missing mute/resume samples");
  physical_key(3,60);repeat(2000)@(negedge clk);if(dut.media_mode!=1 || dut.mus_sel!=0)$fatal(1,"gallery did not select exploration BGM");
  physical_key(3,60);repeat(10000)@(negedge clk);if(dut.media_mode!=2 || dut.mus_sel!=0)$fatal(1,"RPG title did not select exploration BGM");
  physical_key(0,60);repeat(80000)@(negedge clk);if(sfx_events<1)$fatal(1,"real RPG key event never triggered public SFX");
  if(pending>16 || packets<300 || pushes<500)$fatal(1,"insufficient real HDMI music transport coverage");
  $display("PASS hdmi_music_top sourcePSGexact_to_FIFO_and_packet48k pushes=%0d packets=%0d nonzero=%0d unequal48=%0d mute=%0d resume=%0d realRPGsfx=%0d",pushes,packets,nonzero,difference48,mute_samples,resume_samples,sfx_events);$finish;
 end
 initial begin #40000000;$fatal(1,"HDMI music top timeout");end
 `undef ENC
endmodule
