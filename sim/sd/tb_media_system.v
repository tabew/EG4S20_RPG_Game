`timescale 1ns/1ps
// Public-interface integration: controller -> CDC -> real FAT32/BMP -> actual RAM.
module tb_media_system;
 reg pc=0,sc=0;always #7 pc=~pc;always #5 sc=~sc;
 reg rst=0;reg[3:0]keys=0,longs=0;reg frame_enable=1;reg[7:0]fc=0;
 wire frame_tick=frame_enable && fc==0;
 always@(posedge pc)if(!rst)fc<=0;else fc<=fc+1'b1;
 wire req,ready,sgo;wire[5:0]reqidx,sidx;
 wire cat,busy,valid,done;wire[1:0]error;wire[5:0]count,seq,shown;wire[63:0]name;
 wire pcat,pbusy,pvalid,pdone;wire[1:0]perror;wire[5:0]pcount,pseq,pshown;wire[63:0]pname;
 wire[1:0]mode,contrast,view;wire[3:0]bright,fade;wire auto_run,settings,osd,visual,mute,gal_on,block_keys,loading;
 media_ctrl #(.FPS(4),.SEQUENCE_FRAMES(3),.FADE_FRAMES(1),.LOCK_FRAMES(1)) control(
 .clk(pc),.rst_n(rst),.frame_tick(frame_tick),.keys(keys),.longs(longs),.cat_ready(pcat),.image_busy(pbusy),.image_valid(pvalid),.load_done(pdone),
 .image_error(perror),.file_count(pcount),.seq_count(pseq),.shown_index(pshown),.req_ready(ready),.load_req(req),.load_index(reqidx),
 .media_mode(mode),.media_auto(auto_run),.media_settings(settings),.media_osd(osd),.media_visual(visual),.media_mute(mute),
 .media_brightness(bright),.media_contrast(contrast),.media_view(view),.gal_fade(fade),.gal_on(gal_on),.gal_block(block_keys),.media_loading(loading));
 media_cdc bridge(.pclk(pc),.prst_n(rst),.sclk(sc),.srst_n(rst),.p_req(req),.p_index(reqidx),.p_req_ready(ready),.s_load_go(sgo),.s_load_index(sidx),
 .s_cat_ready(cat),.s_busy(busy),.s_valid(valid),.s_done(done),.s_error(error),.s_count(count),.s_seq_count(seq),.s_shown(shown),.s_name(name),
 .s_diag(8'd0),.s_panel(8'd0),.s_fill(1'b0),.p_diag(),.p_panel(),.p_fill(),
 .p_cat_ready(pcat),.p_busy(pbusy),.p_valid(pvalid),.p_done(pdone),.p_error(perror),.p_count(pcount),.p_seq_count(pseq),.p_shown(pshown),.p_name(pname));
 wire init_go,rd_go;reg init_done=0;wire[31:0]rd_addr;reg[7:0]dout=0;reg dvalid=0,blk_done=0;
 wire[15:0]wa;wire[3:0]wd;wire we;wire[1:0]diag;wire[7:0]dbg;
 sd_img loader(.clk(sc),.rst_n(rst),.init_go(init_go),.init_done(init_done),.init_err(1'b0),.rd_go(rd_go),.rd_addr(rd_addr),.dout(dout),.dvalid(dvalid),.blk_done(blk_done),
 .tw_addr(wa),.tw_data(wd),.tw_wren(we),.tf_valid(valid),.tf_err(error),.fdiag(diag),.dsel(3'd7),.dbg(dbg),.load_go(sgo),.load_index(sidx),
 .file_count(count),.seq_count(seq),.shown_index(shown),.shown_name(name),.cat_ready(cat),.busy(busy),.load_done(done),.src_width(),.src_height());
 reg[15:0]ra=0;wire[3:0]ramdata;
 tf_ram cache(.wclk(sc),.waddr(wa),.wren(we),.wdata(wd),.rclk(pc),.raddr(ra),.rdata(ramdata));
 reg[31:0]lbas[0:4095];reg[7:0]sectors[0:2097151];reg[3:0]expected[0:98303];
 reg[1023:0]lp,dp,ep;integer ns,k,slot,pos=0,active=0,phase=0;
 integer completions=0,requests=0,reads=0,images_checked=0;
 always@(posedge pc)if(rst)begin if(pdone)completions=completions+1;if(req)requests=requests+1;end
 always@(posedge sc)if(rst && we && pvalid && gal_on && !loading && fade!=0)$fatal(1,"visible cache write: transition/CDC black barrier failed");
 always@(negedge sc)begin
  dvalid=0;blk_done=0;
  if(rst)begin
   if(init_go)init_done=1;
   if(rd_go)begin
    if(active)$fatal(1,"overlapping read");slot=-1;
    for(k=0;k<ns;k=k+1)if(lbas[k]==rd_addr)slot=k;
    if(slot<0)$fatal(1,"unmapped LBA%0d",rd_addr);
    reads=reads+1;active=1;pos=0;phase=0;
   end else if(active)begin
    if(pos<512)begin phase=phase+1;if(phase%5!=0)begin dout=sectors[slot*512+pos];dvalid=1;pos=pos+1;end end
    else begin blk_done=1;active=0;end
   end
  end
 end
 task click;input[3:0]bits;begin @(negedge pc);keys=bits;@(negedge pc);keys=0;repeat(4)@(negedge pc);end endtask
 task long_key;input[3:0]bits;begin @(negedge pc);longs=bits;@(negedge pc);longs=0;repeat(4)@(negedge pc);end endtask
 task check_image;input integer number,wanted_slot,refnum;integer n,i;begin
  n=0;while(completions<number && n<1500000)begin@(negedge pc);n=n+1;end
  frame_enable=0;
  if(completions!=number || !pvalid || perror!=0 || pshown!=wanted_slot || pcount!=7 || pseq!=2)$fatal(1,"integration completion%0d shown%0d error%0d count%0d seq%0d",completions,pshown,perror,pcount,pseq);
  for(i=0;i<49152;i=i+1)begin
   @(negedge pc);ra=i;@(posedge pc);#1;
   if(ramdata!==expected[refnum*49152+i])$fatal(1,"integrated cached pixel%0d image%0d got%h expected%h",i,wanted_slot,ramdata,expected[refnum*49152+i]);
  end
  images_checked=images_checked+1;
  $display("CHECK media_system completion%0d shown%0d all49152pixels",completions,pshown);
 end endtask
 initial begin
  if(!$value$plusargs("NSECTORS=%d",ns))$fatal(1,"missing NSECTORS");
  if(!$value$plusargs("LBA=%s",lp)||!$value$plusargs("DATA=%s",dp)||!$value$plusargs("EXPECTED=%s",ep))$fatal(1,"missing input");
  $readmemh(lp,lbas,0,ns-1);$readmemh(dp,sectors,0,ns*512-1);$readmemh(ep,expected);
  repeat(5)@(negedge pc);rst=1;
  check_image(1,0,0);frame_enable=1;
  check_image(2,1,1);frame_enable=1;
  check_image(3,0,0);
  click(8);if(mode!=1||auto_run)$fatal(1,"gallery entry");
  frame_enable=1;repeat(6000)@(negedge pc);click(1);check_image(4,6,1);
  frame_enable=1;repeat(6000)@(negedge pc);click(2);check_image(5,0,0);
  click(8);if(mode!=2||gal_on)$fatal(1,"RPG not selectable");
  frame_enable=1;repeat(700)@(negedge pc);if(block_keys)$fatal(1,"game inputs never unlocked");
  long_key(8);if(mode!=0||!gal_on)$fatal(1,"return to player");
  check_image(6,0,0);
  $display("PASS media_system images=%0d pixels=%0d requests=%0d reads=%0d",images_checked,images_checked*49152,requests,reads);$finish;
 end
 initial begin #150000000;$fatal(1,"integration timeout");end
endmodule
