`timescale 1ns/1ps
// Public pins only: real timing/font/artwork/monster ROMs, no force or RAM peeks.
module tb_spectrum_border;
`ifndef BORDER_MODE
`define BORDER_MODE 1
`endif
  localparam MODE=`BORDER_MODE, W=(MODE==1)?640:800, H=(MODE==1)?480:600;
  reg clk=0; always #5 clk=~clk;
  reg rst_n=0,we=0,en=0,gal=0;
  reg [10:0] wa=0; reg [16:0] wd=0;
  reg [63:0] levels=0;
  wire hs,vs,de,tick,req,bhs,bvs,bde,btick,breq;
  wire [15:0] rgb,brgb,addr,baddr;
  wire [23:0] full,bfull;
`define PORTS .clk(clk),.rst_n(rst_n),.we(we),.waddr(wa),.wdata(wd), \
    .anim_on(1'b1),.anim_frame(3'd1),.mon_on(1'b1),.mon_id(5'd0),.mon_fade(4'd8), \
    .mon_rotation(2'd1),.mon_mirror(1'b1),.bars(64'h3c30241810080400), \
    .gal_on(gal),.gal_img(2'd0),.gal_fade(4'd8),.tf_valid(1'b1),.tf_err(2'd0), \
    .diag(8'ha5),.diag2(8'h96),.dfill(1'b0),.tf_rdata(4'd12), \
    .media_mode(2'd0),.media_auto(1'b0),.media_settings(1'b0),.media_loading(1'b0), \
    .media_osd(1'b0),.media_index(6'd0),.media_count(6'd1),.media_name("BORDER00"), \
    .media_brightness(4'd4),.media_contrast(2'd1),.media_view(2'd0),.media_visual(1'b1), \
    .fb_front_valid(gal),.fb_pixel_valid(1'b1),.fb_pixel_rgb(24'h123456)
  rpg_video #(.VIDEO_MODE(MODE)) dut(`PORTS,.spectrum_border_en(en),.spectrum_levels(levels),
    .hs(hs),.vs(vs),.de(de),.frame_tick(tick),.rgb(rgb),.rgb_full(full),.fb_pixel_req(req),.tf_raddr(addr));
  rpg_video_legacy #(.VIDEO_MODE(MODE)) baseline(`PORTS,
    .hs(bhs),.vs(bvs),.de(bde),.frame_tick(btick),.rgb(brgb),.rgb_full(bfull),.fb_pixel_req(breq),.tf_raddr(baddr));
