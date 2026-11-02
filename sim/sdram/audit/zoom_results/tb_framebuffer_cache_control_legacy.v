`timescale 1ns/1ps
// Focused handshake checks; RGB/storage integrity is covered by the full bench.
module tb_framebuffer_cache_control;
 reg sclk=0,pclk=0;wire phy_clk;
 always #10 sclk=~sclk;always #19.84127 pclk=~pclk;
 assign #5 phy_clk=sclk;
 reg srst_n=0,prst_n=0,frame_begin=0,pixel_wr_valid=0,frame_end=0,frame_abort=0;
 reg [18:0]pixel_wr_addr=0;reg[23:0]pixel_wr_data=0;
 reg cache_mode=1,swap_only=0;reg[1:0]write_bank=1,swap_bank=0;
 wire pixel_wr_ready,s_ready,frame_done,frame_ok,s_front_valid,busy;
 wire[1:0]s_front_bank;wire[3:0]error_flags;
 reg frame_tick=0,pixel_req=0;wire[23:0]pixel_rgb;
 wire pixel_valid,front_valid,underrun;
 wire [1:0] view_mode=2'bzz; wire [1:0] view_active;
 media_framebuffer dut(.*);
 integer successes=0,failures=0,oldfail,oldsuccess;
 always @(posedge sclk)if(srst_n)begin
  if(frame_done)if(frame_ok)successes=successes+1;else failures=failures+1;
  if(dut.cmd_valid && dut.cmd_ready && dut.cmd_write)$fatal(1,"cache control generated a write");
 end
 task blank;begin @(negedge pclk);frame_tick=1;@(negedge pclk);frame_tick=0;end endtask
 task swap;input[1:0]bank;begin @(negedge sclk);swap_bank=bank;swap_only=1;@(negedge sclk);swap_only=0;end endtask
 initial begin
  srst_n=1;prst_n=1;#1;srst_n=0;prst_n=0;#72;srst_n=1;prst_n=1;
  wait(s_ready);
  // Bad decoder header can request abort before it has emitted frame_begin.
  oldfail=failures;@(negedge sclk);frame_abort=1;@(negedge sclk);frame_abort=0;
  while(failures==oldfail)@(negedge sclk);
  if(frame_ok || s_front_valid || busy)$fatal(1,"idle abort did not acknowledge with invalid front");
  // No pixel consumer is enabled here: only command/CDC behavior is checked.
  oldsuccess=successes;swap(2);blank();
  while(successes==oldsuccess)@(negedge sclk);
  if(s_front_bank!=2 || !front_valid)$fatal(1,"initial bank selection");
  // Initiate a new blank to force front prefetch, and request during real READ.
  blank();while(dut.state!=dut.READ_WAIT || !dut.ctrl_busy)@(negedge sclk);
  oldsuccess=successes;swap(3);
  if(!busy || !dut.commit_pending || pixel_wr_ready)$fatal(1,"busy controller rejected cached bank request");
  repeat(4)@(negedge sclk);
  if(s_front_bank!=2)$fatal(1,"cache request switched before blank");
  // Allow the prior epoch's pixel return to settle before another blank.
  while(dut.epoch_state!=dut.E_RUN)@(negedge sclk);
  blank();while(successes==oldsuccess)@(negedge sclk);
  if(s_front_bank!=3)$fatal(1,"queued busy-read cache hit did not commit");
  // A duplicate swap during an upload must leave its captured write bank alone.
  @(negedge sclk);frame_begin=1;write_bank=1;
  @(negedge sclk);frame_begin=0;write_bank=0;
  swap(2);
  if(!dut.loading || dut.commit_pending || dut.active_write_bank!=1 || !error_flags[0])$fatal(1,"duplicate swap corrupted active upload");
  oldfail=failures;frame_abort=1;@(negedge sclk);frame_abort=0;
  while(failures==oldfail)@(negedge sclk);
  if(s_front_bank!=3)$fatal(1,"abort modified visible bank");
  // A second decoder/header abort has no loading frame and retains this front.
  oldfail=failures;@(negedge sclk);frame_abort=1;@(negedge sclk);frame_abort=0;
  while(failures==oldfail)@(negedge sclk);
  if(s_front_bank!=3 || busy || !front_valid)$fatal(1,"idle abort lost visible front");
  $display("PASS framebuffer_cache_control idle abort ack, hit during real READ, vblank selection, duplicate swap during upload");$finish;
 end
 initial begin #2000000;$fatal(1,"control timeout state=%0d epoch=%0d success=%0d fail=%0d",dut.state,dut.epoch_state,successes,failures);end
endmodule
