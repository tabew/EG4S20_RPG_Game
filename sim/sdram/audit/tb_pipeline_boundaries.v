`timescale 1ns/1ps
module tb_pipeline_boundaries;
 parameter real TEST_T_AC_NS=5.4;
 defparam dut.memory.T_AC_NS=TEST_T_AC_NS;
 reg clk=0;always #10 clk=~clk;
 reg phy_clk=0;initial begin #5;forever #10 phy_clk=~phy_clk;end
 reg rst_n=0,cmd_valid=0,cmd_write=0,wr_valid=0;
 reg [20:0]cmd_addr=0;reg[7:0]cmd_len=0;
 reg[31:0]wr_data=0;reg[3:0]wr_strb=15;
 wire init_done,cmd_ready,wr_ready,rd_valid,rd_last,wr_done,busy;
 wire[31:0]rd_data;
 media_sdram_ctrl dut(.*);
 reg [31:0]expected[0:2097151];
 integer n,pass,t,k,base,received,rt_before,wt_before,checked=0;
 reg [31:0]value;reg[3:0]mask;
 task command;
 input w;input integer a,len;
 begin
  @(negedge clk);while(!cmd_ready)@(negedge clk);
  cmd_write=w;cmd_addr=a;cmd_len=len;cmd_valid=1;
  @(negedge clk);cmd_valid=0;
 end endtask
 task write_check;
 input integer a,len,masked;
 integer i,b,old_tokens;reg[31:0]d;reg[3:0]s;
 begin
  old_tokens=dut.memory.write_tokens;
  command(1,a,len);
  for(i=0;i<len;i=i+1)begin
   // Alternate producer gaps, including first and final beats.
   if(i%7==0)repeat(3)@(negedge clk);
   while(!wr_ready)@(negedge clk);
   d=32'h12345678 ^ ((a+i)*32'h8721) ^ (masked*32'hcafe0987);
   s=masked ? ((i+len)%16) : 15;
   wr_data=d;wr_strb=s;wr_valid=1;
   for(b=0;b<4;b=b+1)if(s[b])expected[a+i][8*b+:8]=d[8*b+:8];
   @(negedge clk);wr_valid=0;
  end
  while(!wr_done)@(negedge clk);
  if(dut.memory.write_tokens-old_tokens!=len)$fatal(1,"AUDIT physical write count len=%0d actual=%0d",len,dut.memory.write_tokens-old_tokens);
 end endtask
 task read_check;
 input integer a,len;
 integer i,old_tokens;
 begin
  old_tokens=dut.memory.read_tokens;command(0,a,len);i=0;
  while(i<len)begin
   @(negedge clk);
   if(rd_valid)begin
    if(rd_data!==expected[a+i])$fatal(1,"AUDIT data addr=%h len=%0d beat=%0d got=%h expected=%h",a+i,len,i,rd_data,expected[a+i]);
    if(rd_last!==(i==len-1))$fatal(1,"AUDIT rd_last len=%0d beat=%0d",len,i);
    checked=checked+1;i=i+1;
   end
  end
  while(busy)begin
   @(negedge clk);
   if(rd_valid)$fatal(1,"AUDIT extra read beat len=%0d",len);
  end
  if(dut.memory.read_tokens-old_tokens!=len)$fatal(1,"AUDIT physical read count len=%0d actual=%0d",len,dut.memory.read_tokens-old_tokens);
 end endtask
 initial begin
  rst_n=1;#1;rst_n=0;#52;rst_n=1;wait(init_done);
  for(n=1;n<=128;n=n+1)begin
   // Aligned, near page end (split lengths), and full bank carry.
   for(pass=0;pass<3;pass=pass+1)begin
    case(pass)0:base=21'h1000;1:base=21'h1f8;2:base=21'h7ffc1;endcase
    write_check(base,n,0);read_check(base,n);
    write_check(base,n,1);read_check(base,n);
   end
  end
  $display("PASS independent CAS pipeline model tAC=%0.1fns: all lengths 1..128, first+last words, page/bank carry, per-beat strobes 0..15, producer gaps, exact physical word counts; checked=%0d",TEST_T_AC_NS,checked);
  $finish;
 end
 initial begin #20000000;$fatal(1,"AUDIT timeout");end
endmodule
