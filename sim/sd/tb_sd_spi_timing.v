`timescale 1ns/1ps
// SIM ONLY: delayed physical-pin card model; internal sample phase is observed, never driven.
module tb_sd_spi_timing;
  parameter integer TEST_FAST_DIV=1;
  parameter integer SECTORS=64;
  parameter integer CARD_TCO_NS=14;
  parameter integer MISO_BOARD_NS=4;
  parameter integer CLOCK_BOARD_NS=0;
  parameter integer MOSI_BOARD_NS=0;
  wire card_sclk, card_mosi;
  assign #(CLOCK_BOARD_NS) card_sclk=sclk;
  assign #(MOSI_BOARD_NS) card_mosi=mosi;
  realtime last_mosi_change=-100000, last_card_rise=-100000;
  realtime last_card_fall=-100000, last_miso_change=-100000;
  realtime min_setup=100000, min_hold=100000, min_settle=100000;
  realtime min_sample_window=100000;
  integer timing_samples=0;
  integer cycle_count=0;
  integer bulk_start, bulk_cycles;
  integer timing_failures=0;
  // Card command-input requirements: setup >=5ns, hold >=5ns.
  always @(card_mosi) begin
    if(rst_n && !cs && $realtime-last_card_rise<5.0)
      $fatal(1,"MOSI_HOLD div=%0d actual=%0.3fns",TEST_FAST_DIV,$realtime-last_card_rise);
    if(rst_n && !cs && $realtime-last_card_rise<min_hold)
      min_hold=$realtime-last_card_rise;
    last_mosi_change=$realtime;
  end
  always @(posedge card_sclk) if(rst_n && !cs) begin
    if($realtime-last_mosi_change<5.0)
      $fatal(1,"MOSI_SETUP div=%0d actual=%0.3fns",TEST_FAST_DIV,$realtime-last_mosi_change);
    if($realtime-last_mosi_change<min_setup) min_setup=$realtime-last_mosi_change;
    last_card_rise=$realtime;
  end
  always @(negedge card_sclk) if(rst_n && !cs) last_card_fall=$realtime;
  always @(miso) last_miso_change=$realtime;
  // Observe the real engine sample event, without driving any internal signal.
  // A synchronizer here would alter the phase and must not be silently added.
  always @(posedge clk) begin
    cycle_count=cycle_count+1;
    if(rst_n && dut.eng_act && dut.half && dut.sclk_r && !cs) begin
      if($realtime-last_miso_change<0.5)
        $fatal(1,"MISO_SETUP div=%0d actual=%0.3fns",TEST_FAST_DIV,$realtime-last_miso_change);
      if($realtime-last_card_fall<CARD_TCO_NS+MISO_BOARD_NS+0.5)
        $fatal(1,"MISO_SETTLE div=%0d window=%0.3fns",TEST_FAST_DIV,$realtime-last_card_fall);
      if(init_done) begin
        timing_samples=timing_samples+1;
        if($realtime-last_miso_change<min_settle) min_settle=$realtime-last_miso_change;
        if($realtime-last_card_fall<min_sample_window) min_sample_window=$realtime-last_card_fall;
      end
    end
  end
  reg clk=0; always #10 clk=~clk;
  reg rst_n=0, init_go=0, rd_go=0;
  reg [31:0] rd_addr=0;
  wire sclk,mosi,cs,init_done,ccs,err,dvalid,blk_done;
  reg miso=1;
  wire [7:0] dout,r1b;
  wire [4:0] step;
  sd_spi #(.FAST_DIV(TEST_FAST_DIV)) dut(.clk(clk),.rst_n(rst_n),.sd_sclk(sclk),.sd_mosi(mosi),.sd_cs_n(cs),.sd_miso(miso),
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
  always @(posedge card_sclk) if(!cs) begin
    if(init_phase) begin
      if(last_rise!=0 && $realtime-last_rise<2500) $fatal(1,"initialization SPI clock too fast: %0t",$realtime-last_rise);
      last_rise=$realtime;
    end
    completed={rx[6:0],card_mosi}; rx=completed;
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
  always @(negedge card_sclk) if(!cs) begin
    if(head<tail) begin
      miso <= #(CARD_TCO_NS+MISO_BOARD_NS) reply[head][txbit];
      if(txbit==0) begin txbit=7; head=head+1; end else txbit=txbit-1;
    end else begin miso <= #(CARD_TCO_NS+MISO_BOARD_NS) 1; txbit=7; end
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
  integer mode,n,sector;
  initial begin
    for(mode=0;mode<2;mode=mode+1) begin
      card_hc=(mode==0); rst_n=0; inject_error=0; collecting=0;
      repeat(5) @(negedge clk); rst_n=1;
      initialize;
      bulk_start=cycle_count;
      for(sector=0;sector<SECTORS;sector=sector+1) read_block(32'h123+sector*13);
      bulk_cycles=cycle_count-bulk_start;
      $display("THROUGHPUT div=%0d hc=%0d sectors=%0d bytes=%0d cycles=%0d ns=%0d",TEST_FAST_DIV,card_hc,SECTORS,SECTORS*512,bulk_cycles,bulk_cycles*20);
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
    if(timing_samples<SECTORS*512*8) $fatal(1,"missing timing samples");
    $display("TIMING div=%0d setup_ns=%0.3f hold_ns=%0.3f miso_setup_ns=%0.3f sample_window_ns=%0.3f samples=%0d",TEST_FAST_DIV,min_setup,min_hold,min_settle,min_sample_window,timing_samples);
    $display("PASS sd_spi_timing blocks=%0d commands=%0d CMD17=%0d",completed_blocks,commands,read_commands); $finish;
  end
  initial begin #500000000; $fatal(1,"wire-level SPI global timeout"); end
endmodule
