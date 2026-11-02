`timescale 1ns/1ps
// Functional clock-edge audit only; this does not model routed FPGA delays.
module staged_pin_monitor(input clk,phy_clk,rst_n,wr_done,
 input [54:0] pins,input ras_n,cas_n,we_n,cs_n,cke,input[3:0]dqm,
 input drive);
 realtime changed=0,last_fall=-1000,last_phy=-1000,last_pre=-1000;
 real min_setup=1000,min_done_recovery=1000;
 integer checks=0,write_completions=0;
 always @(negedge clk)last_fall=$realtime;
 always @(pins)begin
  if(rst_n && $realtime>1)begin
   if($realtime-last_fall>0.001)$fatal(1,"STAGED physical outputs changed off falling SYS edge");
   if($realtime-last_phy<1.0)$fatal(1,"STAGED physical output hold <1ns");
  end
  changed=$realtime;
 end
 always @(posedge phy_clk)begin
  last_phy=$realtime;
  if(rst_n)begin
   if(cke)begin
    if($realtime<200000)$fatal(1,"STAGED CKE before200us");
    if($realtime-changed<14.999)$fatal(1,"STAGED physical setup <15ns, actual=%0.3f",$realtime-changed);
    if($realtime-changed<min_setup)min_setup=$realtime-changed;
    checks=checks+1;
    if(!cs_n && {ras_n,cas_n,we_n}==3'b010)last_pre=$realtime;
   end else if(dqm!==4'b1111 || drive!==0 || {ras_n,cas_n,we_n}!==3'b111)
    $fatal(1,"STAGED startup pins not safe");
  end
 end
 always @(posedge clk)begin
  #0.001; // Observe wr_done after the controller's nonblocking updates.
  if(rst_n && wr_done)begin
   if($realtime-last_pre<21)$fatal(1,"STAGED wr_done before tRP recovery");
   if($realtime-last_pre<min_done_recovery)min_done_recovery=$realtime-last_pre;
   write_completions=write_completions+1;
  end
 end
 final $display("PASS staged pin monitor: minimum output setup=%0.1fns, wr_done minus final PRE >=%0.1fns, checkedPHY=%0d writeCompletions=%0d",min_setup,min_done_recovery,checks,write_completions);
endmodule

`define STAGED_MONITOR(T) \
 staged_pin_monitor monitor( \
  .clk(T.clk),.phy_clk(T.phy_clk),.rst_n(T.rst_n),.wr_done(T.wr_done), \
  .pins({T.dut.phy_ras_n,T.dut.phy_cas_n,T.dut.phy_we_n,T.dut.phy_cs_n,T.dut.phy_cke,T.dut.phy_addr,T.dut.phy_bank,T.dut.phy_dqm,T.dut.phy_dq_out,T.dut.phy_dq_drive}), \
  .ras_n(T.dut.phy_ras_n),.cas_n(T.dut.phy_cas_n),.we_n(T.dut.phy_we_n), \
  .cs_n(T.dut.phy_cs_n),.cke(T.dut.phy_cke),.dqm(T.dut.phy_dqm),.drive(T.dut.phy_dq_drive));
module tb_staged_boundaries;
 parameter real ACCESS_NS=5.4;
 tb_pipeline_boundaries #(.TEST_T_AC_NS(ACCESS_NS)) test();
 // Assert reset explicitly before the first PHY edge. A t=0 variable
 // initializer alone need not produce a negedge event in every simulator.
 initial begin test.rst_n=1; #1; test.rst_n=0; end
 `STAGED_MONITOR(test)
endmodule
module tb_staged_original;
 parameter integer ACCESS_NS=6;
 tb_media_sdram #(.TEST_T_AC_NS(ACCESS_NS)) test();
 initial begin test.rst_n=1; #1; test.rst_n=0; end
 `STAGED_MONITOR(test)
endmodule
`undef STAGED_MONITOR
