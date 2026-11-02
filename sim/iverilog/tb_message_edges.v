`timescale 1ns/1ps
`include "rpg_defs.vh"
// Isolated synthetic white-box display regression. HP stimulus exists only
// in this simulation; scene changes/rest use real external key pulses.
module tb_message_edges;
 reg clk=0; always #10 clk=~clk;
 reg rst_n=0; reg [3:0] key=0;
 wire we; wire [10:0] waddr; wire [16:0] wdata;
 rpg_core dut(.clk(clk),.rst_n(rst_n),.key(key),.we(we),.waddr(waddr),.wdata(wdata));
 reg [16:0] cells[0:1199];
 integer starts=0; reg was_rendering=0; reg [9:0] last_start_pc;
 always @(posedge clk) begin
   if(we && waddr<1200) cells[waddr]<=wdata;
   #1;
   if(!rst_n) begin starts=0; was_rendering=0; end
   else begin
     if(!was_rendering && dut.rendering) begin
       starts=starts+1; last_start_pc=dut.pc;
     end
     was_rendering=dut.rendering;
   end
 end
 task idle;
 integer n,calm;
 begin
 n=0; calm=0;
 while(calm<8 && n<300000) begin
 @(negedge clk); n=n+1;
 if(!dut.rendering && !dut.redraw && !dut.alert_pending && dut.rstt==0) calm=calm+1;
 else calm=0;
 end
 if(n==300000) $fatal(1,"idle timeout");
 end endtask
 task tap(input [3:0] k);
 begin @(negedge clk); key=k; @(negedge clk); key=0; idle(); end endtask
 task setup;
 begin
 @(negedge clk); rst_n=0; key=0;
 repeat(4) @(negedge clk);
 rst_n=1; idle(); tap(1); tap(1);
 if(dut.scene!=2) $fatal(1,"setup did not enter map");
 end endtask
 integer before_starts;
 initial begin
 setup();
 @(negedge clk); dut.hp=20; // one-time lab-only initial condition
 idle();
 if(dut.banner_addr!=`MSG_DYING || !dut.banner_v) $fatal(1,"no warning initial condition");
 tap(4); // normal rest: subtracts 10 gold and restores HP
 if(dut.hp_low || dut.hp!=124 || dut.gold!=30) $fatal(1,"normal rest semantics changed");
 if(dut.banner_v && dut.banner_addr==`MSG_DYING && cells[4*40+2][12:9]==5)
   $display("REPRO_STALE_L1: normal rest healed hp=%0d gold=%0d; healthy ctx=%0d but visible MSG_DYING remains red, timer=%0d",dut.hp,dut.gold,dut.ctx_addr,dut.banner_tmr);
 else $display("FIXED_STALE_L1: healing dismissed low-health warning");
`ifdef EXPECT_FIXED
 if(dut.banner_v && dut.banner_addr==`MSG_DYING) $fatal(1,"low-health warning survived healing");
`endif
 setup();
 @(negedge clk); dut.hp=20; // one-time lab-only initial condition
 wait(dut.redraw && !dut.rendering);
 @(negedge clk); key=2; before_starts=starts;
 @(negedge clk); key=0;
 if(dut.scene!=4) $fatal(1,"real key did not enter shop");
 idle();
 if(last_start_pc!=dut.scr_addr && starts==before_starts+1 && cells[4*40+2][8:0]==dut.u_str.mem[dut.ctx_addr][8:0])
   $display("REPRO_REDRAW_RACE: real shop key accepted during automatic redraw; scene=%0d expected_screen_pc=%0d last_render_pc=%0d starts=%0d; visible cell(2,4) still map context glyph=%0d",dut.scene,dut.scr_addr,last_start_pc,starts,cells[4*40+2][8:0]);
 else $display("REDRAW_RESULT scene=%0d expected_pc=%0d last_pc=%0d starts_before=%0d after=%0d cell=%0d",dut.scene,dut.scr_addr,last_start_pc,before_starts,starts,cells[4*40+2][8:0]);
`ifdef EXPECT_FIXED
 if(last_start_pc!=dut.scr_addr) $fatal(1,"scene redraw request lost");
 // Real shop purchases, with one-time synthetic HP setup/recovery only.
 setup(); tap(2); tap(1); // map -> shop -> buy herb
 if(dut.banner_pri!=3 || dut.banner_addr!=`MSG_BUY) $fatal(1,"shop purchase L3 missing");
 @(negedge clk); dut.hp=20;
 idle();
 if(dut.banner_pri!=1 || dut.banner_addr!=`MSG_DYING || !dut.queue_v || dut.queue_addr!=`MSG_BUY)
   $fatal(1,"L1 did not queue shop notice");
 tap(2); // only 25 gold remains, potion costs 30; latest queued L3 is no-gold
 if(dut.queue_addr!=`MSG_NOGOLD || dut.gold!=25) $fatal(1,"latest shop notice replacement or gold semantics");
 @(negedge clk); dut.hp=124;
 idle();
 if(!dut.banner_v || dut.banner_pri!=3 || dut.banner_addr!=`MSG_NOGOLD || dut.queue_v)
   $fatal(1,"recovery failed to restore latest queued L3");
 if(cells[27*40+2][12:9]!=4 || cells[27*40+2][8:0]!=dut.u_str.mem[`MSG_NOGOLD][8:0])
   $fatal(1,"restored L3 not visible through public cell writes");
 $display("PASS recovery restores latest queued L3 through public cell writes");
 // Boss timer is natural; kills is a lab-only readiness initial condition.
 setup(); @(negedge clk); dut.kills=4;
 tap(2); tap(1);
 wait(dut.banner_v && dut.banner_pri==1 && dut.banner_addr==`MSG_BOSS);
 idle();
 if(dut.hp_low || dut.banner_addr!=`MSG_BOSS || dut.banner_pri!=1)
   $fatal(1,"healthy HP incorrectly cancelled boss warning");
 if(cells[27*40+2][12:9]!=5 || cells[27*40+2][8:0]!=dut.u_str.mem[`MSG_BOSS][8:0])
   $fatal(1,"boss L1 not visible");
 tap(8); // normal scene change shop -> shop2 cleans banner and queue
 if(dut.scene!=8 || dut.banner_v || dut.side_v || dut.queue_v || dut.boss_arm)
   $fatal(1,"scene cleanup retained old messages");
 if(cells[27*40+2][8:0]!=dut.u_str.mem[`MSG_HINT2][8:0])
   $fatal(1,"new shop-page hint not visible");
 $display("PASS healthy boss L1 remains visible and scene cleanup clears state");
 $display("PASS focused message display regressions");
`endif
 $finish;
 end
 initial begin #200000000; $fatal(1,"watchdog"); end
endmodule
