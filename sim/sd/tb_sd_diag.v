`timescale 1ns/1ps
// Simulation-only check of the public gallery output at each diagnostic block.
module tb_sd_diag;
  reg clk=0; always #5 clk=~clk;
  reg [11:0] x=0,y=0;
  reg [7:0] diag=0,diag2=0;
  wire [15:0] rgb;
  wire [15:0] addr;
  gal_layer dut(.clk(clk),.rst_n(1'b1),.gal_on(1'b1),.gal_img(2'd0),
    .gal_fade(4'd8),.x2(x),.y2(y),.x3(x),.y3(y),.tf_valid(1'b0),
    .tf_err(2'd1),.diag(diag),.diag2(diag2),.dfill(1'b0),
    .tf_rdata(4'd0),.tf_raddr(addr),.gal_rgb(rgb));
  integer bitno,pos;
  initial begin
    for(bitno=0;bitno<8;bitno=bitno+1) begin
      diag=8'b1<<bitno;
      diag2=8'b1<<(7-bitno);
      for(pos=0;pos<8;pos=pos+1) begin
        x=64+128+pos*32+8; y=44+172+8; #1;
        if(rgb !== ((pos==bitno)?16'hffff:16'h2108))
          $fatal(1,"diag row1 bit=%0d position=%0d rgb=%h",bitno,pos,rgb);
        y=44+200+8; #1;
        if(rgb !== ((pos==bitno)?16'h07ff:16'h2108))
          $fatal(1,"diag row2 bit=%0d position=%0d rgb=%h",bitno,pos,rgb);
        x=64+128+pos*32+24; #1;
        if(rgb !== 16'hf800) $fatal(1,"diagnostic spacing missing");
      end
    end
    $display("PASS sd_diag 8 bits, order and spacing"); $finish;
  end
endmodule
