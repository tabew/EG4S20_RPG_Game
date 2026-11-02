`timescale 1ns/1ps
// Timing-only companion to full RGB/storage bench: real CEA raster epochs and
// actual controller/model, no pixel consumer. Cached payload integrity is
// established independently by tb_framebuffer_cache's four complete uploads.
module tb_framebuffer_cache_latency;
 reg sclk=0,pclk=0;wire phy_clk;
 always #10 sclk=~sclk;always #19.84127 pclk=~pclk;
 assign #5 phy_clk=sclk;
 reg srst_n=0,prst_n=0,frame_begin=0,pixel_wr_valid=0,frame_end=0,frame_abort=0;
 reg[18:0]pixel_wr_addr=0;reg[23:0]pixel_wr_data=0;
 reg cache_mode=1,swap_only=0;reg[1:0]write_bank=0,swap_bank=0;
 wire pixel_wr_ready,s_ready,frame_done,frame_ok,s_front_valid,busy;
 wire[1:0]s_front_bank;wire[3:0]error_flags;
 reg frame_tick=0,pixel_req=0;wire[23:0]pixel_rgb;
 wire pixel_valid,front_valid,underrun;
 media_framebuffer dut(.*);
 integer x=0,y=0,successes=0,source_words=0,write_commands=0;
 realtime request_time,max_latency=0,latency;
 always @(negedge pclk)if(prst_n)begin
  frame_tick=x==0 && y==480;
  if(x==799)begin x=0;if(y==524)y=0;else y=y+1;end else x=x+1;
 end
 always @(posedge sclk)if(srst_n)begin
  if(pixel_wr_valid && pixel_wr_ready)source_words=source_words+1;
  if(dut.cmd_valid && dut.cmd_ready && dut.cmd_write)write_commands=write_commands+1;
  if(frame_done && frame_ok)successes=successes+1;
 end
 task hit;
 input integer bank;input integer phase_x;input integer phase_y;
 integer oldsuccess,oldwords,oldwrites,oldtokens;
 begin
  // Raster counters update on negedge; sample their settled values on posedge.
  while(x!=phase_x || y!=phase_y)@(posedge pclk);
  @(negedge sclk);swap_bank=bank;swap_only=1;
  oldsuccess=successes;oldwords=source_words;oldwrites=write_commands;
  oldtokens=dut.controller.memory.write_tokens;
  // The next rising sclk samples the request.
  @(posedge sclk);request_time=$realtime;
  @(negedge sclk);swap_only=0;
  while(successes==oldsuccess)@(negedge sclk);
  latency=$realtime-request_time;
  if(latency>max_latency)max_latency=latency;
  if(latency>16677000 || s_front_bank!=bank || pixel_wr_ready || error_flags!=0)$fatal(1,"latency/swap failed bank=%0d latency=%0f",bank,latency);
  if(source_words!=oldwords || write_commands!=oldwrites || dut.controller.memory.write_tokens!=oldtokens)$fatal(1,"latency hit generated writes");
  $display("PASS cache_latency CEA25.2 bank=%0d request_xy=(%0d,%0d) request_to_done_ns=%0.0f source_delta=%0d writecmd_delta=%0d physical_write_delta=%0d",bank,phase_x,phase_y,latency,source_words-oldwords,write_commands-oldwrites,dut.controller.memory.write_tokens-oldtokens);$fflush();
 end endtask
 initial begin
  srst_n=1;prst_n=1;#1;srst_n=0;prst_n=0;#72;srst_n=1;prst_n=1;
  wait(s_ready);
  hit(0,0,10);hit(1,0,0);hit(2,200,250);hit(3,790,489);hit(0,0,500);
  $display("PASS framebuffer_cache_latency CEA25.2 maximum_request_to_done_ns=%0.0f source_words=%0d write_commands=%0d",max_latency,source_words,write_commands);$finish;
 end
 initial begin #150000000;$fatal(1,"latency timeout x=%0d y=%0d state=%0d epoch=%0d",x,y,dut.state,dut.epoch_state);end
endmodule
