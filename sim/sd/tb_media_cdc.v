`timescale 1ns/1ps
module tb_media_cdc;
 reg pc=0,sc=0;always #7 pc=~pc;always #5 sc=~sc;
 reg pr=0,sr=0,req=0;reg[5:0]idx=0;
 wire ready,go;wire[5:0]sidx;
 reg cat=0,busy=0,valid=0,done=0;reg[1:0]error=0;
 reg[5:0]count=0,seq=0,shown=0;reg[63:0]name=0;
 reg[7:0]dbg1=0,dbg2=0;reg dbgfill=0;wire[7:0]pdbg1,pdbg2;wire pdbgfill;
 wire pcat,pbusy,pvalid,pdone;wire[1:0]perror;wire[5:0]pcount,pseq,pshown;wire[63:0]pname;
 media_cdc dut(.pclk(pc),.prst_n(pr),.sclk(sc),.srst_n(sr),.p_req(req),.p_index(idx),.p_req_ready(ready),
 .s_load_go(go),.s_load_index(sidx),.s_cat_ready(cat),.s_busy(busy),.s_valid(valid),.s_done(done),
 .s_error(error),.s_count(count),.s_seq_count(seq),.s_shown(shown),.s_name(name),
 .s_diag(dbg1),.s_panel(dbg2),.s_fill(dbgfill),.p_diag(pdbg1),.p_panel(pdbg2),.p_fill(pdbgfill),
 .p_cat_ready(pcat),.p_busy(pbusy),.p_valid(pvalid),.p_done(pdone),.p_error(perror),.p_count(pcount),.p_seq_count(pseq),.p_shown(pshown),.p_name(pname));
 integer go_count=0,done_count=0,iteration,n;
 reg[5:0]last_sidx;
 always@(posedge sc)if(go)begin go_count=go_count+1;last_sidx=sidx;end
 always@(posedge pc)if(pdone)done_count=done_count+1;
 function[63:0]filename;input[5:0]value;reg[7:0]ch;begin ch=8'h41+value;filename={8{ch}};end endfunction
 task wait_snapshot;input[5:0]wanted;input[1:0]want_error;begin
  n=0;while((pshown!==wanted || perror!==want_error || pname!==filename(wanted) || pbusy || !pcat) && n<200)begin @(negedge pc);n=n+1;end
  if(n>=200)$fatal(1,"snapshot incoherent shown%0d expected%0d name%h",pshown,wanted,pname);
  if(pcount!==32 || pseq!==4 || pvalid!==(want_error==0))$fatal(1,"snapshot status torn");
   if(pdbg1!==(8'ha5^{2'd0,wanted}) || pdbg2!==(8'h3c^{2'd0,wanted}) || pdbgfill!==wanted[0])$fatal(1,"diagnostic snapshot torn");
 end endtask
 integer before_go,before_done;
 initial begin
  repeat(5)@(negedge pc);pr=1;sr=1;
  @(negedge sc);cat=1;count=32;seq=4;shown=0;name=filename(0);valid=1;dbg1=8'ha5;dbg2=8'h3c;dbgfill=0;
  wait_snapshot(0,0);
  for(iteration=0;iteration<32;iteration=iteration+1)begin
   n=0;while(!ready&&n<100)begin@(negedge pc);n=n+1;end
   before_go=go_count;
   @(negedge pc);idx=iteration;req=1;
   @(negedge pc);req=0;idx=63;
   n=0;while(go_count==before_go&&n<100)begin@(negedge pc);n=n+1;end
   if(go_count!=before_go+1 || last_sidx!==iteration[5:0])$fatal(1,"request crossed incorrectly iteration%0d",iteration);
   @(negedge sc);busy=1;valid=0;
   repeat(15)@(negedge sc);
   before_done=done_count;
   @(negedge sc);shown=iteration;name=filename(iteration);error=(iteration%7==6)?3:0;valid=(error==0);busy=0;done=1;dbg1=8'ha5^iteration;dbg2=8'h3c^iteration;dbgfill=iteration[0];
   @(negedge sc);done=0;
   n=0;while(done_count==before_done&&n<200)begin@(negedge pc);n=n+1;end
   if(done_count!=before_done+1)$fatal(1,"completion lost or duplicated");
   wait_snapshot(iteration,(iteration%7==6)?3:0);
   repeat(8)@(negedge pc);
   if(go_count!=before_go+1 || done_count!=before_done+1)$fatal(1,"duplicate CDC event");
  end
  $display("PASS media_cdc asynchronous bundled snapshots and32 requests/completions");$finish;
 end
 initial begin #500000;$fatal(1,"CDC timeout");end
endmodule
