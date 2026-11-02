`timescale 1ns/1ps
module tb_buffered_media;
 reg clk=0;always #5 clk=~clk;
 reg rst=0,frame=0;reg[3:0]keys=0,longs=0;
 reg cat=0,busy=1,valid=0,done=0,front=0;reg[1:0]err=0;reg[5:0]shown=0;
 wire req,on,block,loading,auto_run,settings,visual;wire[5:0]index;wire[1:0]mode,view;wire[3:0]fade;
 media_ctrl dut(.clk(clk),.rst_n(rst),.frame_tick(frame),.keys(keys),.longs(longs),.cat_ready(cat),.image_busy(busy),.image_valid(valid),.load_done(done),.image_error(err),
 .file_count(6'd3),.seq_count(6'd2),.shown_index(shown),.req_ready(1'b1),.fb_front_valid(front),.load_req(req),.load_index(index),.media_mode(mode),.media_auto(auto_run),
 .media_settings(settings),.media_visual(visual),.media_view(view),.gal_fade(fade),.gal_on(on),.gal_block(block),.media_loading(loading));
 integer requests=0,n,old;
 always@(posedge clk)begin #1;if(rst&&req)begin requests=requests+1;if(!loading||fade!=8)$fatal(1,"buffered swap hid visible front");end end
 task tick;begin @(negedge clk);frame=1;@(negedge clk);frame=0;repeat(2)@(negedge clk);end endtask
 task key;input[3:0]v;begin@(negedge clk);keys=v;@(negedge clk);keys=0;repeat(2)@(negedge clk);end endtask
 task want_request;input[5:0]v;begin old=requests;n=0;while(requests==old&&n<40)begin tick;n=n+1;end if(requests!=old+1||index!=v)$fatal(1,"request expected%0d actual%0d",v,index);end endtask
 task finish;input[5:0]v;begin@(negedge clk);busy=0;valid=1;shown=v;done=1;@(negedge clk);done=0;repeat(3)@(negedge clk);end endtask
 initial begin
  repeat(4)@(negedge clk);rst=1;@(negedge clk);cat=1;busy=0;valid=1;front=1;
  repeat(4)@(negedge clk);if(fade!=8)$fatal(1,"first committed frame not shown immediately");
  want_request(1);busy=1;key(4);if(auto_run)$fatal(1,"pause during SDRAM load lost");
  for(n=0;n<12;n=n+1)begin tick;if(fade!=8)$fatal(1,"old front faded while loading");end
  finish(1);old=requests;repeat(12)tick;if(requests!=old||fade!=8)$fatal(1,"paused commit advanced or blacked");
  key(4);want_request(0);finish(0);
  key(8);if(mode!=1||auto_run)$fatal(1,"gallery not paused");
  old=requests;key(2);if(requests!=old+1||index!=1||auto_run)$fatal(1,"manual gallery request must issue immediately and pause");finish(1);if(fade!=8)$fatal(1,"gallery swap blacked");
  @(negedge clk);longs=8;@(negedge clk);longs=0;repeat(3)@(negedge clk);
  if(!settings)$fatal(1,"settings entry");old=visual;
   key(4);if(view!=1||visual!=old||auto_run)$fatal(1,"buffered K3 must select 2x without bars/pause side effects");
   key(4);if(view!=2||visual!=old||auto_run)$fatal(1,"buffered K3 must select 4x without bars/pause side effects");
   key(4);if(view!=0||visual!=old||auto_run)$fatal(1,"buffered K3 must wrap to 1x without bars/pause side effects");
   @(negedge clk);longs=2;@(negedge clk);longs=0;repeat(3)@(negedge clk);
   if(visual==old||view!=0||!settings)$fatal(1,"long K2 must retain independent bars toggle");
  $display("PASS buffered_media continuousfront/pause/commit/gallery/settings requests=%0d",requests);$finish;
 end
 initial begin #100000;$fatal(1,"buffered controller timeout");end
endmodule
