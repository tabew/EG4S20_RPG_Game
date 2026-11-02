`timescale 1ns/1ps
// Public gallery pins only: one-cycle RAM model and independently calculated RGB.
module tb_media_video;
  reg clk=0; always #5 clk=~clk;
  reg rst_n=0,gal_on=1;
  reg [11:0] x2=0,y2=0,x3=0,y3=0;
  reg [3:0] data=0,fade=8,bright=4;
  reg [1:0] view=0,contrast=1,mode=0,err=0;
  reg valid=1,loading=0,osd=0,auto_play=1,settings=0,visual=1;
  reg [5:0] idx=0,count=16;
  reg [63:0] name="ALPHA001";
  wire [15:0] addr,rgb;
  integer checks=0,i,j,k,f,a,b,xx,yy,sx,sy,ox,oy,ww,hh,expected_addr;
  integer pattern=0;
  reg [3:0] nib=0;
  reg [15:0] expected;
  gal_layer dut(.clk(clk),.rst_n(rst_n),.gal_on(gal_on),.gal_img(2'd0),.gal_fade(fade),
    .x2(x2),.y2(y2),.x3(x3),.y3(y3),.tf_valid(valid),.tf_err(err),
    .diag(8'ha5),.diag2(8'h96),.dfill(1'b0),.tf_rdata(data),.tf_raddr(addr),.gal_rgb(rgb),
    .media_mode(mode),.media_auto(auto_play),.media_settings(settings),.media_loading(loading),
    .media_osd(osd),.media_index(idx),.media_count(count),.media_name(name),
    .media_brightness(bright),.media_contrast(contrast),.media_view(view),.media_visual(visual));
  wire [15:0] piped_addr,piped_rgb;
  reg [15:0] expected_p1=0,expected_p2=0;
  integer pipeline_checks=0;
  gal_layer #(.PIPELINE(1)) piped(.clk(clk),.rst_n(rst_n),.gal_on(gal_on),.gal_img(2'd0),.gal_fade(fade),
    .x2(x2),.y2(y2),.x3(x3),.y3(y3),.tf_valid(valid),.tf_err(err),
    .diag(8'ha5),.diag2(8'h96),.dfill(1'b0),.tf_rdata(data),.tf_raddr(piped_addr),.gal_rgb(piped_rgb),
    .media_mode(mode),.media_auto(auto_play),.media_settings(settings),.media_loading(loading),
    .media_osd(osd),.media_index(idx),.media_count(count),.media_name(name),
    .media_brightness(bright),.media_contrast(contrast),.media_view(view),.media_visual(visual));
  always @(posedge clk) begin
    x3<=x2; y3<=y2;
    data<=pattern ? (addr[3:0]^addr[11:8]) : nib;
    if(!rst_n) begin expected_p1<=0;expected_p2<=0;end
    else begin expected_p1<=rgb;expected_p2<=expected_p1;end
    #2;
    if(rst_n) begin
      pipeline_checks=pipeline_checks+1;
      if(piped_rgb!==expected_p2 || piped_addr!==addr)
        $fatal(1,"pipeline equivalence RGB got %h expected %h",piped_rgb,expected_p2);
    end
  end
  function [15:0] palette;
    input integer n;
    begin case(n)
      0:palette=16'h0000;1:palette=16'h0841;2:palette=16'h10a2;3:palette=16'h18e3;
      4:palette=16'h3186;5:palette=16'h4208;6:palette=16'h8000;7:palette=16'hc000;
      8:palette=16'he800;9:palette=16'hfd20;10:palette=16'hfe60;11:palette=16'hffe0;
      12:palette=16'hffff;13:palette=16'h7bef;14:palette=16'h39e7;15:palette=16'h0220;
    endcase end
  endfunction
  function integer channel;
    input integer c,maxc,mid,br,co,fa;
    integer v,offset;
    begin
      v=c-mid;
      // Floor division, including negative values, independently of arithmetic shifts.
      if(co==0) v=(v<0) ? -((-v+1)/2) : v/2;
      if(co==2) v=v+((v<0) ? -((-v+1)/2) : v/2);
      offset=(br-4)*((maxc==63)?8:4);
      v=v+mid+offset;
      if(v<0) v=0; if(v>maxc) v=maxc;
      // The established fmul rounds each shift term separately.
      if(fa<8) channel=((fa&4)?v/2:0)+((fa&2)?v/4:0)+((fa&1)?v/8:0);
      else channel=v;
    end
  endfunction
  function [15:0] adjusted;
    input integer n,br,co,fa;
    reg [15:0] p;
    integer r,g,b;
    begin p=palette(n);
      r=channel((p>>11)&31,31,16,br,co,fa);
      g=channel((p>>5)&63,63,32,br,co,fa);
      b=channel(p&31,31,16,br,co,fa);
      adjusted=(r<<11)|(g<<5)|b;
    end
  endfunction
  task pixel;
    input integer x,y;
    begin @(negedge clk);x2=x;y2=y;@(posedge clk);#1; end
  endtask
  task equal_rgb;
    input [15:0] want;
    begin checks=checks+1;
      if(rgb!==want) $fatal(1,"RGB x=%0d y=%0d got=%h expected=%h br=%0d co=%0d fade=%0d",x3,y3,rgb,want,bright,contrast,fade);
    end
  endtask
  task glyph;
    input integer row_y,col;
    input [34:0] bits;
    integer gx,gy;
    reg [15:0] ink;
    begin
      ink=(row_y==8)?16'hffe0 : (row_y==26 && (loading || err!=0))?16'hfd20 :
          (row_y>=474)?16'h07ff : 16'hffff;
      for(gy=0;gy<7;gy=gy+1) for(gx=0;gx<5;gx=gx+1) begin
        pixel(16+col*12+gx*2,row_y+gy*2);
        checks=checks+1;
        if((rgb==ink)!==bits[34-gy*5-gx])
          $fatal(1,"glyph row=%0d col=%0d x=%0d y=%0d RGB=%h",row_y,col,gx,gy,rgb);
      end
    end
  endtask
  reg [34:0] glyph_a=35'b01110_10001_10001_11111_10001_10001_10001;
  reg [34:0] glyph_b=35'b11110_10001_10001_11110_10001_10001_11110;
  reg [34:0] glyph_1=35'b00100_01100_00100_00100_00100_00100_01110;
  reg [34:0] glyph_2=35'b01110_10001_00001_00010_00100_01000_11111;
  reg [34:0] glyph_l=35'b10000_10000_10000_10000_10000_10000_11111;
  reg [34:0] glyph_e=35'b11111_10000_10000_11110_10000_10000_11111;
  initial begin
    repeat(3) @(negedge clk);rst_n=1;
    // Every palette channel, every supported brightness/contrast and fade.
    for(i=0;i<16;i=i+1) for(j=0;j<=8;j=j+1) for(k=0;k<3;k=k+1) for(f=0;f<=8;f=f+1) begin
      nib=i;bright=j;contrast=k;fade=f;pixel(200,100);equal_rgb(adjusted(i,j,k,f));
    end
    bright=4;contrast=1;fade=8;pattern=1;
    // All picture pixels, including every source edge, in each view.
    for(a=0;a<3;a=a+1) begin
      view=a;ox=(a==1)?192:64;oy=(a==1)?140:44;ww=(a==1)?256:512;hh=(a==1)?192:384;
      for(yy=oy;yy<oy+hh;yy=yy+1) for(xx=ox;xx<ox+ww;xx=xx+1) begin
        if(a==0) begin sx=(xx-ox)/2;sy=(yy-oy)/2;end
        else if(a==1) begin sx=xx-ox;sy=yy-oy;end
        else begin sx=64+(xx-ox)/4;sy=48+(yy-oy)/4;end
        expected_addr=sy*256+sx;
        @(negedge clk);x2=xx;y2=yy;#1;
        checks=checks+1;
        if(addr!==expected_addr[15:0] || addr>=49152) $fatal(1,"view %0d address %h expected %h",a,addr,expected_addr);
        @(posedge clk);#1;equal_rgb(palette((sx&15)^(sy&15)));
      end
      pixel(ox-1,oy);if(addr!==0) $fatal(1,"left outside address");
      pixel(ox+ww,oy);if(addr!==0) $fatal(1,"right outside address");
      pixel(ox,oy-1);if(addr!==0) $fatal(1,"top outside address");
      pixel(ox,oy+hh);if(addr!==0) $fatal(1,"bottom outside address");
    end
    // Healthy and error loading both mask stale RAM and diagnostic windows.
    view=0;pattern=0;nib=12;loading=1;
    for(a=0;a<4;a=a+1) begin
      err=a;pixel(200,100);equal_rgb(0);if(addr!==0) $fatal(1,"loading address");
      pixel(192,216);equal_rgb(0);pixel(0,0);equal_rgb(0);
    end
    loading=0;err=2;pixel(200,100);equal_rgb(16'hffe0);
    // Errors take precedence even when tf_valid still holds the previous image.
    err=3;pixel(200,100);equal_rgb(16'hf81f);err=0;
    osd=1;loading=1;
    glyph(26,5,glyph_a);name="BLPHA001";glyph(26,5,glyph_b);
    glyph(8,29,glyph_1);idx=1;glyph(8,29,glyph_2);
    // Visible LOADING / ERROR status and dynamic numeric settings.
    glyph(26,26,glyph_l);loading=0;err=1;
    glyph(26,26,glyph_e);
    err=0;valid=1;
    count=18;glyph(8,32,glyph_2);
    mode=1;glyph(8,2,glyph_l);
    mode=2;glyph(8,2,35'b10001_11011_10101_10101_10001_10001_10001);
    auto_play=0;glyph(8,10,35'b11110_10001_10001_11110_10000_10000_10000);
    contrast=0;glyph(474,21,glyph_l);
    contrast=2;glyph(474,21,35'b10001_10001_10001_11111_10001_10001_10001);
    view=1;glyph(474,35,glyph_a);
    view=2;glyph(474,34,35'b11111_00001_00010_00100_01000_10000_11111);
    glyph(474,7,35'b00010_00110_01010_10010_11111_00010_00010);
    bright=2;glyph(474,7,glyph_2);
    settings=1;pixel(18,496);checks=checks+1;if(rgb==0) $fatal(1,"settings row hidden");
    pixel(24,570);equal_rgb(16'h07ff);
    for(a=0;a<8;a=a+1) begin pixel(0,600);pixel(0,599);end
    pixel(24,570);equal_rgb(0); // marquee has advanced two physical pixels
    osd=0;pixel(16,496);equal_rgb(0);
    gal_on=0;pixel(200,100);equal_rgb(0);if(addr!==0) $fatal(1,"gallery disabled reads");
    $display("PASS media_video: %0d public RGB/address assertions",checks);$finish;
  end
  initial begin #20000000;$fatal(1,"media test timeout");end
endmodule

// Exercise the complete display pipeline with its real 40 MHz timing generator.
// Only unrelated artwork/font blocks are replaced with zero-data combinational stubs.
module tb_media_frame;
  reg clk=0;always #5 clk=~clk;
  reg rst_n=0,visual=0,loading=0;
  wire tick,de,hs,vs;
  wire [15:0] rgb,addr;
  integer cycles=0,last_tick=0,ticks=0,active=0,checks=0;
  reg tick_d=0;
  rpg_video dut(.clk(clk),.rst_n(rst_n),.we(1'b0),.waddr(11'd0),.wdata(17'd0),
    .anim_on(1'b0),.anim_frame(3'd0),.mon_on(1'b0),.mon_id(5'd0),.mon_fade(4'd8),
    .bars(64'h7878787878787878),.gal_on(1'b1),.gal_img(2'd0),.gal_fade(4'd8),
    .tf_valid(1'b1),.tf_err(2'd0),.diag(8'd0),.diag2(8'd0),.dfill(1'b0),
    .tf_rdata(4'd12),.tf_raddr(addr),.hs(hs),.vs(vs),.de(de),.rgb(rgb),.frame_tick(tick),
    .media_mode(2'd0),.media_auto(1'b1),.media_settings(1'b0),.media_loading(loading),
    .media_osd(1'b0),.media_index(6'd0),.media_count(6'd1),.media_name("FRAME001"),
    .media_brightness(4'd4),.media_contrast(2'd1),.media_view(2'd0),.media_visual(visual));
  always @(negedge clk) if(rst_n) begin
    cycles=cycles+1;
    if(de) active=active+1;
    if(tick) begin
      if(de || tick_d) $fatal(1,"frame_tick overlaps active video or lasts multiple clocks");
      if(ticks!=0) begin
        if(cycles-last_tick!=1056*628) $fatal(1,"frame_tick period");
        if(active!=800*600) $fatal(1,"active frame size %0d",active);
        checks=checks+1;
      end
      last_tick=cycles;ticks=ticks+1;active=0;
    end
    tick_d=tick;
  end
  task sample_bar;
    input [15:0] expected;
    integer px,py;
    begin
      // At tick the active frame has finished. Count DE pixels in the next frame.
      @(posedge tick);@(negedge clk);
      for(py=0;py<=510;py=py+1) begin
        while(de!==1'b1) @(negedge clk);
        for(px=0;px<800;px=px+1) begin
          if(py==510 && px==40) begin
            checks=checks+1;
            if(rgb!==expected) $fatal(1,"public bar RGB %h expected %h",rgb,expected);
          end
          @(negedge clk);
        end
        while(de===1'b1) @(negedge clk);
      end
    end
  endtask
  initial begin
    repeat(4) @(negedge clk);rst_n=1;
    sample_bar(16'h0000);visual=1;
    sample_bar(16'hffff);loading=1;
    sample_bar(16'h0000);
    $display("PASS media_frame: %0d public raster/tick/bar assertions",checks);$finish;
  end
  initial begin #30000000;$fatal(1,"frame test timeout");end
endmodule
// Real banked RAM feeds both gallery variants; compare public RGB at two clocks.
module tb_media_pipeline;
  reg clk=0;always #5 clk=~clk;
  reg rst_n=0,wren=0,on=1,osd=1,loading=0,settings=0;
  reg [15:0] wa=0;
  reg [3:0] wd=0,bright=4,fade=8;
  reg [1:0] view=0,contrast=1,mode=0,err=0;
  reg [5:0] index=0;
  reg [63:0] name="ALPHA001";
  reg [11:0] x2=0,y2=0,x3=0,y3=0;
  wire [3:0] rd;
  wire [15:0] a0,a1,c0,c1;
  reg [15:0] ref1=0,ref2=0;
  integer n,checks=0;
  tf_ram ram(.wclk(clk),.waddr(wa),.wren(wren),.wdata(wd),.rclk(clk),.raddr(a0),.rdata(rd));
  gal_layer #(.PIPELINE(0)) plain(.clk(clk),.rst_n(rst_n),.gal_on(on),.gal_img(2'd0),.gal_fade(fade),
    .x2(x2),.y2(y2),.x3(x3),.y3(y3),.tf_valid(1'b1),.tf_err(err),.diag(8'ha5),.diag2(8'h69),
    .dfill(1'b0),.tf_rdata(rd),.tf_raddr(a0),.gal_rgb(c0),.media_mode(mode),.media_auto(index[0]),
    .media_settings(settings),.media_loading(loading),.media_osd(osd),.media_index(index),
    .media_count(6'd31),.media_name(name),.media_brightness(bright),.media_contrast(contrast),
    .media_view(view),.media_visual(1'b0));
  gal_layer #(.PIPELINE(1)) piped(.clk(clk),.rst_n(rst_n),.gal_on(on),.gal_img(2'd0),.gal_fade(fade),
    .x2(x2),.y2(y2),.x3(x3),.y3(y3),.tf_valid(1'b1),.tf_err(err),.diag(8'ha5),.diag2(8'h69),
    .dfill(1'b0),.tf_rdata(rd),.tf_raddr(a1),.gal_rgb(c1),.media_mode(mode),.media_auto(index[0]),
    .media_settings(settings),.media_loading(loading),.media_osd(osd),.media_index(index),
    .media_count(6'd31),.media_name(name),.media_brightness(bright),.media_contrast(contrast),
    .media_view(view),.media_visual(1'b0));
  always @(posedge clk) begin
    x3<=x2;y3<=y2;
    if(!rst_n) begin ref1<=0;ref2<=0;end
    else begin ref1<=c0;ref2<=ref1;end
    #2;
    if(rst_n) begin
      checks=checks+1;
      if(a0!==a1 || c1!==ref2)
        $fatal(1,"real RAM pipeline RGB got=%h expected=%h addr=%h/%h",c1,ref2,a0,a1);
    end
  end
  initial begin
    for(n=0;n<49152;n=n+1) begin
      @(negedge clk);wa=n;wd=(n^(n>>8))&15;wren=1;
    end
    @(negedge clk);wren=0;rst_n=1;
    for(n=0;n<100000;n=n+1) begin
      @(negedge clk);
      x2=n%800;y2=((n/800)*11)%628;
      if(n%37==0) begin
        view=(n/37)%3;contrast=(n/37)%3;bright=(n/37)%9;
        fade=(n/37)%9;mode=(n/37)%3;index=(n/37)%32;
        name=(n&1)?"BETA002 ":"ALPHA001";
        loading=(n/37)%11==0;err=((n/37)%13==0)?2'd2:2'd0;
        settings=(n/37)&1;osd=(n/37)%5!=0;on=(n/37)%17!=0;
      end
    end
    repeat(4) @(negedge clk);
    $display("PASS media_pipeline: %0d real-RAM changing pixel/control equivalence checks",checks);$finish;
  end
  initial begin #3000000;$fatal(1,"pipeline test timeout");end
endmodule
module font_rom(input clk,input [8:0] glyph,input [3:0] row,output [15:0] data);
  assign data=16'd0;
endmodule
module anim_rom(input clk,input [14:0] addr,output [7:0] data,input [3:0] pal_idx,output [15:0] pal_rgb);
  assign data=8'd0;assign pal_rgb=16'd0;
endmodule
module mon_layer(input clk,input rst_n,input [4:0] mon_id,input [3:0] fade,
  input [1:0] rotation,input mirror,input [11:0] x,input [11:0] y,output in_win,output [15:0] rgb,output valid);
  assign in_win=1'b0;assign rgb=16'd0;assign valid=1'b0;
endmodule

// Public RGB888 pins: every eight-bit channel level, adjustment and two-stage latency.
module tb_media_rgb888;
 reg clk=0;always #5 clk=~clk;
 reg rst_n=0,on=1,front=1,loading=0,osd=0,settings=0,valid=1;
 reg [11:0] x2=0,y2=0,x3=0,y3=0;
 reg [23:0] source=0,pixel_rgb=0;
 reg pixel_valid=0;
 reg [3:0] bright=4,fade=8;
 reg [1:0] contrast=1,view=0,err=0;
 wire req0,req1;
 wire [23:0] rgb0,rgb1;
 wire [15:0] legacy0,legacy1,addr0,addr1;
 reg [23:0] reference1=0,reference2=0;
 integer checks=0,equivalence=0,c,b,k,f;
 gal_layer #(.PIPELINE(0)) plain(.clk(clk),.rst_n(rst_n),.gal_on(on),.gal_img(2'd0),.gal_fade(fade),
  .x2(x2),.y2(y2),.x3(x3),.y3(y3),.tf_valid(1'b0),.tf_err(err),.diag(8'ha5),.diag2(8'h96),
  .dfill(1'b0),.tf_rdata(4'd7),.tf_raddr(addr0),.gal_rgb(legacy0),.gal_rgb_full(rgb0),
  .media_mode(2'd0),.media_auto(1'b1),.media_settings(settings),.media_loading(loading),.media_osd(osd),
  .media_index(6'd0),.media_count(6'd3),.media_name("FULL0001"),.media_brightness(bright),
  .media_contrast(contrast),.media_view(view),.media_visual(1'b0),
  .fb_front_valid(front),.fb_pixel_valid(pixel_valid),.fb_pixel_rgb(pixel_rgb),.fb_pixel_req(req0));
 gal_layer #(.PIPELINE(1)) piped(.clk(clk),.rst_n(rst_n),.gal_on(on),.gal_img(2'd0),.gal_fade(fade),
  .x2(x2),.y2(y2),.x3(x3),.y3(y3),.tf_valid(1'b0),.tf_err(err),.diag(8'ha5),.diag2(8'h96),
  .dfill(1'b0),.tf_rdata(4'd7),.tf_raddr(addr1),.gal_rgb(legacy1),.gal_rgb_full(rgb1),
  .media_mode(2'd0),.media_auto(1'b1),.media_settings(settings),.media_loading(loading),.media_osd(osd),
  .media_index(6'd0),.media_count(6'd3),.media_name("FULL0001"),.media_brightness(bright),
  .media_contrast(contrast),.media_view(view),.media_visual(1'b0),
  .fb_front_valid(front),.fb_pixel_valid(pixel_valid),.fb_pixel_rgb(pixel_rgb),.fb_pixel_req(req1));
 always @(posedge clk) begin
  x3<=x2;y3<=y2;pixel_rgb<=source;pixel_valid<=req0 && valid;
  if(!rst_n)begin reference1<=0;reference2<=0;end
  else begin reference1<=rgb0;reference2<=reference1;end
  #2;
  if(rst_n)begin
   equivalence=equivalence+1;
   if(req0!==req1 || rgb1!==reference2)$fatal(1,"RGB888 latency got %h expected %h",rgb1,reference2);
   if(legacy0!=={rgb0[23:19],rgb0[15:10],rgb0[7:3]} && front)$fatal(1,"RGB888 legacy projection");
   if(addr0!==0 || addr1!==0)$fatal(1,"full framebuffer used legacy RAM");
  end
 end
 function integer adjust;
  input integer value,br,co,fa;
  integer v;
  begin
   v=value-128;
   if(co==0)v=(v<0)?-((-v+1)/2):v/2;
   if(co==2)v=v+((v<0)?-((-v+1)/2):v/2);
   v=v+128+(br-4)*32;if(v<0)v=0;if(v>255)v=255;
   adjust=(fa>=8)?v:((fa&4)?v/2:0)+((fa&2)?v/4:0)+((fa&1)?v/8:0);
  end
 endfunction
 task sample;
  input integer px,py;
  input [23:0] expected;
  begin
   @(negedge clk);x2=px;y2=py;@(posedge clk);#1;checks=checks+1;
   if(rgb0!==expected)$fatal(1,"RGB888 xy=%0d,%0d got=%h expected=%h bright=%0d contrast=%0d fade=%0d",px,py,rgb0,expected,bright,contrast,fade);
  end
 endtask
 reg [23:0] expected;
 initial begin
  repeat(3)@(negedge clk);rst_n=1;
  for(c=0;c<256;c=c+1)for(b=0;b<=8;b=b+1)for(k=0;k<3;k=k+1)for(f=0;f<=8;f=f+1)begin
   source={c[7:0],(c[7:0]^8'h5a),~c[7:0]};bright=b;contrast=k;fade=f;
   expected={8'(adjust(c,b,k,f)),8'(adjust(c^90,b,k,f)),8'(adjust(255-c,b,k,f))};
   @(negedge clk);x2=100;y2=100;@(posedge clk);#1;sample(100,100,expected);
  end
  bright=4;contrast=1;fade=8;source=24'h123557;
  for(view=0;view<3;view=view+1)begin
   sample(80,60,source);sample(719,539,source);
   @(negedge clk);x2=79;y2=60;#1;if(req0)$fatal(1,"left framebuffer read");
   @(negedge clk);x2=720;y2=60;#1;if(req0)$fatal(1,"right framebuffer read");
   @(negedge clk);x2=80;y2=59;#1;if(req0)$fatal(1,"top framebuffer read");
   @(negedge clk);x2=80;y2=540;#1;if(req0)$fatal(1,"bottom framebuffer read");
   sample(100,100,source);
  end
  for(err=0;err<3;err=err+1)begin
   loading=1;sample(100,100,source);if(!req0)$fatal(1,"loading dropped front read");
   loading=0;sample(100,100,source);
  end
  valid=0;sample(100,100,0);valid=1;sample(100,100,source);
  osd=1;settings=1;sample(16+6*12,474,source);
  sample(16+34*12,474,24'h00ffff);sample(16+35*12,496,24'h00ffff);
  osd=0;settings=0;on=0;sample(100,100,0);if(req0)$fatal(1,"disabled framebuffer read");
  $display("PASS media_rgb888: %0d color/window assertions, %0d pipeline checks",checks,equivalence);$finish;
 end
 initial begin #5000000;$fatal(1,"RGB888 test timeout");end
endmodule

// Complete raster consumes ordered pixels through the synchronous service pins.
module tb_media_fullframe;
 reg clk=0;always #5 clk=~clk;
 reg rst_n=0,front=1,loading=0;
 reg [1:0] err=0;
 reg [23:0] pixel_rgb=0;
 reg pixel_valid=0;
 wire req,de,tick,hs,vs;
 wire [15:0] rgb,addr;
 wire [23:0] full;
 integer reads=0,frame_reads=0,frames=0,checks=0;
 reg req_s3=0,req_p1=0,req_p2=0;
 reg [23:0] expected_p1=0,expected_p2=0;
 function [23:0] pattern;
  input integer n;
  begin pattern={8'(n*37+n/640),8'(n*73+19),8'(n*11+(n/640)*17)};end
 endfunction
 rpg_video dut(.clk(clk),.rst_n(rst_n),.we(1'b0),.waddr(11'd0),.wdata(17'd0),
  .anim_on(1'b0),.anim_frame(3'd0),.mon_on(1'b0),.mon_id(5'd0),.mon_fade(4'd8),
  .bars(64'd0),.gal_on(1'b1),.gal_img(2'd0),.gal_fade(4'd8),.tf_valid(1'b0),
  .tf_err(err),.diag(8'd0),.diag2(8'd0),.dfill(1'b0),.tf_rdata(4'd0),.tf_raddr(addr),
  .hs(hs),.vs(vs),.de(de),.rgb(rgb),.rgb_full(full),.frame_tick(tick),
  .media_mode(2'd0),.media_auto(1'b1),.media_settings(1'b0),.media_loading(loading),
  .media_osd(1'b0),.media_index(6'd0),.media_count(6'd2),.media_name("FRAME001"),
  .media_brightness(4'd4),.media_contrast(2'd1),.media_view(2'd2),.media_visual(1'b0),
  .fb_front_valid(front),.fb_pixel_valid(pixel_valid),.fb_pixel_rgb(pixel_rgb),.fb_pixel_req(req));
 always @(posedge clk)begin
  if(!rst_n)begin
   pixel_rgb<=0;pixel_valid<=0;req_s3<=0;req_p1<=0;req_p2<=0;expected_p1<=0;expected_p2<=0;
  end else begin
   pixel_valid<=req && (reads%61!=0);pixel_rgb<=pattern(reads);
   req_s3<=req;req_p1<=req_s3;req_p2<=req_p1;
   expected_p1<=pixel_valid?pixel_rgb:24'd0;expected_p2<=expected_p1;
   if(req)begin reads=reads+1;frame_reads=frame_reads+1;end
  end
  #2;
  if(rst_n && req_p2)begin
   checks=checks+1;
   if(!de || full!==expected_p2 || rgb!=={full[23:19],full[15:10],full[7:3]})
    $fatal(1,"fullframe ordered RGB got=%h expected=%h de=%b",full,expected_p2,de);
  end
 end
 always @(posedge tick)if(rst_n)begin
  if(frame_reads!=640*480)$fatal(1,"framebuffer requests=%0d expected307200",frame_reads);
  frame_reads=0;frames=frames+1;
  if(frames==1)begin loading=1;err=2;end
  if(frames==2)begin
   $display("PASS media_fullframe: frames=%0d requests=%0d full RGB assertions=%0d",frames,reads,checks);$finish;
  end
 end
 initial begin repeat(4)@(negedge clk);rst_n=1;end
 initial begin #16000000;$fatal(1,"fullframe timeout");end
endmodule

// Bar compositing retains the low source bits while the front survives loading.
module tb_media_fullbars;
 reg clk=0;always #5 clk=~clk;
 reg rst_n=0,front=1,loading=1;
 reg [1:0] err=2;
 wire req,de,tick,hs,vs;
 wire [15:0] rgb,addr;
 wire [23:0] full;
 integer px,py,checks=0;
 rpg_video dut(.clk(clk),.rst_n(rst_n),.we(1'b0),.waddr(11'd0),.wdata(17'd0),
  .anim_on(1'b0),.anim_frame(3'd0),.mon_on(1'b0),.mon_id(5'd0),.mon_fade(4'd8),
  .bars(64'h7878787878787878),.gal_on(1'b1),.gal_img(2'd0),.gal_fade(4'd8),.tf_valid(1'b0),
  .tf_err(err),.diag(8'd0),.diag2(8'd0),.dfill(1'b0),.tf_rdata(4'd0),.tf_raddr(addr),
  .hs(hs),.vs(vs),.de(de),.rgb(rgb),.rgb_full(full),.frame_tick(tick),
  .media_mode(2'd0),.media_auto(1'b1),.media_settings(1'b0),.media_loading(loading),
  .media_osd(1'b0),.media_index(6'd0),.media_count(6'd2),.media_name("FRAME001"),
  .media_brightness(4'd4),.media_contrast(2'd1),.media_view(2'd2),.media_visual(1'b1),
  .fb_front_valid(front),.fb_pixel_valid(1'b1),.fb_pixel_rgb(24'h123557),.fb_pixel_req(req));
 task check;
  input [23:0] expected;
  begin
   checks=checks+1;
   if(full!==expected || rgb!=={full[23:19],full[15:10],full[7:3]})
    $fatal(1,"RGB888 bar xy=%0d,%0d got=%h expected=%h",px,py,full,expected);
  end
 endtask
 initial begin
  repeat(4)@(negedge clk);rst_n=1;
  @(posedge tick);@(negedge clk);
  for(py=0;py<=513;py=py+1)begin
   while(de!==1'b1)@(negedge clk);
   for(px=0;px<800;px=px+1)begin
    if(py==510 && px==140)check(24'hffffff);
    if(py==513 && px==100)check(24'h123557);
    // Orange expanded to FF8200, source123557: floor average885B2B.
    if(py==513 && px==140)check(24'h885b2b);
    @(negedge clk);
   end
   while(de===1'b1)@(negedge clk);
  end
  $display("PASS media_fullbars: %0d full-precision bar/transparent/load-retention assertions",checks);$finish;
 end
 initial begin #14000000;$fatal(1,"fullbars timeout");end
endmodule

// Public CEA VIC1 output, independent raster/stream counters, all image edges.
module tb_media_cea;
 reg clk=0;always #5 clk=~clk;
 reg rst_n=0,front=1,loading=0;
 reg [1:0] err=0;
 reg [23:0] pixel_rgb=0;
 reg pixel_valid=0;
 wire req,de,tick,hs,vs;
 wire [15:0] rgb,addr;
 wire [23:0] full;
 integer reads=0,requests=0,frames=0,pixels=0,cycles=0,last_tick=0;
 integer hs_low=0,vs_low=0,last_hs=0,lines=0,hs_pulses=0,vs_pulses=0;
 reg checking=0,hs_prev=1,vs_prev=1,tick_prev=0;
 function [23:0] pattern;
  input integer n;
  begin pattern={8'(n*37+n/640+17),8'(n*73+19),8'(n*11+(n/640)*17+3)};end
 endfunction
 rpg_video #(.VIDEO_MODE(1)) dut(.clk(clk),.rst_n(rst_n),.we(1'b0),.waddr(11'd0),.wdata(17'd0),
  .anim_on(1'b0),.anim_frame(3'd0),.mon_on(1'b0),.mon_id(5'd0),.mon_fade(4'd8),
  .bars(64'd0),.gal_on(1'b1),.gal_img(2'd0),.gal_fade(4'd8),.tf_valid(1'b0),
  .tf_err(err),.diag(8'd0),.diag2(8'd0),.dfill(1'b0),.tf_rdata(4'd0),.tf_raddr(addr),
  .hs(hs),.vs(vs),.de(de),.rgb(rgb),.rgb_full(full),.frame_tick(tick),
  .media_mode(2'd0),.media_auto(1'b1),.media_settings(1'b0),.media_loading(loading),
  .media_osd(1'b0),.media_index(6'd0),.media_count(6'd2),.media_name("FRAME001"),
  .media_brightness(4'd4),.media_contrast(2'd1),.media_view(2'd2),.media_visual(1'b0),
  .fb_front_valid(front),.fb_pixel_valid(pixel_valid),.fb_pixel_rgb(pixel_rgb),.fb_pixel_req(req));
 always @(posedge clk)begin
  if(!rst_n)begin pixel_valid<=0;pixel_rgb<=0;end
  else begin
   pixel_valid<=req;pixel_rgb<=pattern(reads);
   if(req)begin reads=reads+1;requests=requests+1;end
  end
 end
 always @(negedge clk)if(rst_n)begin
  cycles=cycles+1;
  if(checking)begin
   if(tick && tick_prev)$fatal(1,"CEA tick longer than one clock");
   if(!hs)hs_low=hs_low+1;
   if(!vs)vs_low=vs_low+1;
   if(!hs && hs_prev)begin
    if(last_hs!=0 && cycles-last_hs!=800)$fatal(1,"CEA horizontal total");
    last_hs=cycles;lines=lines+1;
   end
   if(hs && !hs_prev)begin
    if(hs_low!=96)$fatal(1,"CEA negative HS width %0d",hs_low);
    hs_low=0;hs_pulses=hs_pulses+1;
   end
   if(vs && !vs_prev)begin
    if(vs_low!=1600)$fatal(1,"CEA negative VS width %0d",vs_low);
    vs_low=0;vs_pulses=vs_pulses+1;
   end
   if(de)begin
    if(full!==pattern(pixels))$fatal(1,"CEA RGB edge/sequence pixel=%0d row=%0d col=%0d got=%h expected=%h",pixels,pixels/640,pixels%640,full,pattern(pixels));
    if(rgb!=={full[23:19],full[15:10],full[7:3]})$fatal(1,"CEA RGB565 projection");
    pixels=pixels+1;
   end else if(full!==0)$fatal(1,"CEA blank RGB");
  end
  hs_prev=hs;vs_prev=vs;tick_prev=tick;
 end
 always @(posedge tick)if(rst_n)begin
  if(de)$fatal(1,"CEA tick overlaps active video");
  frames=frames+1;
  if(frames==1)begin checking=1;reads=0;requests=0;pixels=0;last_tick=cycles;end
  else begin
   if(cycles-last_tick!=800*525)$fatal(1,"CEA frame total %0d",cycles-last_tick);
   if(requests!=307200 || pixels!=307200)$fatal(1,"CEA frame requests=%0d activepixels=%0d",requests,pixels);
   if(lines!=525 || hs_pulses!=525 || vs_pulses!=1)$fatal(1,"CEA sync pulse counts %0d/%0d/%0d",lines,hs_pulses,vs_pulses);
   $display("PASS media_cea: 800x525 negativeHS96/VS2,307200 requests+RGBpixels inclfirst/last andall640columns");$finish;
  end
 end
 initial begin repeat(4)@(negedge clk);rst_n=1;end
 initial begin #14000000;$fatal(1,"CEA timeout");end
endmodule
