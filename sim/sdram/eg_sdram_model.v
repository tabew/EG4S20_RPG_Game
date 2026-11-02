`timescale 1ns/1ps
// Simulation-only command-level SDR SDRAM model. Real storage, CAS3 latency,
// sequential full-page wrap, delayed burst termination, DQM byte writes,
// independently enforced startup/refresh and bank timing. Not a vendor model.
module EG_PHY_SDRAM_2M_32 #(parameter T_AC_NS=6) (
 input clk, ras_n, cas_n, we_n, input [10:0] addr,
 input [1:0] ba, inout [31:0] dq, input cs_n,
 input dm0,dm1,dm2,dm3,cke
);
 reg [31:0] mem[0:2097151];
 reg [10:0] row[0:3];
 reg [3:0] opened=0;
 integer activated[0:3],precharged[0:3],written[0:3];
 integer cycles=0, last_refresh=-1000, refs=0, pre_count=0;
 integer mrs_cycle=-1000, ref_count=0, read_count=0, write_count=0;
 integer max_refresh_gap=0, gap=0;
 reg mode_ready=0, writing=0, reading=0;
 integer read_start=0, read_end=2147483647;
 reg [1:0] burst_bank;
 reg [7:0] col;
 reg [31:0] output_data;
 reg output_enable=0;
 wire [3:0] mask={dm3,dm2,dm1,dm0};
 assign dq=output_enable ? output_data : 32'bz;
 integer k,index,b;
 realtime command_changed=0, data_changed=0;
 always @(ras_n or cas_n or we_n or addr or ba or cs_n or dm0 or dm1 or dm2 or dm3)
  command_changed=$realtime;
 always @(dq) data_changed=$realtime;
 initial begin
  for(k=0;k<4;k=k+1) begin activated[k]=-1000;precharged[k]=-1000;written[k]=-1000;end
 end
 always @(posedge cke) if($time<200000)$fatal(1,"CKE enabled before 200us startup");
 always @(posedge clk) begin
  cycles=cycles+1;
  if($time<200000 && ({dm3,dm2,dm1,dm0}!==4'b1111))
   $fatal(1,"DQM must remain high during power-up");
  if(cke) begin
   if($realtime-command_changed<2.0)$fatal(1,"command setup less than 2ns");
   if(mode_ready && cycles-last_refresh>390) $fatal(1,"SDRAM refresh deadline exceeded");
   if(!cs_n) begin
    case({ras_n,cas_n,we_n})
    3'b011: begin // ACTIVE
     if(!mode_ready) $fatal(1,"ACT before mode initialized");
     if(opened[ba]) $fatal(1,"ACT open bank");
     if(cycles-precharged[ba]<2) $fatal(1,"tRP violation");
     if(cycles-last_refresh<5) $fatal(1,"tRFC violation");
     if(cycles-mrs_cycle<2) $fatal(1,"tMRD violation");
     opened[ba]=1;row[ba]=addr;activated[ba]=cycles;
    end
    3'b010: begin // PRECHARGE
     if($time<200000) $fatal(1,"startup shorter than 200us");
     if(writing) $fatal(1,"PRE before WRITE terminated");
     for(b=0;b<4;b=b+1) if(addr[10] || b==ba) begin
      if(opened[b] && cycles-activated[b]<3) $fatal(1,"tRAS violation");
      if(cycles-written[b]<2) $fatal(1,"tWR violation");
      opened[b]=0;precharged[b]=cycles;
     end
     pre_count=pre_count+1;
    end
    3'b001: begin // AUTO REFRESH
     if(opened!=0) $fatal(1,"REF with open bank");
     for(b=0;b<4;b=b+1) if(cycles-precharged[b]<2) $fatal(1,"REF tRP violation");
     if(cycles-last_refresh<5) $fatal(1,"REF tRFC violation");
     if(pre_count==0) $fatal(1,"REF before PRE");
     if(mode_ready) begin
      gap=cycles-last_refresh;
      if(gap>max_refresh_gap)max_refresh_gap=gap;
     end
     last_refresh=cycles;refs=refs+1;ref_count=ref_count+1;
    end
    3'b000: begin // MODE REGISTER SET
     if(refs<8) $fatal(1,"fewer than eight startup refreshes");
     if(opened!=0 || cycles-last_refresh<5) $fatal(1,"MRS bank/tRFC violation");
     if(addr!=11'h037 || ba!=0) $fatal(1,"unsupported mode register %h bank %d",addr,ba);
     mode_ready=1;mrs_cycle=cycles;
    end
    3'b101,3'b100: begin // READ / WRITE
     if(!mode_ready || !opened[ba]) $fatal(1,"column command without ACT/MRS");
     if(cycles-activated[ba]<2) $fatal(1,"tRCD violation");
     if(addr[10]) $fatal(1,"model expects explicit PRE");
     if(reading || writing) $fatal(1,"new burst overlaps old burst");
     burst_bank=ba;col=addr[7:0];
     if(we_n) begin
      reading=1;read_start=cycles+3;read_end=2147483647;read_count=read_count+1;
     end else begin writing=1;write_count=write_count+1;end
    end
    3'b110: begin // BURST TERMINATE
     if(writing)writing=0;
     else if(reading)read_end=cycles+3;
     else $fatal(1,"BST without active burst");
    end
    default: begin end
    endcase
   end
   if(writing) begin
    if($realtime-data_changed<2.0)$fatal(1,"write data setup less than 2ns");
    index={burst_bank,row[burst_bank],col};
    for(b=0;b<4;b=b+1) if(!mask[b]) begin
     if((^dq[b*8+:8])===1'bx)$fatal(1,"unknown/contended write data");
     mem[index][b*8+:8]=dq[b*8+:8];
    end
    written[burst_bank]=cycles;col=col+1'b1;
   end
   if(reading && cycles>=read_end)reading=0;
   if(reading && cycles>=read_start) begin
    index={burst_bank,row[burst_bank],col};
    output_data<=#(T_AC_NS) mem[index];output_enable<=#(T_AC_NS) 1;
    col=col+1'b1;
   end else output_enable<=#(T_AC_NS) 0;
  end else begin
   output_enable<=#(T_AC_NS) 0;
  end
 end
endmodule
