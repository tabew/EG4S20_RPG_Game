`timescale 1ns/1ps
module tb_media_zoom_hud;
 wire done1,done3;
 media_zoom_hud_case #(.MODE(1)) cea(done1);
 media_zoom_hud_case #(.MODE(3)) legacy_timing(done3);
 initial begin wait(done1 && done3);$display("PASS media_zoom_hud: public RGB glyphs for FULL640/2XCENTER/4XCENTER and K3 ZOOM, legacy labels, both video modes and two-stage equivalence");$finish;end
 initial begin #200000;$fatal(1,"zoom HUD timeout");end
endmodule
module media_zoom_hud_case #(parameter MODE=1)(output reg done=0);
 reg clk=0;always #5 clk=~clk;
 reg rst_n=0,front=1;
 reg [1:0] view=0;
 reg [11:0] x=0,y=0;
 wire [23:0] rgb,piped_rgb;
 wire req,piped_req;
 reg [23:0] prior=0,expected=0;
 integer i,col,gx,gy,checks=0;
 reg [7:0] ch;
 reg [34:0] bits;
 localparam PARAM_Y=(MODE==1)?440:474;
 localparam SETTINGS_Y=(MODE==1)?460:496;
 genvar p;
 generate for(p=0;p<2;p=p+1)begin:layers
  wire [23:0] full;
  wire request;
  gal_layer #(.PIPELINE(p),.VIDEO_MODE(MODE)) dut(.clk(clk),.rst_n(rst_n),.gal_on(1'b1),.gal_img(2'd0),.gal_fade(4'd8),
   .x2(x),.y2(y),.x3(x),.y3(y),.tf_valid(1'b1),.tf_err(2'd0),.diag(8'd0),.diag2(8'd0),.dfill(1'b0),.tf_rdata(4'd0),
   .media_mode(2'd0),.media_auto(1'b1),.media_settings(1'b1),.media_loading(1'b0),.media_osd(1'b1),
   .media_index(6'd0),.media_count(6'd2),.media_name("ZOOM0001"),.media_brightness(4'd4),.media_contrast(2'd1),.media_view(view),.media_visual(1'b0),
   .fb_front_valid(front),.fb_pixel_valid(1'b1),.fb_pixel_rgb(24'd0),.fb_pixel_req(request),.gal_rgb_full(full));
 end endgenerate
 assign rgb=layers[0].full;
 assign piped_rgb=layers[1].full;
 assign req=layers[0].request;
 assign piped_req=layers[1].request;
 always @(posedge clk)begin
  if(!rst_n)begin prior<=0;expected<=0;end
  else begin prior<=rgb;expected<=prior;end
  #1;if(rst_n && (piped_rgb!==expected || req!==piped_req))$fatal(1,"zoom HUD changed two-stage latency MODE=%0d",MODE);
 end
 function [34:0] font;
  input [7:0] c;
  begin case(c)
   "A":font=35'b01110_10001_10001_11111_10001_10001_10001;
   "C":font=35'b01111_10000_10000_10000_10000_10000_01111;
   "E":font=35'b11111_10000_10000_11110_10000_10000_11111;
   "F":font=35'b11111_10000_10000_11110_10000_10000_10000;
   "I":font=35'b11111_00100_00100_00100_00100_00100_11111;
   "K":font=35'b10001_10010_10100_11000_10100_10010_10001;
   "L":font=35'b10000_10000_10000_10000_10000_10000_11111;
   "M":font=35'b10001_11011_10101_10101_10001_10001_10001;
   "N":font=35'b10001_11001_10101_10011_10001_10001_10001;
   "O":font=35'b01110_10001_10001_10001_10001_10001_01110;
   "R":font=35'b11110_10001_10001_11110_10100_10010_10001;
   "T":font=35'b11111_00100_00100_00100_00100_00100_00100;
   "U":font=35'b10001_10001_10001_10001_10001_10001_01110;
   "V":font=35'b10001_10001_10001_10001_10001_01010_00100;
   "W":font=35'b10001_10001_10001_10101_10101_11011_10001;
   "X":font=35'b10001_10001_01010_00100_01010_10001_10001;
   "Z":font=35'b11111_00001_00010_00100_01000_10000_11111;
   "0":font=35'b01110_10001_10011_10101_11001_10001_01110;
   "2":font=35'b01110_10001_00001_00010_00100_01000_11111;
   "3":font=35'b11110_00001_00001_01110_00001_00001_11110;
   "4":font=35'b00010_00110_01010_10010_11111_00010_00010;
   "6":font=35'b01110_10000_10000_11110_10001_10001_01110;
   default:font=0;
  endcase end
 endfunction
 task text;
  input integer row,start_column,length;
  input [63:0] label;
  begin
   for(col=0;col<length;col=col+1)begin
    ch=label[(length-col)*8-1 -: 8];bits=font(ch);
    for(gy=0;gy<7;gy=gy+1)for(gx=0;gx<6;gx=gx+1)begin
     @(negedge clk);x=16+(start_column+col)*12+gx*2;y=row+gy*2;#2;
     checks=checks+1;
     if(rgb!==(gx<5 && bits[34-gy*5-gx]?24'h00ffff:24'd0))
      $fatal(1,"zoom HUD MODE=%0d front=%b view=%0d char=%c col=%0d glyph=%0d,%0d RGB=%h",MODE,front,view,ch,col,gx,gy,rgb);
    end
   end
  end
 endtask
 initial begin
  repeat(4)@(negedge clk);rst_n=1;
  for(i=0;i<3;i=i+1)begin
   view=i;
   case(i)
    0:text(PARAM_Y,34,8,"FULL640 ");
    1:text(PARAM_Y,34,8,"2XCENTER");
    2:text(PARAM_Y,34,8,"4XCENTER");
   endcase
   text(SETTINGS_Y,32,7,"K3 ZOOM");
   // Every view consumes exactly the same native framebuffer rectangle.
   @(negedge clk);x=(MODE==1)?0:80;y=(MODE==1)?0:60;#2;if(!req)$fatal(1,"first framebuffer pixel");
   @(negedge clk);x=(MODE==1)?639:719;y=(MODE==1)?479:539;#2;if(!req)$fatal(1,"last framebuffer pixel");
   @(negedge clk);x=(MODE==1)?640:720;#2;if(req)$fatal(1,"read outside framebuffer right edge");
  end
  front=0;
  for(i=0;i<3;i=i+1)begin
   view=i;
   case(i)
    0:text(PARAM_Y,34,6,"NORMAL");
    1:text(PARAM_Y,34,6,"NATIVE");
    2:text(PARAM_Y,34,6,"ZOOM  ");
   endcase
   text(SETTINGS_Y,32,7,"K3 VIEW");
  end
  repeat(4)@(negedge clk);done=1;
 end
endmodule
