`timescale 1ns/1ps
// Navigation assertions use only public controller pins and command counts.
module tb_media_navigation;
 reg clk=0;always #5 clk=~clk;
 reg rst_n=0,frame_tick=0;reg[3:0]keys=0,longs=0;
 reg cat_ready=0,image_busy=1,image_valid=0,load_done=0,req_ready=1,front=0;
 reg[1:0]image_error=0;reg[5:0]file_count=5,seq_count=3,shown_index=0;
 wire req,cancel,auto_run,loading,settings,on;wire[5:0]index;wire[1:0]mode;wire[3:0]fade;
 media_ctrl #(.FPS(4),.SEQUENCE_FRAMES(2),.LOCK_FRAMES(1)) dut(
 .clk(clk),.rst_n(rst_n),.frame_tick(frame_tick),.keys(keys),.longs(longs),
 .cat_ready(cat_ready),.image_busy(image_busy),.image_valid(image_valid),.load_done(load_done),
 .image_error(image_error),.file_count(file_count),.seq_count(seq_count),.shown_index(shown_index),
 .req_ready(req_ready),.fb_front_valid(front),.load_req(req),.cancel_req(cancel),.load_index(index),
 .media_mode(mode),.media_auto(auto_run),.media_settings(settings),.gal_on(on),.gal_fade(fade),.media_loading(loading));
 integer requests=0,cancels=0;reg[5:0]last=0;
 always @(posedge clk) begin #1;
  if(!rst_n)begin requests=0;cancels=0;last=0;end
  else begin
   if(req)begin
    requests=requests+1;last=index;
    if(!req_ready || image_busy || !cat_ready)$fatal(1,"request without readiness");
    if(front && (fade!=8 || !loading))$fatal(1,"buffered front hidden on request");
   end
   if(cancel)cancels=cancels+1;
   if(front && fade!=8)$fatal(1,"visible front faded");
   if(req && cancel)$fatal(1,"load and cancel share command clock");
  end
 end
 task check;input condition;input[8*120-1:0]message;begin
  if(condition!==1'b1)$fatal(1,"%0s (requests=%0d cancels=%0d last=%0d)",message,requests,cancels,last);
 end endtask
 task step;input[3:0]k;input f;input done;begin
  @(negedge clk);keys=k;frame_tick=f;load_done=done;
  @(negedge clk);keys=0;frame_tick=0;load_done=0;
 end endtask
 task quiet;begin repeat(4)@(negedge clk);end endtask
 task reset_case;begin
  @(negedge clk);rst_n=0;keys=0;longs=0;frame_tick=0;load_done=0;
  cat_ready=0;image_busy=1;image_valid=0;image_error=0;front=0;req_ready=1;
  file_count=5;seq_count=3;shown_index=0;
  repeat(3)@(negedge clk);rst_n=1;quiet;
 end endtask
 task boot;begin reset_case;cat_ready=1;image_busy=0;image_valid=1;front=1;quiet;end endtask
 initial begin
  boot;
  step(2,0,0);check(requests==1 && last==1 && !auto_run,"manual next must issue immediately and pause auto");
  image_busy=1;step(2,0,0);check(cancels==1 && requests==1,"second next must cancel once");
  step(2,0,0);check(cancels==1,"third next must not duplicate cancel");
  step(1,0,0);check(cancels==1,"opposite key retains single cancel"); // cursor 1 ->2 ->0 ->2
  image_busy=0;step(0,0,1);check(requests==2 && last==2,"completion must immediately issue latest wrapped target");
  image_busy=1;step(1,0,0);check(cancels==2,"new inflight request gets its own cancel");
  image_busy=0;step(2,0,1);check(requests==3 && last==2 && cancels==2,"same-cycle key must beat older pending target");
  image_busy=1;step(2,0,0);req_ready=0;image_busy=0;step(0,0,1);quiet;
  check(requests==3,"pending request must wait for command readiness");
  req_ready=1;quiet;check(requests==4 && last==0,"pending target survives completion and delayed ready");
  image_busy=1;step(2,0,0);step(1,0,0);image_busy=0;step(8,0,1);quiet;
  check(mode==1 && requests==4,"mode change on completion clears queued target");
  step(2,0,0);check(requests==5 && last==1,"gallery navigation must use full catalog from visible frame");
  image_busy=1;step(2,0,0);image_busy=0;step(4,0,1);
  check(auto_run && requests==5,"K3 resumes paused manual load without same-cycle restart");
  quiet;check(requests==6 && last==2,"resume retains pending manual destination");
  image_busy=1;step(4,0,0);check(!auto_run && cancels==6,"K3 pause cancels resumed read once");
  image_busy=0;step(0,0,1);quiet;check(requests==6,"pause clears old manual destination");
  // Auto back read first manual step is based on shown_index, not load_index.
  boot;step(0,1,0);step(0,1,0);check(requests==1 && last==1,"auto buffered request has no raster delay");
  image_busy=1;image_error=3;step(1,0,0);check(cancels==1 && !auto_run,"manual during auto read acknowledges immediately");
  image_busy=0;image_error=0;step(0,0,1);check(requests==2 && last==2,"first previous during auto prefetch uses visible index0 even with old error metadata");
  // A completion may carry busy until the following status update.
  image_busy=1;step(1,0,0);step(0,0,1);quiet;check(requests==2,"busy snapshot must defer pending load");
  image_busy=0;quiet;check(requests==3 && last==1,"busy release must issue exactly once without frame tick");
  // Bootstrap has no safe front to retain; queue navigation without cancellation.
  reset_case;step(2,0,0);step(2,0,0);check(!auto_run && requests==0 && cancels==0,"boot keys queue without cancelling bootstrap");
  cat_ready=1;quiet;check(requests==0,"catalog alone cannot interrupt bootstrap");
  image_busy=0;image_valid=1;front=1;step(0,0,1);quiet;
  check(requests==1 && last==2 && cancels==0,"boot completion dispatches accumulated manual cursor");
  // Error navigation and fallback catalog wrap remain usable.
  boot;image_error=3;image_valid=1;shown_index=0;step(1,0,0);
  check(requests==1 && last==2,"error previous wraps sequence");
  image_busy=0;shown_index=2;image_error=0;step(0,0,1);quiet;seq_count=0;
  step(1,0,0);check(requests==2 && last==1,"fallback previous uses visible frame after completed manual");
  image_busy=1;step(1,0,0);step(1,0,0);image_busy=0;step(0,0,1);
  check(requests==3 && last==4,"fallback wraps against file_count");
  // K4 beats navigation when simultaneous, and RPG owns short keys.
  image_busy=1;step(10,0,0);image_busy=0;step(0,0,1);quiet;
  check(mode==1 && requests==3,"K4 priority clears manual destination");
  step(8,0,0);step(2,0,0);quiet;check(mode==2 && requests==3,"RPG preserves key ownership");
  // Catalog snapshots start with zero counts. Retain signed early steps until
  // the actual sequence limit arrives, without touching the bootstrap request.
  reset_case;file_count=0;seq_count=0;step(1,0,0);step(1,0,0);step(2,0,0);
  check(!auto_run && requests==0 && cancels==0,"zero-count boot must acknowledge all manual steps");
  cat_ready=1;file_count=5;seq_count=3;repeat(8)@(negedge clk);
  check(requests==0 && cancels==0,"pre-catalog navigation must not cancel bootstrap");
  front=1;image_valid=1;image_busy=0;step(0,0,1);quiet;
  check(requests==1 && last==2,"early previous/previous/next normalizes to sequence last");
  // A queued request and a new key share req_ready release: issue the new target
  // exactly once. K1 wins simultaneous K1/K2, as in the original controller.
  boot;req_ready=0;step(2,0,0);step(2,0,0);quiet;
  check(requests==0 && !auto_run,"manual destination queues while command channel occupied");
  @(negedge clk);req_ready=1;keys=3;
  @(negedge clk);keys=0;quiet;
  check(requests==1 && last==1,"new key on readiness release beats older pending target");
  image_busy=0;shown_index=1;step(0,0,1);quiet;
  check(requests==1,"completed queued navigation must not be issued twice");
  boot;req_ready=0;step(2,0,0);
  @(negedge clk);req_ready=1;keys=8;
  @(negedge clk);keys=0;quiet;
  check(mode==1 && requests==0,"mode on ready release must suppress old pending request");
  // Resuming auto must still drain the acknowledged manual queue first,
  // including the short interval where an early destination is normalizing.
  reset_case;file_count=0;seq_count=0;repeat(20)step(2,0,0);
  cat_ready=1;file_count=5;seq_count=3;front=1;image_valid=1;image_busy=0;
  step(4,0,0);check(auto_run,"K3 resumes during pre-catalog target normalization");
  frame_tick=1;repeat(4)@(negedge clk);frame_tick=0;
  check(requests==0,"resumed auto cannot overtake unresolved manual destination");
  repeat(8)@(negedge clk);
  check(requests==1 && last==2,"normalized manual destination precedes automatic playback");
  $display("PASS media_navigation immediate/queue/cursor/wrap/opposite/same-cycle/ready/busy/boot-zero-count/error/mode/K3");$finish;
 end
 initial begin #100000;$fatal(1,"navigation timeout");end
endmodule
