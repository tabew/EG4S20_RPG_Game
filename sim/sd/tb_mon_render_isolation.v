`timescale 1ns/1ps
// Public RGB/sync only: a transformed monster may not move any other pixels.
module tb_mon_render_isolation;
 reg clk=0;always #5 clk=~clk;
 reg rst_n=0,we=0;reg [10:0]waddr=0;reg [16:0]wdata=0;
 reg [1:0]rotation=0;reg mirror=0;
 wire[1:0]hs,vs,de,tick,fb_req;
 wire[15:0]rgb[0:1];wire[23:0]full[0:1];wire[15:0]tf_addr[0:1];
 genvar g;
 generate for(g=0;g<2;g=g+1)begin:render
  rpg_video #(.VIDEO_MODE(1),.TEST_BARS(0)) dut(
   .clk(clk),.rst_n(rst_n),.we(we),.waddr(waddr),.wdata(wdata),
   .anim_on(1'b0),.anim_frame(3'd0),.mon_on(1'b1),.mon_id(5'd0),.mon_fade(4'd8),
   .mon_rotation(g==0?2'd0:rotation),.mon_mirror(g==0?1'b0:mirror),
   .hit_trig(1'b0),.hit_kind(2'd0),
   .bars(64'd0),.gal_on(1'b0),.gal_img(2'd0),.gal_fade(4'd8),
   .tf_valid(1'b0),.tf_err(2'd0),.diag(8'd0),.diag2(8'd0),.dfill(1'b0),.tf_rdata(4'd0),.tf_raddr(tf_addr[g]),
   .media_mode(2'd2),.media_auto(1'b0),.media_settings(1'b0),.media_loading(1'b0),.media_osd(1'b0),
   .media_index(6'd0),.media_count(6'd1),.media_name(64'd0),.media_brightness(4'd4),.media_contrast(2'd1),.media_view(2'd0),.media_visual(1'b0),
   .frame_tick(tick[g]),.hs(hs[g]),.vs(vs[g]),.de(de[g]),.rgb(rgb[g]),
   .fb_front_valid(1'b0),.fb_pixel_valid(1'b0),.fb_pixel_rgb(24'd0),.fb_pixel_req(fb_req[g]),.rgb_full(full[g]));
 end endgenerate
 reg[15:0]font[0:8191];
 function[23:0]expand;
 input[15:0]c;
 begin expand={c[15:11],c[15:13],c[10:5],c[10:9],c[4:0],c[4:2]};end
 endfunction
 integer i,cx,cy,code;reg[3:0]bg;
 integer cfg=0,frame_pixels=0,frame_outside=0,frame_text=0,frame_diff=0;
 integer total_pixels=0,total_outside=0,total_text=0,total_diff=0;
 integer ox=0,oy=-1,row_pixels=0,frames=0;
 reg initialized=0,armed=0,checking=0,prev_de=0,prev_vs=1,prev_tick=0;
 reg in_window,in_text,glyph;reg[23:0]expected_text;
 initial begin
  $readmemh("D:/EG4S20_RPG_Game-main/rtl/gen/font.hex",font);
  for(i=0;i<1200;i=i+1)begin
   @(negedge clk);we=1;waddr=i;cx=i%40;cy=i/40;bg=2+(cx+cy)%4;
   wdata={bg,4'd14,9'd0};
   // Two text cells deliberately occupy the monster window and its last edge.
   if(i==4*40+16)wdata={4'd3,4'd14,9'd65};
   if(i==11*40+23)wdata={4'd3,4'd14,9'd57};
   // Footer/title and camp/map-like colored cells remain outside the object.
   if(cy==22 && cx>=2 && cx<10)wdata={4'd1,4'd8,9'd70};
  end
  @(negedge clk);we=0;rst_n=1;initialized=1;
 end
 always @(posedge clk)begin
  #1;
  if(initialized)begin
   if(hs[0]!==hs[1]||vs[0]!==vs[1]||de[0]!==de[1]||tick[0]!==tick[1])$fatal(1,"monster transform changed public timing");
   if(fb_req!==0)$fatal(1,"monster transform requested gallery framebuffer pixels");
   if(tick[0]&&!prev_tick)begin
    if(checking)begin
     if(frame_pixels!=307200 || oy!=479 || row_pixels!=640)$fatal(1,"incomplete public raster %0d row%0d count%0d",frame_pixels,oy,row_pixels);
     if(frame_outside!=286464 || frame_text!=512)$fatal(1,"missing isolation coverage outside%0d text%0d",frame_outside,frame_text);
     $display("PASS mon_render cfg=%0d rotation=%0d mirror=%b full=%0d outside=%0d text=%0d changed_inside=%0d",cfg,rotation,mirror,frame_pixels,frame_outside,frame_text,frame_diff);$fflush();
     frames=frames+1;total_pixels=total_pixels+frame_pixels;total_outside=total_outside+frame_outside;total_text=total_text+frame_text;total_diff=total_diff+frame_diff;
     if(cfg==7)begin
      if(total_diff<100)$fatal(1,"transform inputs never changed visible monster");
      $display("PASS mon_render_isolation frames=%0d pixels=%0d outside_equal=%0d glyph_priority=%0d transformed_pixels=%0d",frames,total_pixels,total_outside,total_text,total_diff);$finish;
     end
     cfg=cfg+1;
    end
    armed=1;checking=0;frame_pixels=0;frame_outside=0;frame_text=0;frame_diff=0;
    // Configuration changes while the visible scan is in vertical blank only.
    rotation=cfg[1:0];mirror=cfg[2];
   end
   if(armed && !prev_vs && vs[0])begin checking=1;ox=0;oy=-1;row_pixels=0;end
   if(checking && de[0])begin
    if(!prev_de)begin
     if(oy>=0 && row_pixels!=640)$fatal(1,"wrong active row width");
     ox=0;oy=oy+1;row_pixels=0;
    end
    if(oy<0||oy>=480||ox>=640)$fatal(1,"public raster range");
    if((^full[0])===1'bx || (^full[1])===1'bx)$fatal(1,"undefined active RGB");
    in_window=ox>=240 && ox<384 && oy>=48 && oy<192;
    in_text=((ox/16==16 && oy/16==4)||(ox/16==23 && oy/16==11));
    if(!in_window)begin
     if(full[0]!==full[1]||rgb[0]!==rgb[1])$fatal(1,"outside monster changed cfg%0d x%0d y%0d %h %h",cfg,ox,oy,full[0],full[1]);
     frame_outside=frame_outside+1;
    end else if(in_text)begin
     code=(oy/16==4)?65:57;glyph=font[code*16+(oy%16)][15-(ox%16)];
     expected_text=expand(glyph?16'hf81f:16'h7bef);
     if(full[0]!==expected_text||full[1]!==expected_text)$fatal(1,"text priority/alignment cfg%0d x%0d y%0d actual%h/%h expected%h",cfg,ox,oy,full[0],full[1],expected_text);
     frame_text=frame_text+1;
    end
    if(in_window && !in_text && full[0]!==full[1])frame_diff=frame_diff+1;
    frame_pixels=frame_pixels+1;row_pixels=row_pixels+1;ox=ox+1;
   end
   prev_de=de[0];prev_vs=vs[0];prev_tick=tick[0];
  end
 end
 initial begin #45000000;$fatal(1,"render isolation timeout cfg%0d frames%0d",cfg,frames);end
endmodule
