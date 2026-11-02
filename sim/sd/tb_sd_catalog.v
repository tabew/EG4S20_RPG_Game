`timescale 1ns/1ps
// Public-interface catalog/load regression. No DUT forces or internal state probes.
module tb_sd_catalog;
  reg clk=0; always #5 clk=~clk;
  reg rst_n=0, init_done=0, init_err=0, load_go=0;
  reg [5:0] load_index=0;
  wire init_go, rd_go, tw_wren, tf_valid, cat_ready, busy, load_done;
  wire [31:0] rd_addr;
  reg [7:0] dout=0;
  reg dvalid=0, blk_done=0;
  wire [15:0] tw_addr, src_width, src_height;
  wire [3:0] tw_data;
  wire [1:0] tf_err, fdiag;
  wire [7:0] dbg;
  wire [5:0] file_count, seq_count, shown_index;
  wire [63:0] shown_name;
  sd_img #(.RETRY_TICKS(128)) dut(.clk(clk),.rst_n(rst_n),.init_go(init_go),.init_done(init_done),
    .init_err(init_err),.rd_go(rd_go),.rd_addr(rd_addr),.dout(dout),
    .dvalid(dvalid),.blk_done(blk_done),.tw_addr(tw_addr),.tw_data(tw_data),
    .tw_wren(tw_wren),.tf_valid(tf_valid),.tf_err(tf_err),.fdiag(fdiag),.dsel(3'd7),.dbg(dbg),
    .load_go(load_go),.load_index(load_index),.file_count(file_count),.seq_count(seq_count),
    .shown_index(shown_index),.shown_name(shown_name),.cat_ready(cat_ready),.busy(busy),
    .load_done(load_done),.src_width(src_width),.src_height(src_height));
  reg [31:0] lbas[0:4095];
  reg [7:0] sectors[0:2097151];
  reg [3:0] expected[0:589823], actual[0:49151];
  reg touched[0:49151];
  reg [79:0] plans[0:11]; // basename[79:16], index[15:8], error[7:0]
  reg [1023:0] lba_path,data_path,expected_path,plan_path;
  integer nsectors,nops,want_count,want_seq,forbid_lba,op,i,k,reads=0,writes=0,cycles=0;
  integer active=0,slot,pos=0,phase=0,init_requests=0,done_pulses=0;
  reg last_done=0, saw_busy=0;
  integer io_mode=0, fast_bytes=0;
  reg io_injected=0;
  reg [63:0] previous_name=0;
  reg [5:0] previous_index=0;
  initial begin
    if (!$value$plusargs("NSECTORS=%d",nsectors)) $fatal(1,"NSECTORS");
    if (!$value$plusargs("NOPS=%d",nops)) $fatal(1,"NOPS");
    if (!$value$plusargs("COUNT=%d",want_count)) $fatal(1,"COUNT");
    if (!$value$plusargs("SEQ=%d",want_seq)) $fatal(1,"SEQ");
    if (!$value$plusargs("FORBID=%d",forbid_lba)) forbid_lba=-1;
    if (!$value$plusargs("IO=%d",io_mode)) io_mode=0;
    if (!$value$plusargs("FAST=%d",fast_bytes)) fast_bytes=0;
    if (!$value$plusargs("LBA=%s",lba_path)) $fatal(1,"LBA");
    if (!$value$plusargs("DATA=%s",data_path)) $fatal(1,"DATA");
    if (!$value$plusargs("EXPECTED=%s",expected_path)) $fatal(1,"EXPECTED");
    if (!$value$plusargs("PLAN=%s",plan_path)) $fatal(1,"PLAN");
    $readmemh(lba_path,lbas,0,nsectors-1);
    $readmemh(data_path,sectors,0,nsectors*512-1);
    $readmemh(expected_path,expected,0,nops*49152-1);
    $readmemh(plan_path,plans,0,nops-1);
    for(i=0;i<49152;i=i+1) begin touched[i]=0; actual[i]=4'bxxxx; end
    repeat(5) @(negedge clk); rst_n=1;
    repeat(20) @(negedge clk); init_done=1;
    for(op=0;op<nops;op=op+1) begin
      if(op!=0) begin
        for(i=0;i<49152;i=i+1) begin touched[i]=0; actual[i]=4'bxxxx; end
        // Operation2 after a card failure is the automatic boot load after remount.
        if (!(io_mode && op==2)) begin
          @(negedge clk); load_index=plans[op][13:8]; load_go=1;
          if(op!=1) begin repeat(3) @(negedge clk); load_go=0; end
        end
      end
      wait(load_done===1'b1); @(negedge clk);
      if(busy || cat_ready !== (plans[op][7:0]!=1) || file_count!=want_count || seq_count!=want_seq)
        $fatal(1,"catalog/status op=%0d busy=%b ready=%b count=%0d seq=%0d",op,busy,cat_ready,file_count,seq_count);
      if(tf_err !== plans[op][1:0]) $fatal(1,"error op=%0d got=%0d want=%0d",op,tf_err,plans[op][7:0]);
      if(plans[op][7:0]==0) begin
        if(!tf_valid || shown_name!==plans[op][79:16] || shown_index!==plans[op][13:8])
          $fatal(1,"loaded metadata op=%0d name=%h index=%0d valid=%b",op,shown_name,shown_index,tf_valid);
        if(src_width!=256 || src_height!=192) $fatal(1,"source dimensions");
        for(i=0;i<49152;i=i+1)
          if(!touched[i] || actual[i]!==expected[op*49152+i])
            $fatal(1,"pixel op=%0d address=%0d actual=%h expected=%h touched=%b",op,i,actual[i],expected[op*49152+i],touched[i]);
        previous_name=shown_name; previous_index=shown_index;
      end else begin
        if(tf_valid || shown_name!==previous_name || shown_index!==previous_index)
          $fatal(1,"failed load exposed partial image or replaced shown metadata");
      end
      $display("PASS catalog operation=%0d index=%0d error=%0d name=%h",op,plans[op][13:8],tf_err,shown_name);
      repeat(12) @(negedge clk);
      load_go=0;
      repeat(3) @(negedge clk);
    end
    if(init_requests!=(io_mode ? 2 : 1) || done_pulses!=nops)
      $fatal(1,"init=%0d done=%0d expected=%0d",init_requests,done_pulses,nops);
    if(io_mode && !io_injected) $fatal(1,"I/O failure was not injected");
    $display("PASS sd_catalog count=%0d seq=%0d operations=%0d reads=%0d writes=%0d init_requests=%0d",file_count,seq_count,nops,reads,writes,init_requests);
    $finish;
  end
  always @(posedge clk) if(rst_n) begin
    cycles=cycles+1;
    if(init_go) init_requests=init_requests+1;
    if(load_done) begin
      done_pulses=done_pulses+1;
      if(last_done) $fatal(1,"load_done longer than one cycle");
    end
    last_done=load_done;
    if(cat_ready && (file_count!=want_count || seq_count!=want_seq)) $fatal(1,"catalog changed");
    if(tw_wren) begin
      if(tf_valid || !busy) $fatal(1,"write while frame visible or loader idle");
      if(tw_addr>=49152) $fatal(1,"write address");
      actual[tw_addr]=tw_data; touched[tw_addr]=1; writes=writes+1;
    end
    if(cycles>12000000) $fatal(1,"timeout op=%0d dbg=%0d",op,dbg);
  end
  always @(negedge clk) begin
    dvalid=0; blk_done=0;
    if(rst_n) begin
      if(io_injected && init_go) begin
        init_done=1; init_err=0;
      end
      if(rd_go) begin
        if(rd_addr==forbid_lba) $fatal(1,"catalog continued root scan past cap");
        if(active) $fatal(1,"overlap");
        slot=-1;
        for(k=0;k<nsectors;k=k+1) if(lbas[k]==rd_addr) slot=k;
        if(slot<0) $fatal(1,"unmapped read LBA=%0d",rd_addr);
        reads=reads+1; pos=0; active=1; phase=0;
      end else if(active && io_mode && op==1 && !io_injected && pos==128) begin
        // Match sd_spi read-error behavior: no blk_done, err high, initialization lost.
        active=0; io_injected=1; init_done=0; init_err=1;
      end else if(active) begin
        phase=phase+1;
        if(pos<512) begin
          if(fast_bytes || phase%5!=0) begin dout=sectors[slot*512+pos]; dvalid=1; pos=pos+1; end
        end else begin blk_done=1; active=0; end
      end
    end
  end
endmodule
