`timescale 1ns/1ps
module tb_media_cancel_loader;
 reg clk=0;always #5 clk=~clk;
 reg rst=0,load=0,cancel=0,init_done=0,dvalid=0,blk_done=0;
 reg [5:0] index=1;reg [7:0] dout=0;
 wire init_go,rd_go,valid,busy,done,cancelled,cat,we,pixel,start;
 wire [31:0] rd_addr;wire [5:0] count,seq,shown;wire [63:0] name;
 wire [1:0] error;wire [7:0] dbg;
 sd_img dut(.clk(clk),.rst_n(rst),.init_go(init_go),.init_done(init_done),.init_err(1'b0),
 .rd_go(rd_go),.rd_addr(rd_addr),.dout(dout),.dvalid(dvalid),.blk_done(blk_done),
 .tw_wren(we),.tf_valid(valid),.tf_err(error),.dsel(3'd7),.dbg(dbg),
 .load_go(load),.cancel_go(cancel),.load_cancelled(cancelled),.load_index(index),
 .file_count(count),.seq_count(seq),.shown_index(shown),.shown_name(name),
 .cat_ready(cat),.busy(busy),.load_done(done),.fb_start(start),.fb_pixel_valid(pixel));
 reg [31:0] lbas[0:4095];reg [7:0] data[0:2097151];reg [1023:0] lp,dp;
 integer ns,k,slot,pos=0,crc=0,active=0,reads=0,completions=0,cancellations=0;
 integer n,before_reads,before_done,before_cancel;reg [63:0] old_name;
 always @(negedge clk) begin
 dvalid=0;blk_done=0;
 if(rst)begin
 if(init_go)init_done=1;
 if(rd_go)begin
 if(active)$fatal(1,"loader overlapped SD transactions");
 slot=-1;for(k=0;k<ns;k=k+1)if(lbas[k]==rd_addr)slot=k;
 if(slot<0)$fatal(1,"unmapped LBA %0d",rd_addr);
 reads=reads+1;active=1;pos=0;crc=0;
 end else if(active)begin
 if(pos<512)begin dout=data[slot*512+pos];dvalid=1;pos=pos+1;end
 else if(crc<7)crc=crc+1; // Model trailing CRC and SPI transaction release.
 else begin active=0;blk_done=1;end
 end end end
 always @(posedge clk)begin #1;
 if(rst && done)completions=completions+1;
 if(rst && cancelled)begin
 cancellations=cancellations+1;
 if(!done || busy || valid || error!=0 || !cat || shown!=0 || name!==old_name)
 $fatal(1,"cancel completion failed to retain catalog/front metadata");
 if(active)$fatal(1,"cancel acknowledged before sector data and CRC completed");
 end end
 task request_back;begin
 @(negedge clk);load=1;@(negedge clk);load=0;
 n=0;while(!busy && n<100)begin @(negedge clk);n=n+1;end
 if(!busy)$fatal(1,"cancelled loader no longer requestable");end endtask
 task cancel_now;begin
 before_reads=reads;before_done=completions;before_cancel=cancellations;
 cancel=1;@(negedge clk);cancel=0;
 n=0;while(completions==before_done && n<600)begin @(negedge clk);n=n+1;end
 if(completions!=before_done+1 || cancellations!=before_cancel+1)
 $fatal(1,"cancel did not complete within current sector (%0d cycles)",n);
 repeat(50)@(negedge clk);
 if(reads!=before_reads || completions!=before_done+1 || cancellations!=before_cancel+1)
 $fatal(1,"cancel issued next sector or duplicate completion");
 end endtask
 initial begin
 if(!$value$plusargs("NSECTORS=%d",ns) || !$value$plusargs("LBA=%s",lp) || !$value$plusargs("DATA=%s",dp))$fatal(1,"missing fixture");
 $readmemh(lp,lbas,0,ns-1);$readmemh(dp,data,0,ns*512-1);
 repeat(5)@(negedge clk);rst=1;
 n=0;while(completions<1 && n<1000000)begin @(negedge clk);n=n+1;end
 if(completions!=1 || !valid || shown!=0 || error || !cat || count!=7)$fatal(1,"initial real FAT/BMP load failed");
 old_name=name;
 // Cancel during catalog selection before an SD transaction starts.
 request_back;cancel_now;
 // Cancel in the header, before its acceptance at byte 53.
 request_back;wait(active && dbg==9 && pos==20);cancel_now;
 // Cancel in an ordinary file sector after the valid header.
 request_back;wait(active && dbg==9 && rd_addr>2054 && pos==130);cancel_now;
 // A file FAT lookup must also drain its entire SD sector.
 request_back;wait(active && dbg==11 && pos==40);cancel_now;
 // Cancellation on exactly the last block completion must beat successful metadata publication.
 request_back;wait(active && dbg==9 && rd_addr==2342 && pos==512);
 wait(blk_done);cancel_now;
 // Idle cancellation has no second completion; publication cancellation belongs to top.
 before_done=completions;@(negedge clk);cancel=1;@(negedge clk);cancel=0;
 repeat(30)@(negedge clk);if(completions!=before_done)$fatal(1,"idle cancellation generated spurious completion");
 // The catalog still supports a successful load after repeated cancellations.
 request_back;n=0;while(busy && n<1000000)begin @(negedge clk);n=n+1;end
 if(busy || !valid || error || shown!=1 || name==old_name)$fatal(1,"normal load after cancellation failed");
 $display("PASS media_cancel_loader selection/header/data/FAT/EOF/idle/reload, full sector plus CRC drained");$finish;
 end
 initial begin #50000000;$fatal(1,"loader cancellation timeout state%0d LBA%0d pos%0d",dbg,rd_addr,pos);end
endmodule
