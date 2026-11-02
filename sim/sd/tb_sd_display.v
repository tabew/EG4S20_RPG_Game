`timescale 1ns/1ps
// Simulation only: exercise real RAM and gallery through their public ports.
module tb_sd_display;
  reg wclk=0, rclk=0;
  always #5 wclk=~wclk;
  always #7 rclk=~rclk;
  reg [15:0] waddr=0, manual_addr=0;
  reg [3:0] wdata=0;
  reg wren=0, gallery_read=0;
  reg [11:0] x2=0,y2=0,x3=0,y3=0;
  reg [1:0] gal_img=0;
  wire [15:0] gallery_addr, rgb;
  wire [15:0] raddr=gallery_read ? gallery_addr : manual_addr;
  wire [3:0] rdata;
  tf_ram ram(.wclk(wclk),.waddr(waddr),.wren(wren),.wdata(wdata),
    .rclk(rclk),.raddr(raddr),.rdata(rdata));
  gal_layer gallery(.clk(rclk),.rst_n(1'b1),.gal_on(1'b1),.gal_img(gal_img),
    .gal_fade(4'd8),.x2(x2),.y2(y2),.x3(x3),.y3(y3),.tf_valid(1'b1),
    .tf_err(2'd0),.diag(8'd0),.diag2(8'd0),.dfill(1'b0),
    .tf_rdata(rdata),.tf_raddr(gallery_addr),.gal_rgb(rgb));
  always @(posedge rclk) begin x3<=x2; y3<=y2; end

  function [3:0] pixel;
    input integer address;
    begin
      // Give the row/column and high-address boundaries distinct values.
      case(address)
        255: pixel=4'd1;
        256: pixel=4'd2;
        32767: pixel=4'd3;
        32768: pixel=4'd4;
        49151: pixel=4'd5;
        default: pixel=(address ^ (address>>4) ^ (address>>8) ^ (address>>12)) & 15;
      endcase
    end
  endfunction

  function [15:0] palette;
    input [3:0] index;
    begin
      case(index)
        0: palette=16'h0000; 1: palette=16'h0841;
        2: palette=16'h10a2; 3: palette=16'h18e3;
        4: palette=16'h3186; 5: palette=16'h4208;
        6: palette=16'h8000; 7: palette=16'hc000;
        8: palette=16'he800; 9: palette=16'hfd20;
        10: palette=16'hfe60; 11: palette=16'hffe0;
        12: palette=16'hffff; 13: palette=16'h7bef;
        14: palette=16'h39e7; 15: palette=16'h0220;
      endcase
    end
  endfunction

  integer i,row,col,checks=0;
  reg [3:0] held_data;
  task check_display;
    input integer sx,sy,corner;
    integer want_addr;
    begin
      want_addr=sy*256+sx;
      @(negedge rclk);
      x2=64+sx*2+corner; y2=44+sy*2+corner;
      gal_img=want_addr%4;
      #1;
      if(gallery_addr !== want_addr[15:0])
        $fatal(1,"gallery mapping x=%0d y=%0d corner=%0d actual=%0d expected=%0d",sx,sy,corner,gallery_addr,want_addr);
      @(posedge rclk); #1;
      if(rdata !== pixel(want_addr))
        $fatal(1,"gallery RAM data address=%0d actual=%h expected=%h",want_addr,rdata,pixel(want_addr));
      if(rgb !== palette(pixel(want_addr)))
        $fatal(1,"gallery RGB address=%0d corner=%0d actual=%h expected=%h",want_addr,corner,rgb,palette(pixel(want_addr)));
      checks=checks+1;
    end
  endtask
  task check_outside;
    input integer x,y;
    begin
      @(negedge rclk); x2=x; y2=y; #1;
      if(gallery_addr !== 16'd0)
        $fatal(1,"gallery outside address x=%0d y=%0d addr=%0d",x,y,gallery_addr);
    end
  endtask

  initial begin
    // Write every location before reading any, so truncated addresses cannot
    // pass by reading each value immediately after its own write.
    for(i=0;i<49152;i=i+1) begin
      @(negedge wclk); waddr=i; wdata=pixel(i); wren=1;
      @(posedge wclk); #1;
    end
    @(negedge wclk); wren=0;
    for(i=0;i<49152;i=i+1) begin
      held_data=rdata;
      @(negedge rclk); manual_addr=i; #1;
      if(i>0 && rdata !== held_data) $fatal(1,"RAM read is not synchronous address=%0d",i);
      @(posedge rclk); #1;
      if(rdata !== pixel(i))
        $fatal(1,"RAM readback address=%0d actual=%h expected=%h",i,rdata,pixel(i));
    end
    gallery_read=1;
    for(row=0;row<192;row=row+1)
      for(col=0;col<256;col=col+1) begin
        check_display(col,row,0);
        check_display(col,row,1);
      end
    check_outside(63,44); check_outside(576,44);
    check_outside(64,43); check_outside(64,428);
    check_outside(0,0); check_outside(4095,4095);
    $display("PASS sd_display RAM=49152 boundaries=255/256,32767/32768,49151 mapped_RGB=%0d",checks);
    $finish;
  end
  initial begin #10000000; $fatal(1,"display test timeout"); end
endmodule
