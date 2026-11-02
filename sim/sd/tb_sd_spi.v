`timescale 1ns/1ps
// SIM ONLY: mode-0 SPI card model. No internal DUT reads, writes, or forces.
module tb_sd_spi;
  reg clk=0; always #5 clk=~clk;
  reg rst_n=0, init_go=0, rd_go=0;
  reg [31:0] rd_addr=0;
  wire sclk,mosi,cs,init_done,ccs,err,dvalid,blk_done;
  reg miso=1;
  wire [7:0] dout,r1b;
  wire [4:0] step;
  sd_spi dut(.clk(clk),.rst_n(rst_n),.sd_sclk(sclk),.sd_mosi(mosi),.sd_cs_n(cs),.sd_miso(miso),
    .init_go(init_go),.rd_go(rd_go),.rd_addr(rd_addr),.init_done(init_done),.ccs(ccs),.err(err),
    .dout(dout),.dvalid(dvalid),.blk_done(blk_done),.step(step),.r1b(r1b));
  reg card_hc=1, inject_error=0;
  reg [7:0] reply[0:4095], frame[0:5];
  reg [7:0] rx=0, completed;
  integer head=0,tail=0, txbit=7,rxbit=0,framepos=0;
  integer cmd, acmd=0,lastcmd=-1,commands=0,read_commands=0,cmd16_count=0;
  reg [31:0] arg, expected_lba=0;
  integer data_count=0, completed_blocks=0;
  reg collecting=0, init_phase=0;
  realtime last_rise=0;
  function [7:0] payload;
    input [31:0] lba;
    input integer index;
    begin payload=(lba*37) ^ (index*13) ^ (index>>3); end
  endfunction
  task enqueue;
    input [7:0] value;
    begin reply[tail]=value; tail=tail+1; end
  endtask
  task respond;
    integer n;
    begin
      cmd=frame[0]&8'h3f;
      arg={frame[1],frame[2],frame[3],frame[4]};
      commands=commands+1;
      // Two FF delay bytes ensure R1 polling exercises real wait behavior.
      enqueue(8'hff); enqueue(8'hff);
      case(cmd)
        0: begin
          if(arg!=0 || frame[5]!=8'h95) $fatal(1,"invalid CMD0 frame");
          acmd=0; enqueue(8'h01);
        end
        8: begin
          if(arg!=32'h1aa || frame[5]!=8'h87) $fatal(1,"invalid CMD8 frame");
          enqueue(8'h01); enqueue(0); enqueue(0); enqueue(1); enqueue(8'haa);
        end
        55: enqueue(acmd<3 ? 8'h01 : 8'h00);
        41: begin
          if(lastcmd!=55) $fatal(1,"ACMD41 without CMD55");
          acmd=acmd+1; enqueue(acmd<3 ? 8'h01 : 8'h00);
        end
        58: begin enqueue(0); enqueue(card_hc ? 8'hc0 : 8'h80); enqueue(8'hff); enqueue(8'h80); enqueue(0); end
        16: begin
          if(card_hc || arg!=512) $fatal(1,"invalid CMD16");
          cmd16_count=cmd16_count+1; enqueue(0);
        end
        17: begin
          read_commands=read_commands+1;
          if(arg !== (card_hc ? expected_lba : expected_lba<<9))
            $fatal(1,"CMD17 address actual=%h expected=%h hc=%0d",arg,card_hc ? expected_lba : expected_lba<<9,card_hc);
          if(inject_error) enqueue(8'h04);
          else begin
            enqueue(0); enqueue(8'hff); enqueue(8'hff); enqueue(8'hfe);
            for(n=0;n<512;n=n+1) enqueue(payload(expected_lba,n));
            enqueue(8'h12); enqueue(8'h34);
          end
        end
        default: $fatal(1,"unexpected card command %0d",cmd);
      endcase
      lastcmd=cmd;
    end
  endtask
  always @(posedge cs) begin
    miso=1; rxbit=0; framepos=0; head=0; tail=0; txbit=7; rx=0;
  end
  always @(negedge cs) begin rxbit=0; framepos=0; head=0; tail=0; txbit=7; rx=0; miso=1; end
  always @(posedge sclk) if(!cs) begin
    if(init_phase) begin
      if(last_rise!=0 && $realtime-last_rise<1200) $fatal(1,"initialization SPI clock too fast: %0t",$realtime-last_rise);
      last_rise=$realtime;
    end
    completed={rx[6:0],mosi}; rx=completed;
    if(rxbit==7) begin
      rxbit=0;
      if(framepos==0) begin
        if(completed[7:6]==2'b01) begin frame[0]=completed; framepos=1; end
      end else begin
        frame[framepos]=completed;
        if(framepos==5) begin framepos=0; respond; end
        else framepos=framepos+1;
      end
    end else rxbit=rxbit+1;
  end
  // Shift on falling SCLK; first bit is ready before the next rising sample.
  always @(negedge sclk) if(!cs) begin
    if(head<tail) begin
      miso=reply[head][txbit];
      if(txbit==0) begin txbit=7; head=head+1; end else txbit=txbit-1;
    end else begin miso=1; txbit=7; end
  end
  always @(posedge clk) if(rst_n) begin
    if(dvalid) begin
      if(!collecting || data_count>=512) $fatal(1,"unexpected extra data byte");
      if(dout !== payload(expected_lba,data_count)) $fatal(1,"block byte %0d actual=%h expected=%h",data_count,dout,payload(expected_lba,data_count));
      data_count=data_count+1;
    end
    if(blk_done) begin
      if(data_count!=512) $fatal(1,"block length %0d",data_count);
      completed_blocks=completed_blocks+1; collecting=0;
    end
  end
  task initialize;
    integer n;
    begin
      init_phase=1; last_rise=0;
      @(negedge clk); init_go=1; @(negedge clk); init_go=0;
      n=0;
      while(init_done && n<100) begin @(negedge clk); n=n+1; end
      n=0;
      while(!init_done && n<1000000) begin @(negedge clk); n=n+1; if(err) $fatal(1,"initialization error"); end
      if(!init_done || ccs!==card_hc || step!==31) $fatal(1,"initialization failed ccs=%0d step=%h",ccs,step);
      init_phase=0; last_rise=0;
    end
  endtask
  task read_block;
    input [31:0] address;
    integer n,target;
    begin
      expected_lba=address; data_count=0; collecting=1; target=completed_blocks+1;
      @(negedge clk); rd_addr=address; rd_go=1;
      @(negedge clk); rd_go=0; rd_addr=32'hdeadbeef;
      n=0;
      while(completed_blocks<target && n<200000) begin @(negedge clk); n=n+1; if(err) $fatal(1,"block error"); end
      if(completed_blocks!=target) $fatal(1,"block timeout");
    end
  endtask
  integer mode,n;
  initial begin
    for(mode=0;mode<2;mode=mode+1) begin
      card_hc=(mode==0); rst_n=0; inject_error=0; collecting=0;
      repeat(5) @(negedge clk); rst_n=1;
      initialize;
      read_block(32'h123); read_block(32'h245);
      // Explicit reinitialization after fast reads must restore the slow divider.
      initialize; read_block(32'h36a);
      // A card-reported read error must invalidate readiness and permit recovery.
      expected_lba=32'h47b; inject_error=1;
      @(negedge clk); rd_addr=expected_lba; rd_go=1;
      @(negedge clk); rd_go=0; rd_addr=0;
      n=0; while(!err && n<200000) begin @(negedge clk); n=n+1; end
      repeat(2) @(negedge clk);
      if(!err || init_done) $fatal(1,"read error did not invalidate readiness");
      repeat(5) @(negedge clk); inject_error=0;
      initialize; read_block(32'h58c);
      $display("PASS SPI card_hc=%0d blocks=%0d",card_hc,completed_blocks);
    end
    if(cmd16_count<3) $fatal(1,"SDSC block length command missing");
    $display("PASS sd_spi blocks=%0d commands=%0d CMD17=%0d",completed_blocks,commands,read_commands); $finish;
  end
  initial begin #100000000; $fatal(1,"wire-level SPI global timeout"); end
endmodule
