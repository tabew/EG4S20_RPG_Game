`timescale 1ns/1ps
module tb_media_sdram;
 parameter integer TEST_T_AC_NS=6;
 defparam dut.memory.T_AC_NS=TEST_T_AC_NS;
 reg clk=0;always #10 clk=~clk;
 reg phy_clk=0;initial begin #5;forever #10 phy_clk=~phy_clk;end
 reg rst_n=0,cmd_valid=0,cmd_write=0,wr_valid=0;
 reg[20:0]cmd_addr=0;reg[7:0]cmd_len=0;
 reg[31:0]wr_data=0;reg[3:0]wr_strb=15;
 wire init_done,cmd_ready,wr_ready,rd_valid,rd_last,wr_done,busy;
 wire[31:0]rd_data;
 media_sdram_ctrl dut(.*);
 reg[31:0]expected[0:2097151];
 integer n,i,j,seed=32'h19384a2,start_time,end_time;
 reg[31:0]value;reg[3:0]strobes;
 task command;
 input w;input[20:0]a;input integer len;
 begin
  @(negedge clk);while(!cmd_ready)@(negedge clk);
  cmd_write=w;cmd_addr=a;cmd_len=len;cmd_valid=1;
  @(negedge clk);cmd_valid=0;
 end endtask
 task write_words;
 input[20:0]a;input integer len;input integer slow;input[3:0]mask;
 integer t,k;reg[31:0]d;
 begin
  command(1,a,len);
  for(t=0;t<len;t=t+1)begin
   if(slow!=0)repeat(slow)@(negedge clk);
   while(!wr_ready)@(negedge clk);
   d=32'hc0fa0000^(a+t)^(t*32'h10327);
   wr_data=d;wr_strb=mask;wr_valid=1;
   for(k=0;k<4;k=k+1)if(mask[k])expected[a+t][k*8+:8]=d[k*8+:8];
   @(negedge clk);wr_valid=0;
  end
  while(!wr_done)@(negedge clk);
  if(busy)$fatal(1,"wr_done must follow physical recovery");
 end endtask
 task read_words;
 input[20:0]a;input integer len;
 integer t;
 begin
  command(0,a,len);t=0;
  while(t<len)begin
   @(negedge clk);
   if(rd_valid)begin
    if(rd_data!==expected[a+t])$fatal(1,"read addr=%h got=%h expected=%h index=%0d",a+t,rd_data,expected[a+t],t);
    if(rd_last!==(t==len-1))$fatal(1,"bad rd_last at index %0d",t);
    t=t+1;
   end
  end
 end endtask
 initial begin
  // Assert asynchronous reset before the first PHY edge, including falling-edge IO registers.
  rst_n=1;#1;rst_n=0;#52;rst_n=1;
  wait(init_done);
  if($time<200000)$fatal(1,"early init_done");
  // Every legal length, unaligned columns, both sides of page boundaries.
  for(n=1;n<=128;n=n+1)begin
   write_words(21'h0000f8,n,0,15);
   read_words(21'h0000f8,n);
  end
  // All banks, highest row, row crossing, and byte masks.
  for(j=0;j<4;j=j+1)begin
   write_words((j<<19)+21'h7ff80,128,0,15);
   read_words((j<<19)+21'h7ff80,128);
   write_words((j<<19)+21'h001f9,128,0,15);
   write_words((j<<19)+21'h001f9,128,0,5);
   read_words((j<<19)+21'h001f9,128);
  end
  // Consecutive addressing across a bank boundary must not wrap a page.
  write_words(21'h07ffc1,128,0,15);read_words(21'h07ffc1,128);
  // A slow producer must not starve refresh while assembling a write burst.
  write_words(21'h04220,20,100,15);read_words(21'h04220,20);
  repeat(1000)@(negedge clk);
  // Sustained service: 128-word read requests exceed 73.728MB/s requirement.
  write_words(21'h30000,128,0,15);
  start_time=$time;
  for(j=0;j<64;j=j+1)read_words(21'h30000,128);
  end_time=$time;
  if((end_time-start_time)>444444)$fatal(1,"read bandwidth below 73.728 MB/s");
  $display("PASS SDRAM storage/timing: all lengths1..128, row crossings, four banks, strobes, refresh during slow writes");
  $display("PASS bandwidth: 32768 bytes in %0d ns, maximum refresh gap %0d clocks",end_time-start_time,dut.memory.max_refresh_gap);
  $finish;
 end
 initial begin #20000000;$fatal(1,"controller timeout");end
endmodule
