`timescale 1ns/1ps
module tb_media_cancel_ctrl;
 reg clk=0; always #5 clk=~clk;
 reg rst=0,frame=0; reg [3:0] keys=0,longs=0;
 reg busy=0,valid=1,done=0,front=1,req_ready=1; reg [1:0] error=0;
 wire req,cancel,auto_run,settings; wire [1:0] mode; wire [3:0] fade;
 integer requests=0,cancels=0,n;
 media_ctrl #(.FPS(4),.SEQUENCE_FRAMES(2),.LOCK_FRAMES(1)) dut(
 .clk(clk),.rst_n(rst),.frame_tick(frame),.keys(keys),.longs(longs),
 .cat_ready(1'b1),.image_busy(busy),.image_valid(valid),.load_done(done),
 .image_error(error),.file_count(6'd3),.seq_count(6'd2),.shown_index(6'd0),
 .req_ready(req_ready),.fb_front_valid(front),.load_req(req),.cancel_req(cancel),
 .media_mode(mode),.media_auto(auto_run),.media_settings(settings),.gal_fade(fade));
 always @(posedge clk) begin #1; if(rst) begin
 if(req) requests=requests+1; if(cancel) cancels=cancels+1;
 if(req && cancel) $fatal(1,"request and cancel overlap"); end end
 task step; input f; input [3:0] k; begin
 @(negedge clk); frame=f;keys=k; @(negedge clk);frame=0;keys=0;
 repeat(2) @(negedge clk); end endtask
 task reset_case; begin
 @(negedge clk);rst=0;busy=0;valid=1;done=0;front=1;error=0;req_ready=1;
 repeat(3) @(negedge clk); requests=0;cancels=0;rst=1;
 repeat(3) @(negedge clk); end endtask
 task start_back; begin
 n=0;while(requests==0 && n<10) begin step(1,0); n=n+1;end
 if(requests!=1) $fatal(1,"missing automatic request"); busy=1;valid=0;
 end endtask
 task cancelled_done; begin
 @(negedge clk);busy=0;valid=1;done=1;
 @(negedge clk);done=0;repeat(3) @(negedge clk);end endtask
 initial begin
 reset_case;start_back;step(0,4);
 if(auto_run || cancels!=1 || fade!=8) $fatal(1,"WAIT pause must cancel and retain front immediately");
 step(0,2);step(0,1);step(0,4);step(0,4);step(0,8);
 if(mode!=1 || cancels!=1 || requests!=1) $fatal(1,"manual or mode change duplicated cancel/load while draining");
 cancelled_done;
 repeat(12) step(1,0);
 if(requests!=1 || fade!=8) $fatal(1,"cancelled pause unexpectedly advances");
 // A fresh transaction can be cancelled by K4 and mode changes immediately.
 reset_case;start_back;step(0,8);
 if(mode!=1 || auto_run || cancels!=1) $fatal(1,"WAIT mode key delayed or failed to cancel");
 cancelled_done;repeat(12) step(1,0);
 if(requests!=1) $fatal(1,"mode cancellation restarted automatically");
 // Exact BLACK launch cycle: mode key suppresses the queued automatic request.
 reset_case;req_ready=0;step(1,0);step(1,0);step(1,0);
 @(negedge clk);req_ready=1;frame=1;keys=8;
 @(negedge clk);frame=0;keys=0;repeat(2)@(negedge clk);
 if(requests!=0 || cancels!=0 || mode!=1 || fade!=8) $fatal(1,"BLACK mode key did not suppress request");
 repeat(12) step(1,0);if(requests) $fatal(1,"hidden queued mode transition");
 // HOLD deadline also gives mode change priority over automatic scheduling.
 reset_case;step(1,0);step(1,8);repeat(12) step(1,0);
 if(requests || cancels) $fatal(1,"HOLD deadline mode key left automatic transition");
 // A cancelled read can still be draining across RPG entry and long-K4 return.
 // Pause on its completion must override the queued restart, including same-cycle assignments.
 reset_case;start_back;step(0,8);step(0,8);
 @(negedge clk);longs=8;@(negedge clk);longs=0;
 repeat(2)@(negedge clk);
 if(mode!=0 || !auto_run) $fatal(1,"RPG return path changed");
 @(negedge clk);busy=0;valid=1;done=1;keys=4;
 @(negedge clk);done=0;keys=0;
 repeat(12) step(1,0);
 if(auto_run || requests!=1 || cancels!=1) $fatal(1,"pause completion edge left queued RPG restart");
 // Settings and first image retain their existing key meanings.
 reset_case;start_back;@(negedge clk);longs=8;@(negedge clk);longs=0;
 step(0,4);if(cancels || !auto_run || !settings) $fatal(1,"settings K3 cancelled load");
 reset_case;front=0;start_back;step(0,4);
 if(cancels || auto_run) $fatal(1,"unbuffered pause changed legacy completion behavior");
 $display("PASS media_cancel_ctrl WAIT/pause/mode/queued/deadline/settings/legacy");$finish;
 end
 initial begin #100000;$fatal(1,"controller cancellation timeout");end
endmodule
