`timescale 1ns/1ps
// Render the real gallery RGB (including FPGA HUD) to an offline preview.
module tb_media_preview;
 reg clk=0;always #5 clk=~clk;
 reg rst=0;reg[11:0]x2=0,y2=0,x3=0,y3=0;
 reg[3:0]data=0;wire[15:0]address,rgb;reg[3:0]memory[0:49151];
 reg[1023:0]input_path,output_path;integer fd,x,y,viewmode=0;
 gal_layer gallery(.clk(clk),.rst_n(rst),.gal_on(1'b1),.gal_img(2'd0),.gal_fade(4'd8),
 .x2(x2),.y2(y2),.x3(x3),.y3(y3),.tf_valid(1'b1),.tf_err(2'd0),.diag(8'd0),.diag2(8'd0),.dfill(1'b0),.tf_rdata(data),.tf_raddr(address),.gal_rgb(rgb),
 .media_mode(2'd1),.media_auto(1'b0),.media_settings(1'b0),.media_loading(1'b0),.media_osd(1'b1),.media_index(6'd8),.media_count(6'd10),.media_name(64'h5049433030303031),
 .media_brightness(4'd4),.media_contrast(2'd1),.media_view(viewmode[1:0]),.media_visual(1'b1));
 always@(posedge clk)begin data<=memory[address];x3<=x2;y3<=y2;end
 initial begin
  if(!$value$plusargs("IMAGE=%s",input_path)||!$value$plusargs("OUTPUT=%s",output_path))$fatal(1,"missing paths");
  if($value$plusargs("VIEW=%d",viewmode))begin end
  $readmemh(input_path,memory);repeat(3)@(negedge clk);rst=1;
  fd=$fopen(output_path,"wb");if(!fd)$fatal(1,"cannot open preview");$fwrite(fd,"P6\n800 600\n255\n");
  for(y=0;y<600;y=y+1)for(x=0;x<800;x=x+1)begin
   @(negedge clk);x2=x;y2=y;@(posedge clk);#1;
   $fwrite(fd,"%c%c%c",{rgb[15:11],rgb[15:13]},{rgb[10:5],rgb[10:9]},{rgb[4:0],rgb[4:2]});
  end
  $fclose(fd);$display("PASS media_preview actual gallery800x600");$finish;
 end
endmodule
