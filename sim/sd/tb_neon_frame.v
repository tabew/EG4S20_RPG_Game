`timescale 1ns/1ps
// Public RGB pins and write port only; real font/monster/animation ROMs.
module tb_neon_frame;
`ifndef NEON_MODE
`define NEON_MODE 1
`endif
 localparam MODE=`NEON_MODE,W=(MODE==1)?640:800,H=(MODE==1)?480:600;
 reg clk=0;always #5 clk=~clk;
 reg rst_n=0,we=0,en=0,gal=0;reg[10:0]wa=0;reg[16:0]wd=0;reg[63:0]levels=0;
 wire hs,vs,de,tick,req,bhs,bvs,bde,btick,breq;wire[15:0]rgb,brgb,addr,baddr;wire[23:0]full,bfull;
`define PORTS .clk(clk),.rst_n(rst_n),.we(we),.waddr(wa),.wdata(wd), \
 .anim_on(1'b0),.anim_frame(3'd0),.mon_on(1'b1),.mon_id(5'd1),.mon_fade(4'd8), \
 .mon_rotation(2'd0),.mon_mirror(1'b0),.bars(64'd0), \
 .gal_on(gal),.gal_img(2'd0),.gal_fade(4'd8),.tf_valid(1'b1),.tf_err(2'd0), \
 .diag(8'd0),.diag2(8'd0),.dfill(1'b0),.tf_rdata(4'd0), \
 .media_mode(2'd2),.media_auto(1'b0),.media_settings(1'b0),.media_loading(1'b0), \
 .media_osd(1'b0),.media_index(6'd0),.media_count(6'd1),.media_name("NEONVIEW"), \
 .media_brightness(4'd4),.media_contrast(2'd1),.media_view(2'd0),.media_visual(1'b0), \
 .fb_front_valid(gal),.fb_pixel_valid(1'b1),.fb_pixel_rgb(24'h174b85)
 rpg_video #(.VIDEO_MODE(MODE)) dut(`PORTS,.hit_trig(1'b0),.hit_kind(2'd0),.spectrum_border_en(en),.spectrum_levels(levels),
 .hs(hs),.vs(vs),.de(de),.frame_tick(tick),.rgb(rgb),.rgb_full(full),.fb_pixel_req(req),.tf_raddr(addr));
 rpg_video_legacy #(.VIDEO_MODE(MODE)) baseline(`PORTS,
 .hs(bhs),.vs(bvs),.de(bde),.frame_tick(btick),.rgb(brgb),.rgb_full(bfull),.fb_pixel_req(breq),.tf_raddr(baddr));
