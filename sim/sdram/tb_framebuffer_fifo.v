`timescale 1ns/1ps
module tb_framebuffer_fifo;
 reg wclk=0,rclk=0;always #10 wclk=~wclk;always #12.5 rclk=~rclk;
 reg wrst_n=0,rrst_n=0,wclear=0,rclear=0,w_en=0,r_en=0;
 reg [23:0]w_data=0;wire[23:0]r_data;wire r_valid,w_full,r_empty;wire[11:0]w_level;
 media_async_fifo #(.WIDTH(24),.ADDR_BITS(11)) dut(.*);
 reg [23:0] scoreboard[0:49999];
 integer head=0,tail=0,mode=3,wraps=0,round=0;
 reg [31:0]wrng=32'h1938472a,rrng=32'hf928da53;
 reg[23:0]wanted;reg taken;
 always @(negedge wclk)begin
  wrng={wrng[30:0],wrng[31]^wrng[21]^wrng[1]^wrng[0]};
  w_en=wrst_n && !wclear && (mode==0 || mode==1 && wrng[2:0]!=0);
  w_data=(tail*24'h37921b)^24'h6a0f39;
 end
 always @(negedge rclk)begin
  rrng={rrng[30:0],rrng[31]^rrng[21]^rrng[1]^rrng[0]};
  r_en=rrst_n && !rclear && (mode==2 || mode==1 && rrng[3:0]<13);
 end
 always @(posedge wclk)begin
  if(wrst_n && !wclear)begin
   if(!rclear && w_level>2048)$fatal(1,"impossible conservative FIFO level %0d",w_level);
   if(w_en && !w_full)begin scoreboard[tail]=w_data;tail=tail+1;end
  end
 end
 always @(posedge rclk)begin
  taken=rrst_n && !rclear && r_en && !r_empty;
  if(taken)begin
   if(head>=tail)$fatal(1,"FIFO read unproduced entry");
   wanted=scoreboard[head];head=head+1;
  end
  #1;
  if(rrst_n && !rclear)begin
   if(r_valid!==taken)$fatal(1,"synchronous r_valid latency");
   if(taken && r_data!==wanted)$fatal(1,"FIFO ordering expected=%h got=%h head=%0d",wanted,r_data,head);
  end
 end
 task coordinated_clear;
 begin
  mode=3;@(negedge rclk);rclear=1;
  repeat(5)@(negedge wclk);wclear=1;
  repeat(4)@(negedge wclk);wclear=0;
  repeat(4)@(negedge rclk);head=0;tail=0;rclear=0;
  repeat(4)@(negedge wclk);
  if(!r_empty || w_level!=0 || w_full)$fatal(1,"coordinated clear failed");
 end endtask
 initial begin
  #73;wrst_n=1;rrst_n=1;
  mode=0;wait(w_full);@(negedge wclk);mode=3;
  if(tail!=2048)$fatal(1,"capacity=%0d expected2048",tail);
  repeat(20)@(negedge wclk);
  if(tail!=2048)$fatal(1,"overflow accepted while full");
  mode=1;wait(tail>=20000);mode=2;wait(head==tail);repeat(5)@(negedge rclk);mode=3;
  if(!r_empty)$fatal(1,"FIFO must report empty after draining");
  coordinated_clear();
  mode=0;wait(tail>=137);coordinated_clear();
  mode=1;wait(tail>=10000);mode=2;wait(head==tail);repeat(5)@(negedge rclk);mode=3;
  $display("PASS asyncFIFO2048x24: exact capacity, full/empty stalls, 50/40MHz random clocks, >14wraps, ordered sync output, clear with residual data");
  $finish;
 end
 initial begin #5000000;$fatal(1,"asyncFIFO test timeout");end
endmodule
