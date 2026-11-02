`timescale 1ns/1ps
module tb_media_cancel_cdc;
 reg pc=0,sc=0;always #3 pc=~pc;always #17 sc=~sc;
 reg rst=0,req=0,cancel=0;reg [5:0] index=0;
 wire ready,go,cgo;wire [5:0] sindex;
 integer loads=0,cancels=0,n,i;reg [5:0] last_index;
 media_cdc dut(.pclk(pc),.prst_n(rst),.sclk(sc),.srst_n(rst),
 .p_req(req),.p_cancel(cancel),.p_index(index),.p_req_ready(ready),
 .s_load_go(go),.s_cancel_go(cgo),.s_load_index(sindex),
 .s_cat_ready(1'b1),.s_busy(1'b0),.s_valid(1'b1),.s_done(1'b0),
 .s_error(2'd0),.s_count(6'd3),.s_seq_count(6'd2),.s_shown(6'd0),
 .s_name(64'd0),.s_diag(8'd0),.s_panel(8'd0),.s_fill(1'b0));
 always @(posedge sc) if(rst) begin
 if(go && cgo) $fatal(1,"CDC load and cancellation overlap");
 if(go) begin loads=loads+1;last_index=sindex;end
 if(cgo) cancels=cancels+1;end
 task idle_bridge;begin
 n=0;while(!ready && n<200)begin @(negedge pc);n=n+1;end
 if(!ready)$fatal(1,"CDC command bridge failed to acknowledge");end endtask
 initial begin
 repeat(5)@(negedge sc);rst=1;
 // Every cancellation is one source cycle while the preceding load is unacked.
 for(i=0;i<24;i=i+1)begin
 idle_bridge;@(negedge pc);req=1;index=i;
 @(negedge pc);req=0;index=63;cancel=1;
 if(ready)$fatal(1,"test did not exercise busy command bridge");
 @(negedge pc);cancel=0;
 n=0;while((loads!=i+1 || cancels!=i+1) && n<200)begin @(negedge pc);n=n+1;end
 if(loads!=i+1 || cancels!=i+1 || last_index!==i[5:0])$fatal(1,"lost/torn/duplicate busy-bridge cancel %0d",i);
 idle_bridge;repeat(15)@(negedge pc);
 if(loads!=i+1 || cancels!=i+1)$fatal(1,"CDC event repeated after acknowledgement");
 end
 // Simultaneous request/cancel gives cancellation priority, with no stale index.
 idle_bridge;@(negedge pc);req=1;cancel=1;index=41;
 @(negedge pc);req=0;cancel=0;
 repeat(50)@(negedge pc);
 if(loads!=24 || cancels!=25)$fatal(1,"CDC simultaneous cancel priority failed");
 $display("PASS media_cancel_cdc busy bridge queued pulse, bundled command, cancel priority");$finish;
 end
 initial begin #100000;$fatal(1,"CDC cancellation timeout");end
endmodule
