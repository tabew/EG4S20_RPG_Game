`timescale 1ns/1ps
// Exercise user-visible pause semantics solely through the controller's public pins.
// Frame ticks and loader completion are independent: a load can span many frames.
module tb_media_pause;
 reg clk=0; always #5 clk=~clk;
 reg rst_n=0,frame_tick=0;
 reg [3:0] keys=0,longs=0;
 reg cat_ready=0,image_busy=1,image_valid=0,load_done=0,req_ready=1;
 reg [1:0] image_error=0;
 reg [5:0] file_count=3,seq_count=2,shown_index=0;
 wire load_req,media_auto,media_settings,gal_on,gal_block,media_loading;
 wire [5:0] load_index;
 wire [1:0] media_mode,media_view;
 wire [3:0] gal_fade;
 media_ctrl #(.FPS(4),.GALLERY_SEC(1),.SEQUENCE_FRAMES(2),.FADE_FRAMES(1),.LOCK_FRAMES(1)) dut(
  .clk(clk),.rst_n(rst_n),.frame_tick(frame_tick),.keys(keys),.longs(longs),
  .cat_ready(cat_ready),.image_busy(image_busy),.image_valid(image_valid),.load_done(load_done),
  .image_error(image_error),.file_count(file_count),.seq_count(seq_count),.shown_index(shown_index),
  .req_ready(req_ready),.load_req(load_req),.load_index(load_index),.media_mode(media_mode),
  .media_auto(media_auto),.media_settings(media_settings),.media_view(media_view),
  .gal_fade(gal_fade),.gal_on(gal_on),.gal_block(gal_block),.media_loading(media_loading));
 integer failures=0,requests=0;
 reg [5:0] last_index=0;
 always @(posedge clk) begin
  #1;
  if(!rst_n) begin requests=0;last_index=0;end
  else if(load_req) begin
   requests=requests+1;last_index=load_index;
   if(gal_fade!==0 || !media_loading) begin
    $display("FAIL media_pause request exposed before black/load mask");failures=failures+1;
   end
  end
 end
 task check;input condition;input [8*160-1:0] message;begin
  if(condition!==1'b1)begin $display("FAIL media_pause %0s",message);failures=failures+1;end
 end endtask
 task step;input frame;input [3:0] short_keys;input [3:0] long_keys;begin
  @(negedge clk);frame_tick=frame;keys=short_keys;longs=long_keys;
  @(negedge clk);frame_tick=0;keys=0;longs=0;
  repeat(2)@(negedge clk);
 end endtask
 task tick;begin step(1,0,0);end endtask
 task click;input [3:0] value;begin step(0,value,0);end endtask
 task reset_case;begin
  @(negedge clk);rst_n=0;frame_tick=0;keys=0;longs=0;
  cat_ready=0;image_busy=1;image_valid=0;load_done=0;image_error=0;
  shown_index=0;file_count=3;seq_count=2;req_ready=1;
  repeat(3)@(negedge clk);rst_n=1;repeat(2)@(negedge clk);
 end endtask
 task boot_image;begin
  @(negedge clk);cat_ready=1;image_busy=0;image_valid=1;
  repeat(3)@(negedge clk);
 end endtask
 task boot_hold;begin reset_case;boot_image;tick;end endtask
 task quiet_frames;input integer count;input [8*160-1:0] message;integer before_count,n;begin
  before_count=requests;
  for(n=0;n<count;n=n+1)tick;
  check(requests==before_count,message);
 end endtask
 task expect_request;input [5:0] wanted;integer before_count,n;begin
  before_count=requests;n=0;
  while(requests==before_count && n<40)begin tick;n=n+1;end
  check(requests==before_count+1 && last_index==wanted,"resume must issue exactly one request for the next image");
 end endtask
 task complete_load;input [5:0] which;begin
  @(negedge clk);image_busy=0;image_valid=1;shown_index=which;image_error=0;load_done=1;
  @(negedge clk);load_done=0;repeat(2)@(negedge clk);
 end endtask
 integer before_count,i;
 reg saved_auto;
 initial begin
  // A click before catalog readiness, including a boot load longer than a dwell.
  reset_case;click(4);
  check(!media_auto,"BOOT/loading K3 must pause even before catalog readiness");
  cat_ready=1;quiet_frames(10,"boot pause must not start another load while busy");
  boot_image;quiet_frames(14,"boot pause must survive initial image completion");
  check(gal_fade==8,"paused boot image must become fully visible");
  click(4);check(media_auto,"boot pause must resume on the next K3");
  expect_request(1);

  // Once accepted, a request is allowed to finish; a pause prevents the next one.
  boot_hold;expect_request(1);
  image_busy=1;image_valid=0;
  quiet_frames(9,"in-flight load must not issue duplicate requests");
  click(4);check(!media_auto,"WAIT/loading K3 must pause");
  quiet_frames(9,"paused in-flight load must remain the only request");
  before_count=requests;complete_load(1);
  quiet_frames(14,"WAIT pause must allow current completion without scheduling an extra image");
  check(shown_index==1 && gal_fade==8 && requests==before_count,"current load must remain displayed after WAIT pause");
  click(4);check(media_auto,"WAIT pause must resume");expect_request(0);

  // Pause during initial sequence fade in: the current picture still becomes visible.
  reset_case;boot_image;click(4);
  check(!media_auto,"sequence fade-in K3 must pause");
  quiet_frames(14,"sequence fade-in pause must prevent next load");
  check(gal_fade==8,"sequence fade-in pause must restore a visible image");

  // The dwell has expired, but no load has been issued: cancel the pending advance.
  boot_hold;tick;tick;click(4);
  check(!media_auto,"sequence fade-out K3 must pause");
  quiet_frames(14,"sequence fade-out pause must cancel pending transition");
  check(gal_fade==8 && shown_index==0,"sequence fade-out cancellation must retain current picture");
  click(4);expect_request(1);

  // K3 shares the exact frame that would otherwise launch the black-screen load.
  boot_hold;tick;tick;tick;
  before_count=requests;step(1,4,0);
  check(!media_auto && requests==before_count,"BLACK same-frame pause must suppress load_req");
  quiet_frames(14,"BLACK cancellation must not defer a hidden request");
  check(gal_fade==8,"BLACK cancellation must restore current image visibility");

  // The pause has priority over an automatic advance on the dwell deadline itself.
  boot_hold;tick;step(1,4,0);
  check(!media_auto,"HOLD deadline K3 must pause");
  quiet_frames(14,"HOLD deadline pause must override automatic scheduling");
  check(gal_fade==8,"HOLD deadline pause must keep the current image visible");

  // Gallery uses gradual fades. Cancel a partially faded outgoing image, then resume.
  boot_hold;click(8);check(media_mode==1 && !media_auto,"gallery must enter paused");
  click(4);for(i=0;i<4;i=i+1)tick;tick;
  check(gal_fade>0 && gal_fade<8,"gallery test must reach a partial outgoing fade");
  click(4);check(!media_auto,"gallery outgoing fade K3 must pause");
  quiet_frames(20,"gallery outgoing pause must cancel pending load");
  check(gal_fade==8,"gallery outgoing pause must restore full brightness");
  click(4);expect_request(1);image_busy=1;image_valid=0;
  complete_load(1);tick;
  check(gal_fade>0 && gal_fade<8,"gallery test must reach a partial incoming fade");
  click(4);check(!media_auto,"gallery incoming fade K3 must pause");
  quiet_frames(20,"gallery incoming pause must finish fade without advancing");
  check(gal_fade==8,"gallery incoming pause must retain a visible image");
  click(4);expect_request(2);

  // A failed boot load remains pausable, and resuming retries the next slot.
  reset_case;
  @(negedge clk);cat_ready=1;image_busy=0;image_error=3;
  repeat(3)@(negedge clk);click(4);
  check(!media_auto,"error screen K3 must pause");
  quiet_frames(20,"paused error screen must not schedule a retry");
  click(4);check(media_auto,"error screen K3 must resume");expect_request(1);

  // Pause also overrides the exact frame when an error retry becomes due.
   reset_case;
   @(negedge clk);cat_ready=1;image_busy=0;image_error=3;
   repeat(3)@(negedge clk);for(i=0;i<7;i=i+1)tick;
   step(1,4,0);check(!media_auto,"ERROR deadline K3 must pause");
   quiet_frames(20,"ERROR deadline pause must cancel the scheduled retry");

   // Settings owns short K3, even if the image loader is busy.
  reset_case;step(0,0,8);saved_auto=media_auto;
  check(media_settings,"settings must open during boot");
  click(4);check(media_view==1 && media_auto==saved_auto,"settings K3 must change view without pausing");
  click(4);check(media_view==2 && media_auto==saved_auto,"settings K3 must keep cycling view without pausing");
  click(4);check(media_view==0 && media_auto==saved_auto,"settings K3 view must wrap without pausing");

  // RPG owns short K3; returning to media still uses the existing long-key path.
  boot_hold;click(8);click(8);saved_auto=media_auto;
  check(media_mode==2 && !gal_on,"RPG mode must be selected");
  click(4);check(media_mode==2 && media_auto==saved_auto && !media_settings,"RPG short K3 must leave media controls untouched");
  step(0,0,8);check(media_mode==0 && media_auto && gal_on,"RPG long K4 return must still restart sequence");

  if(failures!=0)$fatal(1,"media_pause failures=%0d",failures);
  $display("PASS media_pause BOOT/WAIT/resume/sequence-fades/BLACK/deadline/gallery/settings/RPG");
  $finish;
 end
 initial begin #500000;$fatal(1,"media_pause timeout");end
endmodule
