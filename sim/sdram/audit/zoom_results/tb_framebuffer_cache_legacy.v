`timescale 1ns/1ps
// Actual controller/PHY and independent SDRAM CAS/timing/storage model.
// Four fully uploaded banks, complete scanout, cache hits with no writes.
module tb_framebuffer_cache;
 parameter real PIXEL_HALF_NS=19.84127;
 parameter integer LEGACY_RASTER=0;
 reg sclk=0,pclk=0;wire phy_clk;
 always #10 sclk=~sclk;
 always #(PIXEL_HALF_NS) pclk=~pclk;
 assign #5 phy_clk=sclk;
 reg srst_n=0,prst_n=0,frame_begin=0,pixel_wr_valid=0,frame_end=0,frame_abort=0;
 reg [18:0] pixel_wr_addr=0;reg [23:0] pixel_wr_data=0;
 reg cache_mode=1,swap_only=0;reg [1:0] write_bank=0,swap_bank=0;
 wire pixel_wr_ready,s_ready,frame_done,frame_ok,s_front_valid,busy;
 wire [1:0] s_front_bank;wire [3:0] error_flags;
 reg frame_tick=0,pixel_req=0;wire [23:0]pixel_rgb;
 wire pixel_valid,front_valid,underrun;
 wire [1:0] view_mode=2'bzz; wire [1:0] view_active;
 media_framebuffer dut(.*);
 integer x=0,y=0,requested_addr=0,expected_bank=-1;
 integer successes=0,failures=0,source_writes=0,memory_writes=0,round,b,a,i;
 integer checked[0:3];integer before_success,before_failure,saved_source,saved_writes;
 integer last_bank=-1,scan_count=0,complete_frames=0,saved_physical_writes;
 reg req_sample;integer addr_sample,bank_sample;
 reg raster_enable=1;
 function [23:0] pattern;
 input integer bank;input integer address;
 begin pattern=(address*24'h17359d) ^ (24'h3f70a1+bank*24'h294b17);end
 endfunction
 always @(negedge pclk)if(prst_n && raster_enable)begin
  if(LEGACY_RASTER)begin
   frame_tick=x==0 && y==600;
   pixel_req=x>=80 && x<720 && y>=60 && y<540;
   requested_addr=(y-60)*640+x-80;
   if(x==1055)begin x=0;if(y==627)y=0;else y=y+1;end else x=x+1;
  end else begin
   frame_tick=x==0 && y==490;
   pixel_req=x>=80 && x<720 && y<480;
   requested_addr=y*640+x-80;
   if(x==799)begin x=0;if(y==524)y=0;else y=y+1;end else x=x+1;
  end
 end
 always @(posedge pclk)begin
  req_sample=pixel_req;addr_sample=requested_addr;bank_sample=expected_bank;
  #1;
  if(prst_n && front_valid && req_sample)begin
   if(underrun || !pixel_valid)$fatal(1,"cache display underrun/missing pixel bank=%0d addr=%0d",bank_sample,addr_sample);
   if(pixel_rgb!==pattern(bank_sample,addr_sample))$fatal(1,"cache RGB bank=%0d addr=%0d got=%h expected=%h",bank_sample,addr_sample,pixel_rgb,pattern(bank_sample,addr_sample));
   checked[bank_sample]=checked[bank_sample]+1;
   if(addr_sample==0)begin scan_count=0;last_bank=bank_sample;end
   if(bank_sample!=last_bank || addr_sample!=scan_count)$fatal(1,"noncontiguous scanout");
   scan_count=scan_count+1;
   if(scan_count==307200)complete_frames=complete_frames+1;
  end
  if(prst_n && !req_sample && pixel_valid)$fatal(1,"unsolicited pixel");
 end
 always @(posedge sclk)if(srst_n)begin
  if(pixel_wr_valid && pixel_wr_ready)source_writes=source_writes+1;
  if(dut.cmd_valid && dut.cmd_ready && dut.cmd_write)begin
   memory_writes=memory_writes+1;
   if(s_front_valid && dut.cmd_addr[20:19]==s_front_bank)$fatal(1,"write to visible bank");
  end
  if(frame_done)begin
   if(frame_ok)begin
    successes=successes+1;expected_bank=s_front_bank;
    if(!front_valid || dut.epoch_state!=dut.E_RUN)$fatal(1,"success before pixel acknowledgement");
   end else failures=failures+1;
  end
  if(error_flags[3])$fatal(1,"video FIFO overflow");
 end
 task wait_idle;begin while(busy)@(negedge sclk);end endtask
 task upload;
 input integer bank;
 begin
  wait_idle();@(negedge sclk);write_bank=bank;frame_begin=1;
  @(negedge sclk);frame_begin=0;
  for(a=0;a<307200;a=a+1)begin
   while(!pixel_wr_ready)@(negedge sclk);
   pixel_wr_addr=a;pixel_wr_data=pattern(bank,a);pixel_wr_valid=1;
   @(negedge sclk);pixel_wr_valid=0;
  end
  before_success=successes;frame_end=1;@(negedge sclk);frame_end=0;
  while(successes==before_success)@(negedge sclk);
  if(s_front_bank!=bank || error_flags!=0)$fatal(1,"upload did not publish selected bank=%0d actual=%0d errors=%h",bank,s_front_bank,error_flags);
  $display("PASS upload bank=%0d source=%0d t=%0t",bank,source_writes,$time);$fflush();
 end endtask
 task cached_swap;
 input integer bank;
 begin
  wait_idle();@(negedge sclk);swap_bank=bank;swap_only=1;before_success=successes;
  @(negedge sclk);swap_only=0;
  if(pixel_wr_ready || !busy)$fatal(1,"cache hit opened source or failed to reserve");
  while(successes==before_success)@(negedge sclk);
  if(s_front_bank!=bank || error_flags!=0)$fatal(1,"cache swap wrong bank=%0d actual=%0d error=%h",bank,s_front_bank,error_flags);
 end endtask
 task full_scan;
 integer previous_complete;
 begin previous_complete=complete_frames;while(complete_frames==previous_complete)@(negedge sclk);end
 endtask
 initial begin
  for(i=0;i<4;i=i+1)checked[i]=0;
  srst_n=1;prst_n=1;#1;srst_n=0;prst_n=0;
  #72;srst_n=1;prst_n=1;wait(s_ready);
  for(b=0;b<4;b=b+1)begin upload(b);full_scan();end
  saved_source=source_writes;saved_writes=memory_writes;
  saved_physical_writes=dut.controller.memory.write_tokens;
  // Exercise every bank repeatedly with full 307200-pixel verification per hit.
  for(round=0;round<3;round=round+1)for(b=0;b<4;b=b+1)begin
   cached_swap((b+round)%4);full_scan();
   if(source_writes!=saved_source || memory_writes!=saved_writes ||
      dut.controller.memory.write_tokens!=saved_physical_writes)$fatal(1,"cache hit issued pixel/memory write");
   $display("PASS cache hit round=%0d bank=%0d complete_frames=%0d t=%0t",round,(b+round)%4,complete_frames,$time);$fflush();
  end
  // Freeze raster away from a blank event, queue hit, then abort before commit.
  @(negedge pclk);raster_enable=0;frame_tick=0;pixel_req=0;
  wait_idle();before_failure=failures;b=s_front_bank;
  @(negedge sclk);swap_bank=(b+1)%4;swap_only=1;
  @(negedge sclk);swap_only=0;
  repeat(4)@(negedge sclk);
  if(!dut.commit_pending)$fatal(1,"fast swap not pending");
  frame_abort=1;@(negedge sclk);frame_abort=0;
  while(failures==before_failure)@(negedge sclk);
  if(s_front_bank!=b || !error_flags[2])$fatal(1,"aborted fast swap changed visible front");
  // Reject a second swap while the first is pending, preserving its target.
  before_success=successes;
  @(negedge sclk);swap_bank=(b+1)%4;swap_only=1;
  @(negedge sclk);swap_only=0;
  repeat(3)@(negedge sclk);
  swap_bank=(b+2)%4;swap_only=1;@(negedge sclk);swap_only=0;
  if(!error_flags[0] || dut.candidate_bank!=(b+1)%4)$fatal(1,"overlapping swap changed candidate");
  // Commit at a manual blank, then abort after physical selection: actual swap wins.
  @(negedge pclk);frame_tick=1;@(negedge pclk);frame_tick=0;
  while(!dut.swap_waiting)@(negedge sclk);
  frame_abort=1;@(negedge sclk);frame_abort=0;
  while(successes==before_success)@(negedge sclk);
  if(s_front_bank!=(b+1)%4)$fatal(1,"post-commit abort rolled back visible front");
  if(source_writes!=saved_source || memory_writes!=saved_writes)$fatal(1,"swap/abort generated writes");
  for(b=0;b<4;b=b+1)if(checked[b]<4*307200)$fatal(1,"insufficient full-bank scanout bank=%0d pixels=%0d",b,checked[b]);
  $display("PASS framebuffer_cache four banks actual SDRAM timing/storage, complete_frames=%0d writes=%0d source=%0d",complete_frames,memory_writes,source_writes);
  $display("PASS framebuffer_cache zero-write hits, all-bank RGB, pending abort, overlapping reject, post-commit abort; pclk_half=%0fns",PIXEL_HALF_NS);
  $finish;
 end
 initial begin #1200000000;$fatal(1,"cache timeout state=%0d epoch=%0d front=%0d success=%0d",dut.state,dut.epoch_state,s_front_bank,successes);end
endmodule
