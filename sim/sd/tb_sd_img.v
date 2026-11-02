`timescale 1ns/1ps
// SIMULATION ONLY. Drive only the public sd_spi block interface; no DUT forces.
module tb_sd_img;
  reg clk=0; always #5 clk=~clk;
  reg rst_n=0, init_done=0, init_err=0;
  wire init_go, rd_go;
  wire [31:0] rd_addr;
  reg [7:0] dout=0;
  reg dvalid=0, blk_done=0;
  wire [15:0] tw_addr;
  wire [3:0] tw_data;
  wire tw_wren, tf_valid;
  wire [1:0] tf_err, fdiag;
  wire [7:0] dbg;
  sd_img dut(.clk(clk),.rst_n(rst_n),.init_go(init_go),.init_done(init_done),
    .init_err(init_err),.rd_go(rd_go),.rd_addr(rd_addr),.dout(dout),
    .dvalid(dvalid),.blk_done(blk_done),.tw_addr(tw_addr),.tw_data(tw_data),
    .tw_wren(tw_wren),.tf_valid(tf_valid),.tf_err(tf_err),.fdiag(fdiag),.dsel(3'd7),.dbg(dbg));
  reg [31:0] lbas[0:4095];
  reg [7:0] sectors[0:2097151];
  reg [3:0] expected[0:49151], actual[0:49151];
  reg touched[0:49151];
  integer nsectors, want_error, cycles=0, reads=0, writes=0, i, slot, pos=0;
  integer active=0, wait_cycles=0, phase=0, mismatch, missing;
  reg [1023:0] lba_path, data_path, expected_path;
  initial begin
    if (!$value$plusargs("NSECTORS=%d",nsectors)) $fatal(1,"missing NSECTORS");
    if (!$value$plusargs("ERROR=%d",want_error)) want_error=0;
    if (!$value$plusargs("LBA=%s",lba_path)) $fatal(1,"missing LBA");
    if (!$value$plusargs("DATA=%s",data_path)) $fatal(1,"missing DATA");
    if (!$value$plusargs("EXPECTED=%s",expected_path)) $fatal(1,"missing EXPECTED");
    if(nsectors<1 || nsectors>4096) $fatal(1,"fixture sector count out of range: %0d",nsectors);
    $readmemh(lba_path,lbas,0,nsectors-1);
    $readmemh(data_path,sectors,0,nsectors*512-1);
    $readmemh(expected_path,expected);
    for(i=0;i<49152;i=i+1) begin touched[i]=0; actual[i]=4'bxxxx; end
    repeat(5) @(negedge clk); rst_n=1;
    // Initialization may take longer than an image byte; check the request is not repeated.
    repeat(200) @(negedge clk); init_done=1;
  end
  integer init_requests=0;
  always @(posedge clk) if(rst_n) begin
    cycles=cycles+1;
    if(init_go) begin
      init_requests=init_requests+1;
      if(init_requests>1) $fatal(1,"unexpected repeated init_go during slow initialization");
    end
    if(tw_wren) begin
      if(tw_addr>=49152) $fatal(1,"thumbnail address out of range: %d",tw_addr);
      actual[tw_addr]=tw_data; touched[tw_addr]=1; writes=writes+1;
    end
    if(tf_valid) begin
      if(want_error!=0) $fatal(1,"truncated/malformed image incorrectly accepted");
      mismatch=0; missing=0;
      for(i=0;i<49152;i=i+1) begin
        if(!touched[i]) missing=missing+1;
        if(actual[i] !== expected[i]) begin
          if(mismatch<8) $display("PIXEL %0d actual=%h expected=%h",i,actual[i],expected[i]);
          mismatch=mismatch+1;
        end
      end
      if(mismatch || missing) $fatal(1,"pixel mismatch=%0d missing=%0d reads=%0d writes=%0d",mismatch,missing,reads,writes);
      $display("PASS sd_img pixels=49152 reads=%0d writes=%0d init_requests=%0d",reads,writes,init_requests); $finish;
    end
    if(tf_err!=0) begin
      if(want_error==0 || tf_err!=want_error) $fatal(1,"unexpected tf_err=%0d state=%0d reads=%0d",tf_err,dbg,reads);
      $display("PASS sd_img rejected error=%0d reads=%0d",tf_err,reads); $finish;
    end
    if(cycles>3000000) $fatal(1,"timeout state=%0d reads=%0d",dbg,reads);
  end
  // Change data on falling system edges, sample on rising ones. Include byte stalls.
  always @(negedge clk) begin
    dvalid=0; blk_done=0;
    if(rst_n) begin
      if(rd_go) begin
        if(active) $fatal(1,"overlapping block requests");
        slot=-1;
        for(integer k=0;k<nsectors;k=k+1) if(lbas[k]==rd_addr) slot=k;
        if(slot<0) $fatal(1,"read of unmapped LBA %0d",rd_addr);
        reads=reads+1; pos=0; active=1; wait_cycles=3; phase=0;
      end else if(active) begin
        if(wait_cycles>0) wait_cycles=wait_cycles-1;
        else if(pos<512) begin
          phase=phase+1;
          if(phase%5!=0) begin dout=sectors[slot*512+pos]; dvalid=1; pos=pos+1; end
        end else begin blk_done=1; active=0; end
      end
    end
  end
endmodule
