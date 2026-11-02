`timescale 1ns/1ps
// Production debounce and top-level physical column mapping, accelerated ms only.
module tb_media_zoom_key;
 reg clk=0;always #5 clk=~clk;
 reg rst_n=0,front=1;
 reg [3:0] key_n=15;
 wire [3:0] key_swap={key_n[0],key_n[1],key_n[2],key_n[3]};
 wire [3:0] clicks,longs;
 wire auto_run,settings,visual,mute,req,cancel;
 wire [1:0] view,mode;
 integer i,j,short_count=0,long_count=0,expected_short=0,expected_long=0;
 reg previous_mute,previous_auto,previous_visual;
 genvar k;
 generate for(k=0;k<4;k=k+1)begin:raw_keys
  key_debounce #(.CLK_KHZ(2),.DEB_MS(1),.HOLD_MS(20)) debounce(
   .clk(clk),.rst_n(rst_n),.key_n(key_swap[k]),.click(clicks[k]),.press(),.long_press(longs[k]));
 end endgenerate
 media_ctrl #(.VISUAL_DEFAULT(0)) dut(.clk(clk),.rst_n(rst_n),.frame_tick(1'b0),
  .keys(clicks),.longs(longs),.cat_ready(1'b1),.image_busy(1'b0),.image_valid(1'b1),.load_done(1'b0),
  .image_error(2'd0),.file_count(6'd3),.seq_count(6'd2),.shown_index(6'd0),.req_ready(1'b1),
  .fb_front_valid(front),.load_req(req),.cancel_req(cancel),.media_mode(mode),.media_auto(auto_run),
  .media_settings(settings),.media_visual(visual),.media_mute(mute),.media_view(view));
 always @(posedge clk)if(rst_n)begin
  if(clicks[2])short_count=short_count+1;
  if(longs[2])long_count=long_count+1;
 end
 task raw_press;
  input integer logical_key,cycles;
  begin
   @(negedge clk);key_n[3-logical_key]=0;
   repeat(cycles)@(negedge clk);
   key_n[3-logical_key]=1;repeat(20)@(negedge clk);
  end
 endtask
 task short_k3;
  begin
   raw_press(2,12);expected_short=expected_short+1;
   if(short_count!=expected_short || long_count!=expected_long)$fatal(1,"raw short K3 pulse classification");
  end
 endtask
 task long_k3;
  input integer wanted_view;
  begin
   previous_mute=mute;previous_auto=auto_run;previous_visual=visual;
   raw_press(2,120);expected_long=expected_long+1;
   if(short_count!=expected_short || long_count!=expected_long)$fatal(1,"long K3 release leaked a short click or repeated long pulse");
   if(mute!==!previous_mute || auto_run!==previous_auto || visual!==previous_visual || view!==wanted_view)
    $fatal(1,"long K3 must only toggle mute at view=%0d settings=%b",wanted_view,settings);
   if(req || cancel)$fatal(1,"long K3 generated loader traffic");
  end
 endtask
 initial begin
  repeat(4)@(negedge clk);rst_n=1;repeat(10)@(negedge clk);
  if(view!=0 || !auto_run || mute || visual)$fatal(1,"media defaults");
  // Both framebuffer and legacy preview keep the historical three-state control.
  for(j=0;j<2;j=j+1)begin
   front=(j==0);raw_press(3,120);
   if(!settings)$fatal(1,"physical long K4 settings entry");
   for(i=0;i<3;i=i+1)begin
    if(view!=i)$fatal(1,"settings view order");
    long_k3(i);
    previous_visual=visual;short_k3;
    if(view!=((i==2)?0:i+1) || visual!==previous_visual || !settings || !auto_run)
     $fatal(1,"physical settings short K3 failed zoom cycle or changed bars/auto");
   end
   previous_visual=visual;raw_press(1,120);
   if(visual!==!previous_visual || view!=0 || !settings)$fatal(1,"long K2 bars toggle");
   raw_press(3,12);if(settings)$fatal(1,"physical short K4 settings exit");
   // Exercise mute with every saved view outside settings too.
   for(i=0;i<3;i=i+1)begin
    long_k3(i);short_k3;if(auto_run)$fatal(1,"normal short K3 pause");
    long_k3(i);short_k3;if(!auto_run)$fatal(1,"normal short K3 resume");
    raw_press(3,120);short_k3;raw_press(3,12);
    if(settings || view!=((i==2)?0:i+1))$fatal(1,"saved zoom selection");
   end
  end
  if(mode!=0)$fatal(1,"key release changed media mode");
  // Keep a non-default zoom saved while the original RPG owns the keys.
  raw_press(3,120);short_k3;raw_press(3,12);
  raw_press(3,12);raw_press(3,12);
  if(mode!=2 || settings || view!=1)$fatal(1,"RPG entry must preserve saved view");
  long_k3(1);long_k3(1);
  previous_auto=auto_run;previous_mute=mute;short_k3;
  if(mode!=2 || view!=1 || auto_run!==previous_auto || mute!==previous_mute)
   $fatal(1,"RPG short K3 was stolen by media control");
  $display("PASS media_zoom_key: real raw key_n mapping, buffered+legacy 0/1/2 wrap, pause/resume, global long mute incl RPG (%0d shorts/%0d longs)",short_count,long_count);
  $finish;
 end
 initial begin #100000;$fatal(1,"zoom key timeout");end
endmodule
