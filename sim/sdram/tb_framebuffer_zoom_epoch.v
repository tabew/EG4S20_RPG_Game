`timescale 1ns/1ps
// Focused residual-FIFO recovery when the gallery issues no requests.
module tb_framebuffer_zoom_epoch;
 reg sclk=0,pclk=0;wire phy_clk;
 always #10 sclk=~sclk;always #19.84127 pclk=~pclk;assign #5 phy_clk=sclk;
 reg srst_n=0,prst_n=0,frame_begin=0,pixel_wr_valid=0,frame_end=0,frame_abort=0;
 reg [18:0]pixel_wr_addr=0;reg[23:0]pixel_wr_data=0;
 reg cache_mode=1,swap_only=0;reg[1:0]write_bank=0,swap_bank=0,view_mode=0;
 wire[1:0]s_front_bank,view_active;wire[3:0]error_flags;
 wire pixel_wr_ready,s_ready,frame_done,frame_ok,s_front_valid,busy;
 reg frame_tick=0,pixel_req=0;wire[23:0]pixel_rgb;wire pixel_valid,front_valid,underrun;
 media_framebuffer dut(.*);
 integer i,j,b,commands=0,saved_commands,scale,mode;
 reg[23:0]expected;
 function[23:0]pattern;input integer bank;input integer address;
 begin pattern=(address*24'h17359d)^(24'h3f70a1+bank*24'h294b17);end endfunction
 always@(posedge sclk)if(srst_n)begin
  if(dut.cmd_valid && dut.cmd_ready)begin
   if(dut.cmd_write)$fatal(1,"idle gallery wrote cache");
   commands=commands+1;
  end
  if(error_flags[3])$fatal(1,"idle gallery FIFO overflow");
 end
 task epoch;
 input integer bank;input integer zoom;
 begin
  @(negedge sclk);swap_bank=bank;swap_only=1;
  @(negedge sclk);swap_only=0;
  @(negedge pclk);view_mode=zoom;frame_tick=1;
  @(negedge pclk);frame_tick=0;
  while(dut.p_wait)@(negedge pclk);
  repeat(12000)@(negedge pclk);
  if(view_active!==zoom || s_front_bank!==bank || !front_valid || underrun)$fatal(1,"idle epoch coherence");
 end endtask
 initial begin
  srst_n=1;prst_n=1;#1;srst_n=0;prst_n=0;#72;srst_n=1;prst_n=1;wait(s_ready);
  for(b=0;b<4;b=b+1)for(i=0;i<307200;i=i+1)dut.controller.memory.mem[b*524288+i]={8'd0,pattern(b,i)};
  epoch(0,2);
  // FIFO should stay bounded through a whole 800x525 display frame with no req.
  saved_commands=commands;repeat(800*525)@(negedge pclk);
  if(commands!=saved_commands || dut.video_used<1920 || underrun || pixel_valid)$fatal(1,"no-request frame did not hold full FIFO");
  for(mode=0;mode<3;mode=mode+1)begin
   epoch(mode+1,mode);scale=1<<mode;
   // Deliberate gaps inside repeats must not advance the horizontal phase.
   for(i=0;i<1280;i=i+1)begin
    @(negedge pclk);pixel_req=1;
    expected=pattern(mode+1,((480-480/scale)/2+(i/640)/scale)*640+(640-640/scale)/2+(i%640)/scale);
    @(posedge pclk);#1;
    if(pixel_rgb!==expected || !pixel_valid || underrun)$fatal(1,"residual/phase gap mode=%0d pixel=%0d",mode,i);
    if(i%7==3)begin
     @(negedge pclk);pixel_req=0;
     repeat(3)begin @(posedge pclk);#1;if(pixel_valid)$fatal(1,"unsolicited repeat pixel");end
    end
   end
   @(negedge pclk);pixel_req=0;
  end
  $display("PASS zoom_epoch whole-frame-no-requests, residual FIFO discard, coherent bank/mode, gaps inside repeats, no unsolicited pixels");
  $finish;
 end
 initial begin #50000000;$fatal(1,"zoom epoch timeout");end
endmodule