`undef PORTS
 integer px=0,py=0,lx,ly,i,c,r,case_id=0,frame_pixels=0,total=0,inside=0,outside=0,changed=0,gridchecks=0,bodychecks=0;
 integer active=0,expect_base=0,compare_saved=0,capture=0,f=0,pidx,body_energy=0,min_energy=0,max_energy=0;
 reg[23:0] saved[0:W*H-1];reg[23:0]probe_a,probe_b;reg pa=0,pb=0;
 always @(negedge clk)if(rst_n)begin
  if({hs,vs,de,tick,req,addr}!=={bhs,bvs,bde,btick,breq,baddr})$fatal(1,"neon timing/request isolation MODE%0d",MODE);
  if(tick)begin px=0;py=0;end
  if(de)begin
   if(active)begin
    lx=(MODE==1)?px:px*4/5;ly=(MODE==1)?py:py*4/5;pidx=py*W+px;
    if(lx>=16 && lx<624 && ly>=16 && ly<464)begin
     inside=inside+1;
     if(rgb!==brgb || full!==bfull)$fatal(1,"interior changed case%0d x%0d y%0d",case_id,px,py);
    end else begin
     outside=outside+1;
     if(!expect_base)begin
      // A filled tile body must exist even in silence; no former bar cutouts.
      if(ly==6 && lx>32 && lx<608 && (lx%32)>4 && (lx%32)<27)begin
       if(full==24'd0)$fatal(1,"tile body cutout case%0d at%0d,%0d",case_id,lx,ly);
       bodychecks=bodychecks+1;body_energy=body_energy+full[23:16]+full[15:8]+full[7:0];
      end
      if(ly==6 && lx==32)begin probe_a=full;pa=1;end
      if(ly==6 && lx==40)begin probe_b=full;pb=1;end
     end
    end
    if(expect_base && (rgb!==brgb || full!==bfull))$fatal(1,"disabled/gallery/XZ not legacy");
    if(rgb!==brgb)changed=changed+1;
    if(compare_saved && full!==saved[pidx])$fatal(1,"static/clamp/frame-atomic mismatch case%0d x%0d y%0d",case_id,px,py);
    if(case_id==2)saved[pidx]=full;
    if(capture)$fwrite(f,"%c%c%c",full[23:16],full[15:8],full[7:0]);
    frame_pixels=frame_pixels+1;total=total+1;
   end
   if(px==W-1)begin px=0;py=py+1;end else px=px+1;
  end
 end
 task run_frame;
 input integer id;input enable;input[63:0]value;input gallery;input integer cmp;input integer snap;
 begin
  active=0;@(posedge tick);@(negedge clk);en=enable;levels=value;gal=gallery;
  @(posedge tick);@(negedge clk);case_id=id;frame_pixels=0;body_energy=0;pa=0;pb=0;
  expect_base=(enable!==1'b1)||gallery;compare_saved=cmp;capture=snap;
  if(snap)begin f=$fopen("sim/sd/out/neon_frame/frame.ppm","wb");$fwrite(f,"P6\n%0d %0d\n255\n",W,H);end
  active=1;
  if(id==4)begin wait(py==200 && px==100);@(negedge clk);levels=0;en=0;end
  @(posedge tick);@(negedge clk);active=0;if(snap)$fclose(f);
  if(frame_pixels!=W*H)$fatal(1,"incomplete frame%0d got%0d",id,frame_pixels);
  if(!expect_base && (!pa || !pb || probe_a===probe_b))$fatal(1,"tile separator/body distinction missing case%0d",id);
  if(id==1)min_energy=body_energy;if(id==2)begin max_energy=body_energy;if(max_energy<=min_energy)$fatal(1,"music brightness not increasing %0d/%0d",min_energy,max_energy);end
  $display("PASS neon_frame MODE%0d case%0d pixels%0d bodyenergy%0d",MODE,id,frame_pixels,body_energy);$fflush();
 end endtask
 initial begin
  repeat(3)@(negedge clk);rst_n=1;
  for(i=0;i<1200;i=i+1)begin
   @(negedge clk);we=1;wa=i;c=i%40;r=i/40;wd=17'd0;
   if(c==0||c==39||r==0||r==29)wd={4'd0,4'd5,9'd6};
   if((r==2||r==13||r==17||r==23)&&c>0&&c<39)wd={4'd0,4'd3,9'd6};
   if(r==18&&c>=5&&c<=21)wd={4'd5,4'd5,9'd1};
   if(r==21&&c>=5&&c<=21)wd={4'd11,4'd11,9'd1};
   // Decimal glyphs19..28 are part of the public generated-font contract.
   if(r==18&&c==24)wd={4'd0,4'd4,9'd20};
   if(r==18&&c==25)wd={4'd0,4'd4,9'd22};
   if(r==18&&c==26)wd={4'd0,4'd4,9'd19};
   if(r==21&&c==24)wd={4'd0,4'd4,9'd23};
   if(r==21&&c==25)wd={4'd0,4'd4,9'd19};
  end
  @(negedge clk);we=0;
  if($test$plusargs("preview_only"))begin
   run_frame(9,1'b1,64'h785a483c3024180c,0,0,1);
   $display("PASS neon_frame PREVIEW MODE%0d",MODE);$finish;
  end
  run_frame(1,1'b1,64'd0,0,0,0);
  run_frame(2,1'b1,64'h7878787878787878,0,0,0);
  run_frame(3,1'b1,64'hffffffffffffffff,0,1,0);
  if(MODE==1)begin
   run_frame(4,1'b1,64'h7878787878787878,0,1,0);
   run_frame(5,1'b0,64'h7878787878787878,0,0,0);
   run_frame(6,1'bz,64'h7878787878787878,0,0,0);
   run_frame(7,1'bx,64'h7878787878787878,0,0,0);
   run_frame(8,1'b1,64'h7878787878787878,1,0,0);
  end
  if(changed<10000 || bodychecks<100 || inside<100000)$fatal(1,"coverage too small");
  $display("PASS neon_frame COMPLETE MODE%0d pixels%0d interior%0d outer%0d changed%0d bodychecks%0d silenceEnergy%0d loudEnergy%0d",MODE,total,inside,outside,changed,bodychecks,min_energy,max_energy);$finish;
 end
 initial begin #220000000;$fatal(1,"neon timeout");end
endmodule
