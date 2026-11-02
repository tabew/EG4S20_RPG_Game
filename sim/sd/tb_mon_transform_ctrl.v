`timescale 1ns/1ps
// Public-event atomicity plus production raw-key debounce/media controls.
module tb_mon_transform_ctrl;
 reg clk=0;always #5 clk=~clk;
 reg rst_n=1,frame_tick=0,battle=0,rot=0,mir=0;
 wire [1:0] rotation;wire mirror;
 mon_transform_ctrl direct(.clk(clk),.rst_n(rst_n),.frame_tick(frame_tick),.battle_active(battle),.rotate_step(rot),.mirror_toggle(mir),.rotation(rotation),.mirror(mirror));
 reg [1:0] rr=0,ar=0;reg rm=0,am=0;integer public_checks=0;
 always @(posedge clk)begin
  if(!rst_n)begin rr=0;rm=0;ar=0;am=0;end
  else begin
   if(battle)begin if(rot)rr=rr+1'b1;if(mir)rm=!rm;end
   if(frame_tick)begin ar=rr;am=rm;end
   #1;if(rotation!==ar || mirror!==am)$fatal(1,"atomic controller got %0d/%0d expected %0d/%0d",rotation,mirror,ar,am);
   public_checks=public_checks+1;
  end
 end
 task event_clock;
 input b,r,m,f;
 begin @(negedge clk);battle=b;rot=r;mir=m;frame_tick=f;@(negedge clk);rot=0;mir=0;frame_tick=0;end
 endtask
 reg [3:0] raw=15;wire [3:0] swapped={raw[0],raw[1],raw[2],raw[3]};wire [3:0] clicks,longs;
 genvar k;
 generate for(k=0;k<4;k=k+1)begin:keys
  key_debounce #(.CLK_KHZ(20),.DEB_MS(1),.HOLD_MS(8)) kd(.clk(clk),.rst_n(rst_n),.key_n(swapped[k]),.click(clicks[k]),.press(),.long_press(longs[k]));
 end endgenerate
 reg raw_frame=0;wire [1:0] mode,view;wire on,block,settings,mute,auto_run;
 wire load_req,cancel;wire [5:0] index;wire [3:0] fade;
 media_ctrl #(.LOCK_FRAMES(0),.VISUAL_DEFAULT(0)) media(.clk(clk),.rst_n(rst_n),.frame_tick(raw_frame),.keys(clicks),.longs(longs),
  .cat_ready(1'b1),.image_busy(1'b0),.image_valid(1'b1),.load_done(1'b0),.image_error(2'd0),.file_count(6'd3),.seq_count(6'd2),.shown_index(6'd0),.req_ready(1'b1),.fb_front_valid(1'b1),
  .load_req(load_req),.cancel_req(cancel),.load_index(index),.media_mode(mode),.media_auto(auto_run),.media_settings(settings),.media_mute(mute),.media_view(view),.gal_on(on),.gal_block(block),.gal_fade(fade));
 reg [3:0] scene=0;reg mon_on=0;
 wire enabled=!on&&!block&&scene==3&&mon_on;
 wire [1:0] raw_rotation;wire raw_mirror;
 mon_transform_ctrl actual(.clk(clk),.rst_n(rst_n),.frame_tick(raw_frame),.battle_active(enabled),.rotate_step(longs[0]),.mirror_toggle(longs[1]),.rotation(raw_rotation),.mirror(raw_mirror));
 integer short_total=0,long_total=0,c1=0,c2=0,c3=0,c4=0;
 always @(posedge clk)if(rst_n)begin
  if(|clicks)short_total=short_total+1;
  if(|longs)long_total=long_total+1;
  if(!block)begin
   if(clicks[0])c1=c1+1;if(clicks[1])c2=c2+1;if(clicks[2])c3=c3+1;if(clicks[3])c4=c4+1;
  end
 end
 task press;
 input integer logical_key,hold;
 integer shorts_before,longs_before;
 begin
  shorts_before=short_total;longs_before=long_total;
  @(negedge clk);raw[3-logical_key]=0;
  repeat(hold)@(negedge clk);
  raw[3-logical_key]=1;repeat(100)@(negedge clk);
  if(hold==60)begin
   if(short_total!=shorts_before+1 || long_total!=longs_before)$fatal(1,"raw short key classification key%0d",logical_key+1);
  end else if(short_total!=shorts_before || long_total!=longs_before+1)$fatal(1,"raw long release leaked short key%0d",logical_key+1);
 end endtask
 task blank;
 begin @(negedge clk);raw_frame=1;@(negedge clk);raw_frame=0;repeat(3)@(negedge clk);end
 endtask
 task orientation;
 input integer r,m;
 begin if(raw_rotation!==r[1:0] || raw_mirror!==m[0])$fatal(1,"raw orientation got%0d/%0d expected%0d/%0d",raw_rotation,raw_mirror,r,m);end
 endtask
 reg old_mute,old_auto;reg [1:0] old_view;integer a,b,c,d,i;
 initial begin
  #1;rst_n=0;#28;rst_n=1;repeat(100)@(negedge clk);
  // Disabled scene events ignored, including when blank coincides.
  event_clock(0,1,1,1);if(rotation!=0||mirror)$fatal(1,"disabled events changed identity");
  // Multiple requests accumulate before blank; output remains whole-frame held.
  event_clock(1,1,0,0);event_clock(1,1,1,0);event_clock(1,1,1,0);
  if(rotation!=0||mirror)$fatal(1,"output changed before blank");
  event_clock(1,1,1,1);if(rotation!=0||!mirror)$fatal(1,"sameclock event not committed or modulo incorrect");
  event_clock(0,1,1,1);if(rotation!=0||!mirror)$fatal(1,"scene changed saved preference");
  event_clock(1,0,1,1);if(rotation!=0||mirror)$fatal(1,"two mirror events not identity");
  // MEDIA/SETTINGS/GALLERY cannot change the monster settings.
  press(0,320);press(1,320);blank;orientation(0,0);
  press(3,320);if(!settings)$fatal(1,"settings did not open");
  press(0,320);press(1,320);blank;orientation(0,0);
  old_mute=mute;press(2,320);if(mute!==!old_mute)$fatal(1,"settings longK3 mute");
  press(3,60);if(settings)$fatal(1,"settings did not close");
  press(3,60);if(mode!=1)$fatal(1,"gallery not selected");
  press(0,320);press(1,320);blank;orientation(0,0);
  press(3,60);if(mode!=2 || on || block)$fatal(1,"RPG not active");
  // Title/camp and absent monster ignore transform input.
  mon_on=1;scene=0;press(0,320);press(1,320);blank;orientation(0,0);
  scene=1;press(0,320);press(1,320);blank;orientation(0,0);
  scene=3;mon_on=0;press(0,320);press(1,320);blank;orientation(0,0);
  mon_on=1;if(!enabled)begin repeat(2)@(negedge clk);end
  a=c1;b=c2;c=c3;d=c4;
  press(0,320);orientation(0,0);press(1,320);orientation(0,0);blank;orientation(1,1);
  if(c1!=a||c2!=b||c3!=c||c4!=d)$fatal(1,"battle long1/2 leaked attack/skill");
  for(i=0;i<3;i=i+1)press(0,320);
  press(1,320);blank;orientation(0,0);
  press(0,320);press(0,320);press(1,320);blank;orientation(2,1);
  // All original short actions remain untouched.
  a=c1;b=c2;c=c3;d=c4;
  for(i=0;i<4;i=i+1)press(i,60);
  blank;orientation(2,1);
  if(c1!=a+1||c2!=b+1||c3!=c+1||c4!=d+1)$fatal(1,"short combat action remapping");
  scene=1;press(0,320);press(1,320);blank;orientation(2,1);
  scene=3;blank;orientation(2,1);
  old_mute=mute;old_auto=auto_run;old_view=view;press(2,320);blank;orientation(2,1);
  if(mute!==!old_mute||auto_run!==old_auto||view!==old_view)$fatal(1,"RPG global longK3 regression");
  press(3,320);blank;orientation(2,1);
  if(mode!=0||!on)$fatal(1,"RPG global longK4 exit regression");
  $display("PASS mon_transform_ctrl rawmapping/short-actions/long-no-click/scene-gating/frame-atomic/modulo/persistence/globalK3K4 checks=%0d shorts=%0d longs=%0d",public_checks,short_total,long_total);$finish;
 end
 initial begin #500000;$fatal(1,"monster control timeout");end
endmodule
