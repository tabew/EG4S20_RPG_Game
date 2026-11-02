`timescale 1ns/1ps
module tb_media_ctrl;
 reg clk=0;always #5 clk=~clk;
 reg rst_n=0,frame_tick=0;
 reg [3:0]keys=0,longs=0;
 reg cat_ready=0,image_busy=1,image_valid=0,load_done=0;
 reg [1:0]image_error=0;
 reg [5:0]file_count=3,seq_count=2,shown_index=0;
 wire req,gal_on,gal_block,loading,auto_run,settings,osd,visual,mute;
 wire [5:0]index;
 wire [1:0]mode,contrast,view;
 wire [3:0]brightness,fade;
 media_ctrl #(.FPS(4),.GALLERY_SEC(1),.SEQUENCE_FRAMES(2),.FADE_FRAMES(1),.LOCK_FRAMES(1)) dut(
 .clk(clk),.rst_n(rst_n),.frame_tick(frame_tick),.keys(keys),.longs(longs),
 .cat_ready(cat_ready),.image_busy(image_busy),.image_valid(image_valid),.load_done(load_done),
 .image_error(image_error),.file_count(file_count),.seq_count(seq_count),.shown_index(shown_index),.req_ready(1'b1),
 .load_req(req),.load_index(index),.media_mode(mode),.media_auto(auto_run),.media_settings(settings),
 .media_osd(osd),.media_visual(visual),.media_mute(mute),.media_brightness(brightness),
 .media_contrast(contrast),.media_view(view),.gal_fade(fade),.gal_on(gal_on),.gal_block(gal_block),.media_loading(loading));
 integer requests=0;reg [5:0]last_index;
 always @(posedge clk) if(req) begin
  requests=requests+1;last_index=index;
  if(fade!=0 || !loading) $fatal(1,"cache write request before complete black/load mask");
 end
 task tick;begin @(negedge clk);frame_tick=1;@(negedge clk);frame_tick=0;repeat(2)@(negedge clk);end endtask
 task click;input[3:0]value;begin @(negedge clk);keys=value;@(negedge clk);keys=0;repeat(2)@(negedge clk);end endtask
 task hold;input[3:0]value;begin @(negedge clk);longs=value;@(negedge clk);longs=0;repeat(2)@(negedge clk);end endtask
 task expect_request;input[5:0]wanted;integer n,before_count;begin
  before_count=requests;n=0;
  while(requests==before_count && n<30)begin tick;n=n+1;end
  if(requests!=before_count+1 || last_index!==wanted)$fatal(1,"request expected%0d got%0d count%0d",wanted,last_index,requests);
 end endtask
 task finish_load;input[5:0]which;input fail;begin
  image_busy=1;image_valid=0;repeat(6)@(negedge clk);
  if(!loading || fade!=0)$fatal(1,"loading not hidden");
  image_busy=0;if(!fail)shown_index=which;image_valid=!fail;image_error=fail?3:0;
  load_done=1;@(negedge clk);load_done=0;repeat(2)@(negedge clk);
 end endtask
 integer i;
 initial begin
  repeat(5)@(negedge clk);rst_n=1;
  if(!gal_on || mode!=0)$fatal(1,"must boot into sequence");
  repeat(8)@(negedge clk);cat_ready=1;image_busy=0;image_valid=1;
  repeat(3)@(negedge clk);tick;tick;
  expect_request(1);finish_load(1,0);tick;tick;
  expect_request(0);finish_load(0,0);tick;tick;
  click(8);if(mode!=1 || auto_run)$fatal(1,"gallery must enter paused");
  click(1);expect_request(2);finish_load(2,1);
  if(!gal_on)$fatal(1,"failed image must retain usable gallery");
  click(1);expect_request(1);finish_load(1,0);for(i=0;i<11;i=i+1)tick;
  if(fade!=8)$fatal(1,"gallery did not fade in");
  hold(8);if(!settings)$fatal(1,"settings entry");
  click(1);click(2);click(4);
  if(brightness!=5 || contrast!=2 || view!=1)$fatal(1,"settings not changed");
  click(8);if(settings)$fatal(1,"settings exit");
  hold(1);hold(2);hold(4);
  if(osd || visual || !mute)$fatal(1,"long key toggles");
  click(8);if(mode!=2 || gal_on)$fatal(1,"RPG entry");
  tick;if(gal_block)$fatal(1,"RPG key lock failed to release");
  click(1);if(mode!=2)$fatal(1,"RPG short key stolen");
  hold(8);if(mode!=0 || !gal_on)$fatal(1,"RPG return");
  expect_request(0);finish_load(0,0);tick;
  // With no ANIM group, sequence uses the full catalog.
  seq_count=0;shown_index=2;tick;
  expect_request(0);finish_load(0,0);tick;
  expect_request(1);finish_load(1,1); // shown_index stays0 on corruption
  expect_request(2);finish_load(2,0); // must skip bad1, not retry it forever
  $display("PASS media_ctrl boot/sequence/gallery/settings/RPG/black/error/fallback/skip requests=%0d",requests);$finish;
 end
 initial begin #200000;$fatal(1,"controller timeout");end
endmodule
