`timescale 1ns/1ps
// Independent audit model, derived from EM638325 Industrial Rev3.2:
// p8 Fig5 CL3; p16 Fig17 STOP T4 -> last D3 T6, idle T7;
// p16 Fig18 WRITE immediate, STOP takes no data; p8 read DQM latency 2.
// Source tokens enter a three-register CAS pipeline. STOP suppresses future
// source tokens; existing tokens drain. No read_start/read_end arithmetic.
module EG_PHY_SDRAM_2M_32 #(parameter real T_AC_NS=5.4)(
 input clk,ras_n,cas_n,we_n,input [10:0] addr,input [1:0] ba,
 inout [31:0] dq,input cs_n,dm0,dm1,dm2,dm3,cke
);
 reg [31:0] mem [0:2097151];
 reg [10:0] rows [0:3];
 reg [3:0] opened=0;
 reg source_read=0,source_write=0;
 reg [1:0] source_bank;
 reg [7:0] source_col;
 reg [2:0] valid_pipe=0;
 reg [31:0] data_pipe[0:2];
 reg [3:0] dqm_p0=15,dqm_p1=15;
 wire [3:0] mask={dm3,dm2,dm1,dm0};
 reg [31:0] output_data;
 reg [3:0] output_en=0;
 genvar g;
 generate for(g=0;g<4;g=g+1)begin:bytes_out
  assign dq[8*g+:8]=output_en[g] ? output_data[8*g+:8] : 8'bz;
 end endgenerate
 integer cycles=0,last_refresh=0,max_refresh_gap=0;
 integer k,b,index,read_tokens=0,write_tokens=0,read_stops=0,write_stops=0;
 realtime activated[0:3],precharged[0:3],written[0:3];
 realtime last_ref_time=-100000,last_mrs=-100000;
 initial for(k=0;k<4;k=k+1)begin
  activated[k]=-100000;precharged[k]=-100000;written[k]=-100000;
 end
 always @(posedge clk)begin
  cycles=cycles+1;
  if(cke)begin
   // Output uses the old CAS pipeline and DQM from exactly two edges ago.
   output_data<=#(T_AC_NS) data_pipe[2];
   output_en<=#(T_AC_NS) (valid_pipe[2] ? ~dqm_p1 : 4'b0000);
   dqm_p1=dqm_p0;dqm_p0=mask;
   valid_pipe[2]=valid_pipe[1];data_pipe[2]=data_pipe[1];
   valid_pipe[1]=valid_pipe[0];data_pipe[1]=data_pipe[0];
   valid_pipe[0]=0;
   if(!cs_n)case({ras_n,cas_n,we_n})
    3'b011:begin
     if(opened[ba])$fatal(1,"AUDIT ACT bank already open");
     if($realtime-precharged[ba]<21 || $realtime-last_ref_time<63 || $realtime-last_mrs<40)
      $fatal(1,"AUDIT ACT timing");
     opened[ba]=1;rows[ba]=addr;activated[ba]=$realtime;
    end
    3'b010:begin
     if(source_write)$fatal(1,"AUDIT PRE during active WRITE");
     for(b=0;b<4;b=b+1)if(addr[10] || ba==b)begin
      if(opened[b] && $realtime-activated[b]<42)$fatal(1,"AUDIT tRAS");
      if($realtime-written[b]<40)$fatal(1,"AUDIT tWR");
      opened[b]=0;precharged[b]=$realtime;
     end
     // PRE uses the same read interruption latency as Fig10 (CL3).
     source_read=0;
    end
    3'b001:begin
     if(opened!=0 || $realtime-last_ref_time<63)$fatal(1,"AUDIT REF timing");
     for(b=0;b<4;b=b+1)if($realtime-precharged[b]<21)$fatal(1,"AUDIT REF tRP");
     if(last_refresh!=0 && cycles-last_refresh>max_refresh_gap)max_refresh_gap=cycles-last_refresh;
     last_refresh=cycles;last_ref_time=$realtime;
    end
    3'b000:begin
     if(addr!=11'h037 || ba!=0 || opened!=0)$fatal(1,"AUDIT MRS expected CAS3 full-page sequential");
     if($realtime-last_ref_time<63)$fatal(1,"AUDIT MRS tRFC");
     last_mrs=$realtime;
    end
    3'b101,3'b100:begin
     if(!opened[ba] || $realtime-activated[ba]<21)$fatal(1,"AUDIT column tRCD");
     if(source_read || source_write)$fatal(1,"AUDIT overlapping bursts");
     if(addr[10])$fatal(1,"AUDIT auto-precharge unexpected");
     source_bank=ba;source_col=addr[7:0];
     source_read=we_n;source_write=!we_n;
    end
    3'b110:begin
     if(source_read)read_stops=read_stops+1;
     if(source_write)write_stops=write_stops+1;
     if(!source_read && !source_write)$fatal(1,"AUDIT STOP outside burst");
     source_read=0;source_write=0;
    end
    default:begin end
   endcase
   if(source_read)begin
    index={source_bank,rows[source_bank],source_col};
    valid_pipe[0]=1;data_pipe[0]=mem[index];
    source_col=source_col+1'b1;read_tokens=read_tokens+1;
   end
   if(source_write)begin
    index={source_bank,rows[source_bank],source_col};
    for(b=0;b<4;b=b+1)if(!mask[b])begin
     if((^dq[b*8+:8])===1'bx)$fatal(1,"AUDIT unknown/contended write byte");
     mem[index][8*b+:8]=dq[8*b+:8];
    end
    written[source_bank]=$realtime;
    source_col=source_col+1'b1;write_tokens=write_tokens+1;
   end
  end else begin
   output_en<=#(T_AC_NS)0;valid_pipe=0;dqm_p0=mask;dqm_p1=mask;
  end
 end
endmodule