`undef PORTS
  integer px=0,py=0,frames=0,checks=0,inside=0,changed=0,outer=0;
  integer lx,ly,band,depth,lev,height,grid;
  reg model_en=0; reg [63:0] model_levels=0;
  reg [15:0] want; reg [23:0] want_full;
  function [23:0] expand;
    input [15:0] c;
    begin expand={c[15:11],c[15:13],c[10:5],c[10:9],c[4:0],c[4:2]};end
  endfunction
  // Oracle deliberately uses integer scaling, division and explicit inequalities.
  function [15:0] colour;
    input integer d;
    begin
      if(d<=2) colour=16'h041f; else if(d<=4) colour=16'h07ff;
      else if(d<=7) colour=16'h07e0; else if(d<=10) colour=16'hffe0;
      else if(d<=12) colour=16'hfd20; else colour=16'hf800;
    end
  endfunction
  always @(posedge clk) if(rst_n && tick) begin
    model_en=(en===1'b1);model_levels=levels;
  end
  always @(negedge clk) if(rst_n) begin
    if({hs,vs,de,tick,req,addr} !== {bhs,bvs,bde,btick,breq,baddr})
      $fatal(1,"timing/request divergence mode=%0d",MODE);
    if(tick) begin
      frames=frames+1;
      if(frames>1 && (py!=H || px!=0)) $fatal(1,"active dimensions %0d,%0d",px,py);
      px=0;py=0;
    end
    if(de) begin
      if(frames>=1) begin
        lx=(MODE==1)?px:(px*4/5);ly=(MODE==1)?py:(py*4/5);
        want=brgb;want_full=bfull;
        if(model_en && !gal && (lx<16 || lx>=624 || ly<16 || ly>=464)) begin
          outer=outer+1;
          if(ly<16 || ly>=464) begin
            band=lx/80;grid=lx%16;depth=(ly<16)?ly:479-ly;
          end else begin
            band=ly/60;grid=ly%16;depth=(lx<16)?lx:639-lx;
          end
          lev=(model_levels>>(band*8))&255;if(lev>120) lev=120;
          height=lev*15/128;
          want=(lx==0 || lx==639 || ly==0 || ly==479)?16'h0843:
            (grid>=2 && grid<14 && depth>=1 && depth<=height)?colour(depth):16'h0000;
          want_full=expand(want);
        end else if(lx>=16 && lx<624 && ly>=16 && ly<464) inside=inside+1;
        checks=checks+1;
        if(rgb!==want || full!==want_full)
          $fatal(1,"RGB mode=%0d frame=%0d physical=%0d,%0d logical=%0d,%0d got=%h/%h want=%h/%h",MODE,frames,px,py,lx,ly,rgb,full,want,want_full);
        if(rgb!==brgb) changed=changed+1;
      end
      if(px==W-1) begin px=0;py=py+1;end else px=px+1;
    end
  end
  task set_frame;
    input enable;input [63:0] value;input gallery;
    begin @(posedge tick);@(negedge clk);en=enable;levels=value;gal=gallery;end
  endtask
  integer i,c,r,g;
  initial begin
    repeat(3) @(negedge clk);rst_n=1;
    // Write every public cell. Blank monster/animation area; actual font glyphs
    // elsewhere, red HP-like cells and gray internal frame cells included.
    for(i=0;i<1200;i=i+1) begin
      @(negedge clk);we=1;wa=i;c=i%40;r=i/40;
      g=(i%300)+1;
      if(c>=15 && c<24 && r>=3 && r<12) g=0;
      if(c>=12 && c<28 && r>=12 && r<22) g=0;
      wd={4'd0,4'd4,g[8:0]};
      if(c==0 || c==39 || r==0 || r==29) wd={4'd0,4'd5,9'd1};
      if(r==18 && c>=8 && c<20) wd={4'd5,4'd5,9'd1};
      if(r==2 || r==12 || r==17 || r==22) wd={4'd0,4'd3,9'd1};
    end
    @(negedge clk);we=0;
    if($test$plusargs("distinct_only")) begin
      // Eight distinct visible heights: 1,2,4,5,7,8,10,14; catches every bin mux.
      set_frame(1,64'h785a483c3024180c,0);
      @(posedge tick);@(negedge clk);
      if(inside<100000 || outer<10000 || changed<10000) $fatal(1,"distinct coverage");
      $display("PASS spectrum_border distinct MODE=%0d RGB_checks=%0d interior=%0d outer=%0d",MODE,checks,inside,outer);
      $finish;
    end
    set_frame(1,0,0); // silence: black strip and dim one-pixel outline only
    set_frame(1,64'h0000000000000078,0); // band 0 only
    set_frame(1,64'h7800000000000000,0); // band 7 only
    set_frame(1,64'h786454443c180800,0); // distinct bins, exact colour checks
    // Mid-frame data and enable update must leave the remainder unchanged.
    wait(py==100 && px==100);@(negedge clk);levels=64'hffffffffffffffff;en=0;
    @(posedge tick); // previous mixed frame completed without tearing
    set_frame(1,64'h3c3c3c3c3c3c3c3c,0);
    set_frame(1,64'h7878787878787878,0);
    set_frame(1,64'hffffffffffffffff,0); // clamp 255 equals 120
    set_frame(1,64'h0101010101010101,0); // near-zero quantization
    set_frame(1,0,0);
    // Repeat unchanging silence and known data across complete frames.
    set_frame(1,0,0);
    set_frame(1,64'h3c3c3c3c3c3c3c3c,0);
    set_frame(1,64'h3c3c3c3c3c3c3c3c,0);
    set_frame(1'bz,64'hffffffffffffffff,0);
    set_frame(1'bx,64'hffffffffffffffff,0);
    set_frame(1,64'hffffffffffffffff,1); // RGB888 gallery must be bit identical
    set_frame(0,0,0);
    @(posedge tick);@(negedge clk);
    if(inside<100000 || outer<10000 || changed<10000) $fatal(1,"insufficient coverage");
    $display("PASS spectrum_border MODE=%0d frames=%0d RGB_checks=%0d interior=%0d outer=%0d changes=%0d",MODE,frames,checks,inside,outer,changed);
    $finish;
  end
  initial begin #200000000;$fatal(1,"timeout");end
endmodule
