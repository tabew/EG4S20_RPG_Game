`timescale 1ns/1ps
module tb_frame_publication;
 reg clk=0;always #5 clk=~clk;
 reg rst=0,start=0,fdone=0,fok=0,ddone=0,dvalid=0,front=0;
 reg go=0,cancel=0,cancelled=0;
 reg[1:0]derr=0;reg[5:0]idx=0;reg[63:0]name=0;
 wire fend,fabort,pending,pvalid,pdone;wire[1:0]perr;wire[5:0]pidx;wire[63:0]pname;
 publication_dut dut(.clk_mem50(clk),.rst_n50(rst),.fb_start(start),.fb_frame_done(fdone),.fb_frame_ok(fok),.sd_load_done(ddone),.tf_valid50(dvalid),.fb_s_front_valid(front),
 .sd_load_go(go),.sd_cancel_go(cancel),.sd_load_cancelled(cancelled),.tf_err50(derr),.sd_shown_index(idx),.sd_shown_name(name),.fb_frame_end(fend),.fb_frame_abort(fabort),.publication_pending(pending),.published_valid(pvalid),.published_done(pdone),.published_error(perr),.published_index(pidx),.published_name(pname));
 integer ends=0,aborts=0,publications=0;
 always@(posedge clk)begin #1;if(fend)ends=ends+1;if(fabort)aborts=aborts+1;if(pdone)publications=publications+1;end
 task begin_image;input[5:0]i;begin @(negedge clk);idx=i;name={58'd0,i};go=1;start=1;@(negedge clk);go=0;start=0;end endtask
 task decode;input[1:0]e;begin @(negedge clk);derr=e;dvalid=e==0;ddone=1;@(negedge clk);ddone=0;end endtask
 task finish;input okay;begin @(negedge clk);fok=okay;fdone=1;@(negedge clk);fdone=0;repeat(4)@(negedge clk);end endtask
 initial begin
  repeat(4)@(negedge clk);rst=1;
  begin_image(1);decode(0);repeat(10)@(negedge clk);
  if(publications!=0 || pvalid || ends!=1 || !pending)$fatal(1,"decoded image exposed before vblank physical commit");
  front=1;finish(1);
  if(publications!=1 || !pvalid || pidx!=1 || pname!=1 || perr!=0)$fatal(1,"successful commit metadata");
  begin_image(2);finish(0); // early SDRAM error; decoder has not finished yet
  if(publications!=1)$fatal(1,"early framebuffer error published before decoder completion");
  decode(0);repeat(5)@(negedge clk);
  if(publications!=2 || perr!=3 || pidx!=1 || !pvalid || ends!=1)$fatal(1,"early abort lost or oldfront not retained");
  idx=3;decode(3);repeat(3)@(negedge clk);
  if(aborts!=1 || publications!=2)$fatal(1,"format failure must wait for aborted writes to drain");
  finish(0);if(publications!=3 || perr!=3 || pidx!=1)$fatal(1,"format failure recovery metadata");
  begin_image(4);@(negedge clk);derr=0;dvalid=1;ddone=1;fdone=1;fok=1;
  @(negedge clk);ddone=0;fdone=0;repeat(5)@(negedge clk);
  if(publications!=4 || pidx!=4 || pname!=4 || perr!=0 || ends!=1 || aborts!=1)$fatal(1,"simultaneous decode+vblank must publish exactlyonce");
  // A user cancel during decode must wait only for the decoder sector stop,
  // abort the back frame, and report success with the old visible metadata.
  begin_image(5);@(negedge clk);cancel=1;@(negedge clk);cancel=0;
  if(aborts!=1)$fatal(1,"memory aborted before decoder stopped");
  @(negedge clk);cancelled=1;derr=0;dvalid=0;ddone=1;
  @(negedge clk);cancelled=0;ddone=0;repeat(3)@(negedge clk);
  if(ends!=1||aborts!=2)$fatal(1,"cancelled load incorrectly requested frame commit");
  finish(0);if(publications!=5||perr!=0||pidx!=4||!pvalid)$fatal(1,"cancel must retain visible frame without ERROR");
  // Raw decoding may already be done when the cancel arrives; abort before swap.
  begin_image(6);decode(0);repeat(2)@(negedge clk);
  @(negedge clk);cancel=1;@(negedge clk);cancel=0;repeat(3)@(negedge clk);
  if(aborts!=3||ends!=2)$fatal(1,"publication-only cancel must abort pending swap");
  finish(0);if(publications!=6||pidx!=4||perr!=0)$fatal(1,"pending swap cancellation metadata");
  // If vblank has already switched, keep the new actually-visible metadata.
  begin_image(7);decode(0);
  @(negedge clk);cancel=1;fdone=1;fok=1;
  @(negedge clk);cancel=0;fdone=0;repeat(5)@(negedge clk);
  if(publications!=7||pidx!=7||perr!=0)$fatal(1,"completed swap incorrectly rolled filename back");
  begin_image(8);decode(0);finish(1);
  if(publications!=8||pidx!=8||perr!=0)$fatal(1,"cancel leaked into next load");
  $display("PASS frame_publication delayedcommit/earlyabort/formatfailure/samecycle/cancellation frontretention");$finish;
 end
endmodule
