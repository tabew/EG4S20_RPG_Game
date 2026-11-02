`timescale 1ns/1ps
// Public-event broker unit. Deliberately no DUT hierarchy, force, RAM, PHY or SPI.
module tb_frame_cache;
 reg clk=0; always #10 clk=~clk; // production memory clock: 50 MHz
 reg rst_n=0,request_go=0,cancel_go=0,cat_ready=0;
 reg[5:0] request_index=0;
 reg raw_busy=0,raw_done=0,raw_cancelled=0,raw_valid=0;
 reg[1:0] raw_error=0;reg[5:0]raw_index=0;reg[63:0]raw_name=0;
 reg frame_begin=0,frame_done=0,frame_ok=0,front_valid=0;
 reg[1:0]front_bank=0;
 wire decode_go,swap_only,frame_end,frame_abort,publication_pending,transaction_busy;
 wire published_valid,published_done;wire[1:0]published_error,write_bank,swap_bank;
 wire[5:0]decode_index,published_index;wire[63:0]published_name;
 wire[15:0]cache_hits,cache_misses;
 media_frame_cache #(.ENABLE_CACHE(1)) dut(
  .clk(clk),.rst_n(rst_n),.request_go(request_go),.request_index(request_index),.cancel_go(cancel_go),
  .cat_ready(cat_ready),.raw_busy(raw_busy),.raw_done(raw_done),.raw_cancelled(raw_cancelled),
  .raw_valid(raw_valid),.raw_error(raw_error),.raw_index(raw_index),.raw_name(raw_name),
  .frame_begin(frame_begin),.frame_done(frame_done),.frame_ok(frame_ok),.front_valid(front_valid),.front_bank(front_bank),
  .decode_go(decode_go),.decode_index(decode_index),.write_bank(write_bank),.swap_only(swap_only),.swap_bank(swap_bank),
  .frame_end(frame_end),.frame_abort(frame_abort),.publication_pending(publication_pending),.transaction_busy(transaction_busy),
  .published_valid(published_valid),.published_done(published_done),.published_error(published_error),
  .published_index(published_index),.published_name(published_name),.cache_hits(cache_hits),.cache_misses(cache_misses));
 integer decodes=0,swaps=0,ends=0,aborts=0,publications=0;
 integer i,k,n,d,s,e,a,mask;reg[1:0]selected,remembered,victim,old_front;
 reg[1:0]bank_for[0:63];reg[5:0]old_index;reg[63:0]old_name;
 reg[255:0]case_name;
 always @(posedge clk) begin
  #1;
  if(rst_n) begin
   if(decode_go)decodes=decodes+1;
   if(swap_only)swaps=swaps+1;
   if(frame_end)ends=ends+1;
   if(frame_abort)aborts=aborts+1;
   if(published_done)publications=publications+1;
   if(decode_go && swap_only)$fatal(1,"decode and cached swap both requested");
  end
 end
 function[63:0]file_name;input[5:0]idx;begin file_name=64'h4341434845303000+idx;end endfunction
 task check;input okay;input[639:0]message;begin
  if(!okay)begin $display("FAIL frame_cache %0s: %0s",case_name,message);$fatal(1,"contract violation");end
 end endtask
 task idle;input integer cycles;begin repeat(cycles)@(negedge clk);end endtask
 task reset;begin
  rst_n=0;request_go=0;cancel_go=0;cat_ready=0;raw_busy=0;raw_done=0;
  raw_cancelled=0;raw_valid=0;raw_error=0;frame_begin=0;frame_done=0;frame_ok=0;
  front_valid=0;front_bank=0;idle(3);rst_n=1;idle(2);cat_ready=1;idle(2);
  decodes=0;swaps=0;ends=0;aborts=0;publications=0;mask=0;
 end endtask
 task snapshot;begin n=publications;old_index=published_index;old_name=published_name;end endtask
 task unchanged;begin
  check(publications==n,"metadata published before framebuffer acknowledgement");
  check(published_index==old_index && published_name==old_name,"visible metadata changed before acknowledgement");
 end endtask
 task request_miss;input[5:0]idx;begin
  d=decodes;s=swaps;request_index=idx;request_go=1;idle(1);request_go=0;
  check(decodes==d+1 && swaps==s,"miss must pulse decoder only once");
  check(decode_index==idx && transaction_busy,"miss decoder index / busy");
  selected=write_bank;check(selected!=front_bank,"miss selected actual front for overwrite");
  idle(2);check(decodes==d+1,"decoder go held longer than one clock");
 end endtask
 task request_hit;input[5:0]idx;begin
  d=decodes;s=swaps;request_index=idx;request_go=1;idle(1);request_go=0;
  check(swaps==s+1 && decodes==d,"cache hit read TF / failed to request swap only");
  selected=swap_bank;check(selected==bank_for[idx],"hit selected bank different from observed fill");
  check(transaction_busy && publication_pending,"hit not held busy pending physical swap");
  idle(2);check(decodes==d && swaps==s+1,"hit generated later decoder load / repeated swap");
 end endtask
 task start_frame;begin frame_begin=1;raw_busy=1;idle(1);frame_begin=0;idle(1);end endtask
 task decode_finish;input[5:0]idx;input[1:0]error;input valid;input was_cancelled;begin
  raw_index=idx;raw_name=file_name(idx);raw_error=error;raw_valid=valid;
  raw_cancelled=was_cancelled;raw_done=1;raw_busy=0;idle(1);raw_done=0;raw_cancelled=0;idle(2);
 end endtask
 task cancel;begin cancel_go=1;idle(1);cancel_go=0;idle(2);end endtask
 task ack;input okay;begin
  // Every successful fake physical ack uses the bank the DUT actually selected.
  if(okay)begin front_bank=selected;front_valid=1;end
  frame_ok=okay;frame_done=1;idle(1);frame_done=0;idle(3);
 end endtask
 task visible;input[5:0]idx;begin
  check(publications==n+1 && published_valid && !transaction_busy && !publication_pending,"publication completion / actual front validity");
  check(published_index==idx && published_name==file_name(idx) && published_error==0,"published filename/index does not describe visible bank");
 end endtask
 task fill;input[5:0]idx;input boot;begin
  snapshot;
  if(boot)begin selected=write_bank;check(selected!=front_bank,"boot selected front");end
  else request_miss(idx);
  remembered=selected;start_frame;decode_finish(idx,0,1,0);unchanged;
  check(publication_pending && frame_end==0,"decode completion not waiting for swap");
  idle(3);unchanged;ack(1);visible(idx);bank_for[idx]=remembered;
 end endtask
 task hit;input[5:0]idx;begin
  snapshot;request_hit(idx);
  // A cached swap must use stored metadata, even with unrelated decoder outputs.
  raw_index=63;raw_name=file_name(63);idle(3);unchanged;
  ack(1);visible(idx);
 end endtask
 task seed_four;begin
  reset;
  for(k=10;k<14;k=k+1)begin
   fill(k,k==10);
   check((mask & (1<<bank_for[k]))==0,"cold fills reused a valid bank before all four filled");
   mask=mask | (1<<bank_for[k]);
  end
  check(mask==15 && cache_misses==4 && cache_hits==0 && decodes==3,"four cold fills / boot autoload counters");
 end endtask
 task cancelled_finish;input[5:0]idx;input header;begin
  if(header)start_frame;
  snapshot;a=aborts;cancel;
  check(aborts==a,"streaming cancellation must wait for decoder drain/raw_done");
  e=ends;decode_finish(idx,0,0,1);
  check(aborts==a+1 && ends==e,"cancelled decoder did not request abort");
  unchanged;ack(0);
  check(publications==n+1 && published_index==old_index && published_name==old_name && published_valid && published_error==0,"cancel changed actual visible metadata");
 end endtask
 initial begin
  if(!$value$plusargs("CASE=%s",case_name))case_name="cold_hits";
  if(case_name=="cold_hits")begin
   seed_four;
   for(i=10;i<14;i=i+1)hit(i);
   for(i=13;i>=10;i=i-1)hit(i);
   check(cache_hits==8 && cache_misses==4 && decodes==3 && swaps==8 && publications==12,"TF bypass / forward-reverse counters");
  end else if(case_name=="ack_guard")begin
   reset;fill(10,1);snapshot;request_miss(11);start_frame;decode_finish(11,0,1,0);
   old_front=front_bank;check(selected!=old_front,"ack guard requires distinct observed banks");
   // frame_done can lead the synchronized actual-front bank indication.
   frame_ok=1;frame_done=1;idle(1);frame_done=0;idle(3);unchanged;
   front_bank=selected;front_valid=0;idle(3);unchanged;
   front_valid=1;idle(3);visible(11);
   bank_for[11]=selected;bank_for[10]=old_front;
   snapshot;request_hit(10);frame_ok=1;frame_done=1;idle(1);frame_done=0;idle(3);unchanged;
   front_bank=selected;idle(3);visible(10);
  end else if(case_name=="lru")begin
   seed_four;hit(10);hit(12);hit(11); // recency: 11,12,10,13; front 11 protected
   snapshot;request_miss(14);check(selected==bank_for[13],"LRU must evict oldest nonfront after hits");
   remembered=selected;start_frame;decode_finish(14,0,1,0);ack(1);visible(14);bank_for[14]=remembered;
   hit(10);hit(12);hit(11);hit(14);
   request_miss(13);check(selected==bank_for[10],"LRU order lost after eviction/refill");
   check(selected!=front_bank,"front slot not protected during eviction");
  end else if(case_name=="cancel_before")begin
   seed_four;request_miss(20);victim=selected;
   cancelled_finish(20,0);
   for(i=10;i<14;i=i+1)hit(i);
   check(cache_misses==5 && cache_hits==4,"cancel before header destroyed victim metadata");
  end else if(case_name=="cancel_partial")begin
   seed_four;request_miss(20);victim=selected;
   cancelled_finish(20,1);
   for(i=10;i<14;i=i+1)if(bank_for[i]!=victim)hit(i);
   for(i=10;i<14;i=i+1)if(bank_for[i]==victim)begin
    request_miss(i);check(selected==victim,"partial slot must be invalid and reusable");
   end
  end else if(case_name=="cancel_hit")begin
   seed_four;snapshot;request_hit(10);cancel;
   check(aborts==1,"cancelled cache hit must abort pending swap");ack(0);
   check(publications==n+1 && published_index==old_index && published_name==old_name && published_error==0,"cancelled hit changed metadata");
   for(i=10;i<14;i=i+1)hit(i);
   // Physical swap wins a simultaneous cancellation; do not roll metadata back.
   snapshot;request_hit(11);cancel_go=1;ack(1);cancel_go=0;visible(11);
   snapshot;cancel;idle(3);unchanged; // cancellation after commit must keep actual metadata
   hit(10);
  end else if(case_name=="cancel_after_raw")begin
   reset;fill(10,1);snapshot;request_miss(11);start_frame;decode_finish(11,0,1,0);
   a=aborts;cancel;check(aborts==a+1,"cancel after raw_done did not abort publication now");
   ack(0);check(publications==n+1 && published_index==10 && published_error==0,"late cancel did not retain old front");
   fill(12,0); // next command must clear previous cancellation
   snapshot;request_miss(13);start_frame;decode_finish(13,0,1,0);
   cancel_go=1;ack(1);cancel_go=0;visible(13);
  end else if(case_name=="failures")begin
   reset;fill(10,1);
   snapshot;request_miss(11);start_frame;ack(0);unchanged;
   e=ends;a=aborts;decode_finish(11,0,1,0);idle(3);
   check(publications==n+1 && published_error==3 && published_index==10 && ends==e && aborts==a,"early framebuffer failure lost / redundant end");
   snapshot;request_miss(12);e=ends;a=aborts;decode_finish(12,3,0,0);
   unchanged;check(aborts==a+1 && ends==e,"wrong header without frame_begin must abort idle framebuffer");ack(0);
   check(publications==n+1 && published_error==3 && published_index==10,"wrong header publication");
   snapshot;request_miss(13);start_frame;a=aborts;decode_finish(13,2,0,0);unchanged;ack(0);
   check(publications==n+1 && published_error==2 && published_index==10 && aborts==a+1,"raw decoder error not preserved");
   fill(14,0);
  end else if(case_name=="card_epoch")begin
   seed_four;old_front=front_bank;old_index=published_index;old_name=published_name;
   cat_ready=0;idle(4);
   check(front_valid && front_bank==old_front && published_valid && published_index==old_index && published_name==old_name,"card removal clobbered actual displayed frame");
   check(write_bank!=old_front,"first new-card autoload would overwrite visible bank");
   cat_ready=1;idle(2);snapshot;request_miss(13);remembered=selected;
   // The same numeric index from the new card must decode, despite old visible metadata.
   start_frame;decode_finish(13,0,1,0);ack(1);visible(13);bank_for[13]=remembered;
   for(i=10;i<13;i=i+1)begin
    request_miss(i);cancelled_finish(i,0);
   end
   check(cache_hits==0 && cache_misses==8,"old card index survived new-card epoch");
  end else if(case_name=="cancel_reset")begin
   seed_four;request_miss(20);cancelled_finish(20,1);
   snapshot;request_miss(21);start_frame;e=ends;a=aborts;decode_finish(21,0,1,0);
   check(ends==e+1 && aborts==a,"new request did not clear decoder cancellation");ack(1);visible(21);
   bank_for[21]=selected;hit(21);
  end else $fatal(1,"unknown CASE");
  $display("PASS frame_cache %0s decodes=%0d swaps=%0d ends=%0d aborts=%0d pubs=%0d hits=%0d misses=%0d",case_name,decodes,swaps,ends,aborts,publications,cache_hits,cache_misses);
  $finish;
 end
 initial begin #1000000;$fatal(1,"frame cache unit timeout");end
endmodule
