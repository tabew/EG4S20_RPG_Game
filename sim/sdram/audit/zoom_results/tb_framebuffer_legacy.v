`timescale 1ns/1ps
// Full integration: actual framebuffer + actual controller + storage-backed
// SDRAM command/timing model. Clocks are physically representative 50/40MHz.
module tb_framebuffer;
 reg sclk=0,pclk=0;wire phy_clk;always #10 sclk=~sclk;always #12.5 pclk=~pclk;
 assign #5 phy_clk=sclk; // Same PLL relationship as hardware: SDRAM+90deg.
 reg srst_n=0,prst_n=0,frame_begin=0,pixel_wr_valid=0,frame_end=0,frame_abort=0;
 reg [18:0] pixel_wr_addr=0;reg [23:0]pixel_wr_data=0;
 wire pixel_wr_ready,s_ready,frame_done,frame_ok,s_front_valid,busy;
 wire [3:0]error_flags; reg frame_tick=0,pixel_req=0;
 wire [23:0]pixel_rgb;wire pixel_valid,front_valid,underrun;
 wire [1:0] view_mode=2'bzz; wire [1:0] view_active;
 wire cache_mode=1'b0,swap_only=1'b0; wire [1:0] swap_bank=0; wire [1:0] s_front_bank;
 media_framebuffer dut(.write_bank(2'bzz),.*);
 integer x=0,y=0,requested_addr=0,expected_front=-1;
 integer checked0=0,checked1=0,done_success=0,done_failure=0;
 integer raster_frames=0,max_source_queue=0,min_video_level=2048;
 integer accepted_writes=0,read_commands=0,write_commands=0,backpressure=0;
 integer phase=0,abort_bus_seen=0,write_bank=-1;
 reg req_sample;integer addr_sample;reg[23:0]expect_sample;
 function [23:0] pattern;
 input integer image;input integer address;
 begin pattern=(address*24'h17359d)^(image==0 ? 24'h3f70a1 : 24'hc82d56); end
 endfunction
 // Pixel requests cover ALL640x480 pixels at their actual800x600 native window.
 // Refresh and raster blanking both run throughout frame upload and display.
 always @(negedge pclk) begin
  if(prst_n)begin
   frame_tick=(x==0 && y==600);
   pixel_req=x>=80 && x<720 && y>=60 && y<540;
   requested_addr=(y-60)*640+x-80;
   if(x==1055)begin x=0;if(y==627)begin y=0;raster_frames=raster_frames+1;end else y=y+1;end
   else x=x+1;
  end
 end
 always @(posedge pclk)begin
  req_sample=pixel_req;addr_sample=requested_addr;
  expect_sample=pattern(expected_front,requested_addr);
  #1;
  if(prst_n && front_valid && req_sample)begin
   if(underrun)$fatal(1,"nominal display underrun frame=%0d addr=%0d fifo=%0d",raster_frames,addr_sample,dut.video_used);
   if(!pixel_valid)$fatal(1,"missing pixel_valid at %0d",addr_sample);
   if(pixel_rgb!==expect_sample)$fatal(1,"RGB mismatch image=%0d addr=%0d got=%h expected=%h",expected_front,addr_sample,pixel_rgb,expect_sample);
   if(expected_front==0)checked0=checked0+1;else checked1=checked1+1;
   if(dut.video_used<min_video_level)min_video_level=dut.video_used;
  end
  if(prst_n && !req_sample && pixel_valid)$fatal(1,"unsolicited pixel");
 end
 always @(posedge sclk)begin
  if(srst_n)begin
   if(dut.source_used>max_source_queue)max_source_queue=dut.source_used;
   if(pixel_wr_valid && pixel_wr_ready)accepted_writes=accepted_writes+1;
   if(dut.cmd_valid && dut.cmd_ready)begin
    if(dut.cmd_write)begin
     write_commands=write_commands+1;
     if(dut.cmd_len==0 || dut.cmd_len>16)$fatal(1,"bad write burst length");
     if(s_front_valid && dut.cmd_addr[19]==dut.front_bank)$fatal(1,"write touched displayed front bank");
    end else begin
     read_commands=read_commands+1;
     if(dut.cmd_len!=128)$fatal(1,"bad prefetch reservation");
    end
   end
   if(frame_abort && dut.ctrl_busy)abort_bus_seen=1;
   if(frame_done)begin
    if(frame_ok)begin
     done_success=done_success+1;expected_front=done_success-1;
     if(!front_valid)$fatal(1,"frame_done preceded pixel-domain swap acknowledgement");
     if(dut.epoch_state!=dut.E_RUN)$fatal(1,"frame_done before returned CDC acknowledgement");
    end else done_failure=done_failure+1;
   end
   if(error_flags[3])$fatal(1,"read reservation overflow");
  end
 end
 task begin_frame;
 begin
  @(negedge sclk);while(busy)@(negedge sclk);
  frame_begin=1;@(negedge sclk);frame_begin=0;
 end endtask
 task send_pixel;
 input integer image;input integer address;input integer spacing;
 integer delay_count;
 begin
  repeat(spacing-1)@(negedge sclk);
  while(!pixel_wr_ready)begin backpressure=backpressure+1;@(negedge sclk);end
  pixel_wr_addr=address;pixel_wr_data=pattern(image,address);pixel_wr_valid=1;
  @(negedge sclk);pixel_wr_valid=0;
 end endtask
 task finish_frame;
 integer before_done;
 begin
  before_done=done_success;
  @(negedge sclk);frame_end=1;@(negedge sclk);frame_end=0;
  while(done_success==before_done)@(negedge sclk);
  if(error_flags!=0)$fatal(1,"success frame errors=%h",error_flags);
 end endtask
 integer row,col,a,i,oldfailure,oldsuccess,slow_stalls;
 initial begin
  // Exercise asynchronous assertion before the first PHY edge; release remains at73ns.
  srst_n=1;prst_n=1;#1;srst_n=0;prst_n=0;
  #72;srst_n=1;prst_n=1;wait(s_ready);
  if(front_valid || s_front_valid)$fatal(1,"front must start invalid");
  // First image: reversed BMP row order. Burst16 must stop at row jumps.
  begin_frame();
  for(row=479;row>=0;row=row-1)
   for(col=0;col<640;col=col+1)send_pixel(0,row*640+col,6);
  if(front_valid)$fatal(1,"uncommitted first image became visible");
  finish_frame();
  $display("PASS first full307200-pixel image committed only after blank+CDC ack, t=%0t",$time);$fflush();
  while(checked0<307200)@(negedge sclk);
  // Second image uploads concurrently with complete first-image scanout.
  // First2048 pixels use expected SPI spacing200sclk; the remaining upload is
  // accelerated, honoring ready so simulation need not model seconds of SPI.
  begin_frame();slow_stalls=backpressure;
  for(a=0;a<2048;a=a+1)send_pixel(1,a,200);
  if(backpressure!=slow_stalls)$fatal(1,"backpressure at expected SPI producer rate");
  for(a=2048;a<307200;a=a+1)send_pixel(1,a,16);
  if(expected_front!=0)$fatal(1,"front changed before frame_end");
  finish_frame();
  $display("PASS concurrent back upload with front preservation, t=%0t",$time);
  while(checked1<307200)@(negedge sclk);
  // Abort while a real bus write command is in progress; active command must
  // finish, queued data may drop, and complete second front remains unchanged.
  oldfailure=done_failure;oldsuccess=done_success;begin_frame();
  for(i=0;i<128;i=i+1)send_pixel(0,i,1);
  while(dut.state!=dut.WRITE_SEND)@(negedge sclk);
  frame_abort=1;@(negedge sclk);frame_abort=0;
  while(done_failure==oldfailure)@(negedge sclk);
  if(!abort_bus_seen || dut.ctrl_busy)$fatal(1,"abort did not wait for active bus write");
  if(done_success!=oldsuccess || expected_front!=1 || !front_valid)$fatal(1,"abort replaced front");
  if(!error_flags[2])$fatal(1,"abort status not reported");
  // A short successful decoder end must be rejected, never displayed.
  oldfailure=done_failure;begin_frame();for(i=0;i<17;i=i+1)send_pixel(0,i,4);
  frame_end=1;@(negedge sclk);frame_end=0;
  while(done_failure==oldfailure)@(negedge sclk);
  if(!error_flags[1])$fatal(1,"short source frame not rejected");
  // Overflow/protocol violation is explicit and aborts only the back frame.
  oldfailure=done_failure;begin_frame();
  pixel_wr_valid=1;
  for(i=0;i<300;i=i+1)begin pixel_wr_addr=i;pixel_wr_data=pattern(0,i);@(negedge sclk);end
  pixel_wr_valid=0;
  while(done_failure==oldfailure)@(negedge sclk);
  if(!error_flags[0])$fatal(1,"unhonored ready did not report overflow");
  if(expected_front!=1 || done_success!=2)$fatal(1,"failed frame changed visible front");
  $display("PASS full-frame RGB: checked image0=%0d image1=%0d pixels; readbursts=%0d writebursts=%0d",checked0,checked1,read_commands,write_commands);
  $display("PASS bandwidth 50MHzSDRAM/40MHzvideo: no underflow; minFIFO=%0d maxSource=%0d acceleratedBackpressure=%0d",min_video_level,max_source_queue,backpressure);
  $display("PASS abort active-command drain, short-frame rejection, source overflow, reversed rows, repeated blank CDC resets");
  $finish;
 end
 initial begin #700000000;$fatal(1,"framebuffer timeout state=%0d epoch=%0d source=%0d front=%0d done=%0d",dut.state,dut.epoch_state,dut.source_used,expected_front,done_success);end
endmodule
