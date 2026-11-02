`timescale 1ns/1ps
// Actual production controller, +5ns 50MHz PHY, independent CAS/storage model.
// Every output pixel is checked against coordinates, never DUT fetch counters.
module tb_framebuffer_zoom;
 parameter real PIXEL_HALF_NS=19.84127;
 reg sclk=0,pclk=0; wire phy_clk;
 always #10 sclk=~sclk;
 always #(PIXEL_HALF_NS) pclk=~pclk;
 assign #5 phy_clk=sclk;
 reg srst_n=0,prst_n=0,frame_begin=0,pixel_wr_valid=0,frame_end=0,frame_abort=0;
 reg [18:0] pixel_wr_addr=0; reg [23:0] pixel_wr_data=0;
 reg cache_mode=1,swap_only=0; reg [1:0] write_bank=0,swap_bank=0;
 reg [1:0] view_mode=0;wire [1:0] view_active;
 wire pixel_wr_ready,s_ready,frame_done,frame_ok,s_front_valid,busy;
 wire [1:0] s_front_bank; wire [3:0] error_flags;
 reg frame_tick=0,pixel_req=0;wire [23:0] pixel_rgb;
 wire pixel_valid,front_valid,underrun;
 media_framebuffer dut(.*);
 integer i,b,x,y,j,scale,ox,oy,expected_mode=0,expected_bank=0;
 integer checked=0,frames=0,cmd_row=0,cmd_col=0,cmd_scale,cmd_width,cmd_ox,cmd_oy,cmd_expected;
 integer len32=0,len64=0,len128=0,misses=0,duplicates_empty=0,write_count=0,saved_writes;
 reg [23:0] expected_rgb;reg do_check=0;
 function [23:0] pattern;
 input integer bank;input integer address;
 begin pattern=(address*24'h17359d) ^ (24'h3f70a1+bank*24'h294b17);end
 endfunction
 always @(posedge sclk)if(srst_n)begin
  if(dut.epoch_state==dut.E_CLEAR)begin cmd_row=0;cmd_col=0;end
  if(dut.cmd_valid && dut.cmd_ready)begin
   if(dut.cmd_write)write_count=write_count+1;
   else begin
    cmd_scale=1<<dut.active_mode_s;cmd_width=640/cmd_scale;
    cmd_ox=(640-cmd_width)/2;cmd_oy=(480-480/cmd_scale)/2;
    cmd_expected=(cmd_oy+cmd_row/cmd_scale)*640+cmd_ox+cmd_col;
    if(dut.cmd_addr[18:0]!==cmd_expected || dut.cmd_addr[20:19]!==s_front_bank)
     $fatal(1,"zoom read address mode=%0d row=%0d col=%0d actual=%h expected=%h",dut.active_mode_s,cmd_row,cmd_col,dut.cmd_addr,cmd_expected);
    if(dut.cmd_len!=(cmd_width-cmd_col>=128 ? 128 : cmd_width-cmd_col))$fatal(1,"zoom burst length");
    if(cmd_row>=480 || dut.cmd_addr[18:0]+dut.cmd_len>307200)$fatal(1,"zoom source out of range");
    if(dut.cmd_len==32)len32=len32+1;
    if(dut.cmd_len==64)len64=len64+1;
    if(dut.cmd_len==128)len128=len128+1;
    cmd_col=cmd_col+dut.cmd_len;
    if(cmd_col==cmd_width)begin cmd_col=0;cmd_row=cmd_row+1;end
   end
  end
  if(error_flags[3])$fatal(1,"zoom FIFO overflow");
 end
 task blank;
 input integer mode;input integer bank;input integer swap;
 begin
  @(negedge pclk);pixel_req=0;view_mode=mode;
  if(swap)begin
   while(busy)@(negedge sclk);
   @(negedge sclk);swap_bank=bank;swap_only=1;@(negedge sclk);swap_only=0;
   repeat(8)@(negedge sclk);
  end
  @(negedge pclk);frame_tick=1;
  @(negedge pclk);frame_tick=0;
  // Entire normal vertical blank. Source can prefill, then consumer opens.
  repeat(40*800)@(negedge pclk);
  if(view_active!==mode || !front_valid || s_front_bank!==bank || dut.p_wait)
   $fatal(1,"zoom blank ACK mode=%0d active=%0d bank=%0d actual=%0d",mode,view_active,bank,s_front_bank);
  expected_mode=mode;expected_bank=bank;
 end endtask
 task scan;
 input integer change_to;
 begin
  scale=1<<expected_mode;ox=(640-640/scale)/2;oy=(480-480/scale)/2;
  checked=0;
  for(y=0;y<480;y=y+1)begin
   for(x=0;x<640;x=x+1)begin
    @(negedge pclk);pixel_req=1;
    if(y==239 && x==319)view_mode=change_to;
    expected_rgb=pattern(expected_bank,(oy+y/scale)*640+ox+x/scale);
    if(dut.repeat_phase!=0 && dut.video_empty)duplicates_empty=duplicates_empty+1;
    @(posedge pclk);#1;
    if(view_active!==expected_mode)$fatal(1,"midframe zoom changed active mode");
    if(underrun || !pixel_valid || pixel_rgb!==expected_rgb)
     $fatal(1,"zoom pixel mode=%0d bank=%0d x=%0d y=%0d rgb=%h expected=%h valid=%b underrun=%b phase=%0d empty=%b",expected_mode,expected_bank,x,y,pixel_rgb,expected_rgb,pixel_valid,underrun,dut.repeat_phase,dut.video_empty);
    checked=checked+1;
   end
   @(negedge pclk);pixel_req=0;
   repeat(159)@(negedge pclk);
  end
  if(checked!=307200 || cmd_row!=480 || cmd_col!=0)$fatal(1,"incomplete frame/read schedule");
  frames=frames+1;
  $display("PASS zoom mode=%0d bank=%0d full RGB888 pixels=%0d pclk_half=%f",expected_mode,expected_bank,checked,PIXEL_HALF_NS);$fflush();
 end endtask
 task cold_abort;
 integer c;
 begin
  @(negedge sclk);write_bank=1;frame_begin=1;
  @(negedge sclk);frame_begin=0;
  for(c=0;c<1024;c=c+1)begin
   while(!pixel_wr_ready)@(negedge sclk);
   pixel_wr_valid=1;pixel_wr_addr=c;pixel_wr_data=pattern(1,c);
   @(negedge sclk);pixel_wr_valid=0;
  end
  // A cold source is allowed to pause while the viewer keeps requesting zoom.
  repeat(200)@(negedge sclk);
  frame_abort=1;@(negedge sclk);frame_abort=0;
  while(busy)@(negedge sclk);
  if(s_front_bank!=3 || !error_flags[2])$fatal(1,"cold load abort changed visible cache bank");
 end endtask
 initial begin
  srst_n=1;prst_n=1;#1;srst_n=0;prst_n=0;
  #72;srst_n=1;prst_n=1;wait(s_ready);
  // Independent storage preloads all 24 bits of four original full-size banks.
  // Reads still traverse actual command controller, SDRAM PHY and async FIFO.
  for(b=0;b<4;b=b+1)for(i=0;i<307200;i=i+1)
   dut.controller.memory.mem[b*524288+i]={8'd0,pattern(b,i)};
  blank(0,0,1);scan(1);
  saved_writes=write_count;
  blank(1,0,0);scan(2);
  blank(2,3,1);
  fork scan(0);cold_abort();join
  // Same blank commits a different bank and zoom; no mixed bank/mode pixels.
  blank(0,2,1);scan(2);
  if(write_count==saved_writes)$fatal(1,"cold load never reached actual controller");
  saved_writes=write_count;
  blank(2,0,1);scan(1);
  blank(1,2,1);scan(0);
  if(write_count!=saved_writes)$fatal(1,"cache zoom issued source writes");
  if(len32==0 || len64==0 || len128==0 || duplicates_empty==0)$fatal(1,"missing partial burst/end-empty duplicate coverage");
  // Illegal request sanitizes to legacy 1x at next blank, never midframe.
  @(negedge pclk);view_mode=3;frame_tick=1;
  @(negedge pclk);frame_tick=0;
  repeat(100)@(negedge pclk);
  if(view_active!=0 || dut.active_mode_s!=0)$fatal(1,"invalid mode did not sanitize");
  $display("PASS zoom full_frames=%0d len32=%0d len64=%0d len128=%0d end_empty_duplicates=%0d cold_write_commands=%0d",frames,len32,len64,len128,duplicates_empty,write_count);
  $finish;
 end
 initial begin #1500000000;$fatal(1,"zoom timeout");end
endmodule
