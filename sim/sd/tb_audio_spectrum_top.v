`timescale 1ns/1ps
// Real rpg_top music/HDMI/FFT integration. Drive public reset/K3 only;
// inspect hierarchy passively. SIM_BEHAV passes clk50 through to clk_pix,
// so the named board input is deliberately driven at the actual 25.2MHz.
module tb_audio_spectrum_top;
 reg clk=0; always #19.84127 clk=~clk;
 reg rst=0; reg [3:0] keys=15;
 wire [7:0] dac; wire pwm,buzzer,sc,mo,cs,hc; wire [2:0] hd; wire [3:0] rows;
 rpg_top dut(.clk50(clk),.rst_key_n(rst),.key_n(keys),.hdmi_d_p(hd),.hdmi_clk_p(hc),.key_row(rows),.led(dac),.buzzer_n(buzzer),.pwm_audio(pwm),.sd_sclk(sc),.sd_mosi(mo),.sd_cs_n(cs),.sd_miso(1'b1));
 // Only K3 debounce accelerated: short60 clocks versus long400 clocks.
 defparam dut.u_k2.CLK_KHZ=20,dut.u_k2.DEB_MS=1,dut.u_k2.HOLD_MS=8;
 `define ENC dut.u_hdmi.g_hdmi_audio.u_encoder
 `define FFT dut.u_audio_spectrum
 integer cycles=0,last_tick=-1,ticks=0,frames=0,last_frame_cycle=-1;
 integer capture_count=0,blocks=0,zero_frames=0,mute_frames=0;
 integer active_nonzero=0,resume_nonzero=0,muted_ticks=0,nonzero_ticks=0;
 integer fifo_checks=0,capture_checks=0,maximum=0,mute_bound=0;
 integer stage=0,j,nz,lev,old_lev,wanted,wp,cp,pcm_value;
 integer mute_start_frame=0,resume_start_frame=0,bench=0;
 reg block_zero=1,pending_zero=0,pending_block=0,push;
 reg [63:0] previous_levels=0;
 reg [23:0] expected_fifo;
 reg signed [15:0] expected_pcm;
 reg saved_auto,saved_mute,saved_mirror;
 reg [1:0] saved_view,saved_rotation,saved_mode;
 real tick_time=0,clock_period;
 always @(posedge clk) if(dut.rst_n) begin
  cycles=cycles+1;
  if(dut.spectrum_overflow || `ENC.overflow) $fatal(1,"FFT or HDMI FIFO overflow");
  if(dut.hdmi_audio_tick !== `ENC.sample_tick || `FFT.sample_tick !== `ENC.sample_tick || dut.u_hdmi.audio_sample_tick !== `ENC.sample_tick)
   $fatal(1,"FFT/public HDMI tick differs from actual encoder capture enable");
  push=`ENC.sample_tick;
  if(push) begin
   if(last_tick>=0 && cycles-last_tick!=525) $fatal(1,"actual HDMI sample spacing is %0d, expected525",cycles-last_tick);
   if(ticks==1) begin
    clock_period=($realtime-tick_time)/525.0;
    if(clock_period<39.681 || clock_period>39.684) $fatal(1,"SIM_BEHAV actual pixel clock period mismatch");
    $display("CLOCK input_clk50_is_SIM_BEHAV_pixel_clock period_ns=%0.6f pixel_hz=%0.3f sample_hz=%0.6f",clock_period,1.0e9/clock_period,1.0e9/(clock_period*525.0));
   end
   tick_time=$realtime;last_tick=cycles;ticks=ticks+1;
   pcm_value=($signed({1'b0,dut.snd_dac})-128)*64;
   if($signed(dut.hdmi_pcm_sample)!==pcm_value) $fatal(1,"PSG offsetbinary scaling mismatch");
   expected_pcm=dut.media_mute ? 16'sd0 : dut.hdmi_pcm_sample;
   if(`ENC.audio_sample !== dut.hdmi_pcm_sample || `FFT.pcm_sample !== expected_pcm)
    $fatal(1,"actual FFT/HDMI PCM input mismatch");
   if(`ENC.mute !== dut.media_mute) $fatal(1,"encoder mute mismatch");
   expected_fifo={expected_pcm,8'd0};wp=`ENC.wrptr;
   cp={`FFT.capture_bank,`FFT.capture_index};
   if(`FFT.capture_index !== capture_count[7:0]) $fatal(1,"FFT sample capture counter diverged");
   block_zero=block_zero && (expected_pcm==0);
   if(dut.media_mute) begin
    muted_ticks=muted_ticks+1;
    if(expected_pcm!==16'sd0) $fatal(1,"muted PCM nonzero");
   end else if(expected_pcm!=0) begin
    nonzero_ticks=nonzero_ticks+1;
    if(stage==2) resume_nonzero=resume_nonzero+1;
   end
   capture_count=capture_count+1;
   if(capture_count==256) begin
    if(pending_block) $fatal(1,"unpublished reference FFT block");
    pending_zero=block_zero;pending_block=1;blocks=blocks+1;
    capture_count=0;block_zero=1;
   end
  end
  #1;
  if(push) begin
   if(`ENC.fifo[wp] !== expected_fifo) $fatal(1,"new HDMI FIFO push differs from real PSG/mute PCM");
   if(`FFT.capture_mem[cp] !== expected_pcm) $fatal(1,"FFT capture memory differs from same HDMI PCM");
   fifo_checks=fifo_checks+1;capture_checks=capture_checks+1;
  end
  if(dut.spectrum_frame_valid) begin
   if(!pending_block) $fatal(1,"FFT published without captured256 sample block");
   pending_block=0;frames=frames+1;
   if(last_frame_cycle>=0 && cycles-last_frame_cycle!=134400) $fatal(1,"FFT publication interval mismatch");
   last_frame_cycle=cycles;nz=0;maximum=0;
   for(j=0;j<8;j=j+1) begin
    lev=(dut.spectrum_levels>>(8*j))&255;
    if((^dut.spectrum_levels)===1'bx || lev>120) $fatal(1,"FFT level unknown/outside0..120 band%0d",j);
    if(lev!=0) nz=nz+1;
    if(lev>maximum) maximum=lev;
    if(stage==1 && pending_zero) begin
     old_lev=(previous_levels>>(8*j))&255;
     wanted=(old_lev>2)?old_lev-2:0;
     if(lev!=wanted) $fatal(1,"silent real PCM decay band%0d expected%0d got%0d",j,wanted,lev);
    end
   end
   if(stage==0 && nz>=2) active_nonzero=active_nonzero+1;
   if(stage==1) begin
    mute_frames=mute_frames+1;
    if(pending_zero) begin
     if(zero_frames==0) begin
      mute_bound=0;
      for(j=0;j<8;j=j+1) begin
       old_lev=(previous_levels>>(8*j))&255;
       if((old_lev+1)/2>mute_bound) mute_bound=(old_lev+1)/2;
      end
      if(mute_bound>60) $fatal(1,"derived mute decay bound exceeds60");
      $display("MUTE_BOUND previous_levels=%h zero_blocks_to_zero_at_most=%0d",previous_levels,mute_bound);
     end
     zero_frames=zero_frames+1;
     if(zero_frames>mute_bound && dut.spectrum_levels!=0) $fatal(1,"mute decay exceeded measured bound");
    end
   end
   $display("FRAME index=%0d cycle=%0d stage=%0d fully_silent_block=%0d nonzero_bands=%0d maximum=%0d levels=%h",frames,cycles,stage,pending_zero,nz,maximum,dut.spectrum_levels);
   previous_levels=dut.spectrum_levels;
  end
 end
 task physical_k3; input integer duration;
 begin
  @(negedge clk);keys[1]=0;repeat(duration) @(negedge clk);
  keys[1]=1;repeat(200) @(negedge clk);
 end endtask
 task save_controls;
 begin
  saved_auto=dut.media_auto;saved_view=dut.media_view;saved_mode=dut.media_mode;
  saved_rotation=dut.mon_rotation;saved_mirror=dut.mon_mirror;
 end endtask
 task unchanged_controls;
 begin
  if(dut.media_auto!==saved_auto || dut.media_view!==saved_view || dut.media_mode!==saved_mode || dut.mon_rotation!==saved_rotation || dut.mon_mirror!==saved_mirror)
   $fatal(1,"long K3 mute changed auto/view/mode/monster controls");
 end endtask
 initial begin
  if($test$plusargs("BENCH")) bench=1;
  repeat(10) @(negedge clk);rst=1;
  wait(dut.rst_n);repeat(10) @(negedge clk);
  if(dut.u_hdmi.AUDIO_PCM_EN!=1 || `ENC.PCM_INPUT_EN!=1 || dut.u_hdmi.PIXEL_HZ!=25200000 || dut.u_hdmi.H_ACTIVE!=640 || dut.u_hdmi.H_TOTAL!=800)
   $fatal(1,"production PCM/640x480 configuration changed");
  wait(frames>=2);@(negedge clk);
  if(active_nonzero<1 || nonzero_ticks<40) $fatal(1,"real no-card BGM did not energize at least2 bands within2 FFT blocks");
  save_controls;saved_mute=dut.media_mute;
  physical_k3(60);
  if(dut.media_auto!==!saved_auto || dut.media_mute!==saved_mute || dut.media_view!==saved_view || dut.mon_rotation!==saved_rotation || dut.mon_mirror!==saved_mirror)
   $fatal(1,"short K3 pause changed music/view/monster controls");
  save_controls;physical_k3(400);unchanged_controls;
  if(!dut.media_mute) $fatal(1,"real long K3 failed to mute");
  stage=1;mute_start_frame=frames;
  // Bounded by publication count; no timer drives DUT levels or audio.
  while(dut.spectrum_levels!=0 || zero_frames==0) begin
   @(negedge clk);
   if(frames-mute_start_frame>65) $fatal(1,"real muted spectrum failed to reach zero within65 frames");
   if(bench && zero_frames>=1) begin
    $display("PASS audio_spectrum_top_bench ticks=%0d frames=%0d observed_decay_bound=%0d",ticks,frames,mute_bound);$finish;
   end
  end
  $display("MUTE_ZERO pure_zero_blocks=%0d derived_bound=%0d total_mute_publications=%0d",zero_frames,mute_bound,mute_frames);
  // Short K3 resumes picture automation while keeping actual audio muted.
  saved_mute=dut.media_mute;saved_auto=dut.media_auto;physical_k3(60);
  if(dut.media_auto!==!saved_auto || dut.media_mute!==saved_mute || dut.media_view!==saved_view || dut.mon_rotation!==saved_rotation || dut.mon_mirror!==saved_mirror)
   $fatal(1,"short K3 auto resume changed mute/view/monster controls");
  save_controls;physical_k3(400);unchanged_controls;
  if(dut.media_mute) $fatal(1,"real long K3 failed to unmute");
  stage=2;resume_start_frame=frames;
  wait(frames>=resume_start_frame+2);@(negedge clk);
  nz=0;for(j=0;j<8;j=j+1) if(((dut.spectrum_levels>>(8*j))&255)!=0) nz=nz+1;
  if(nz<2 || resume_nonzero<40 || muted_ticks<256) $fatal(1,"BGM/FFT failed to return within2 blocks after unmute");
  if(fifo_checks!=ticks || capture_checks!=ticks) $fatal(1,"missing per-tick memory comparison");
  $display("STATS {\"cycles\":%0d,\"sample_ticks\":%0d,\"frame_valid_count\":%0d,\"captured_blocks\":%0d,\"muted_sample_ticks\":%0d,\"nonzero_sample_ticks\":%0d,\"fifo_checks\":%0d,\"fft_capture_checks\":%0d,\"pure_zero_blocks_to_zero\":%0d,\"derived_mute_bound\":%0d,\"mute_publications\":%0d,\"resume_nonzero_samples\":%0d,\"resume_nonzero_bands\":%0d}",cycles,ticks,frames,blocks,muted_ticks,nonzero_ticks,fifo_checks,capture_checks,zero_frames,mute_bound,mute_frames,resume_nonzero,nz);
  $display("PASS audio_spectrum_top real_PSG_HDMI_FFT_exact_ticks_PCM_and_raw_K3_decay_resume");$finish;
 end
 initial begin #400000000;$fatal(1,"top FFT integration timeout (over74 full FFT periods)");end
 `undef ENC
 `undef FFT
endmodule
