`timescale 1ns/1ps
module tb_hdmi_audio;
reg clk=0; always #12.5 clk=~clk;
reg rst_n=0;
reg [10:0] x=0; reg [9:0] y=0;
wire hs=x>=840 && x<968;
wire vs=y>=601 && y<605;
wire de=x<800 && y<600;
wire [23:0] rgb={x[7:0],y[7:0],(x[7:0]^y[7:0])};
wire [9:0] t0,t1,t2;
wire tick,overflow; wire [2:0] mode;
wire oh,ov,od; wire [23:0] orgb;
hdmi_audio_encoder dut(.clk_pix(clk),.rst_n(rst_n),.rgb(rgb),.hs(hs),.vs(vs),.de(de),.mute(1'b0),
 .tmds0(t0),.tmds1(t1),.tmds2(t2),.sample_tick(tick),.overflow(overflow),
 .mode_out(mode),.hs_out(oh),.vs_out(ov),.de_out(od),.rgb_out(orgb));
integer f,cycle=0,ticks=0;
reg [2:0] pmode=0;
reg ph=0,pv=0,pd=0;
reg [9:0] pt1=0,pt2=0;
initial begin
 f=$fopen("sim/hdmi_audio/trace.txt","w");
 repeat(4) @(negedge clk); rst_n=1;
end
always @(posedge clk) if(rst_n) begin
 if(tick) begin $fdisplay(f,"S %0d",cycle); ticks=ticks+1; end
 if(x==1055) begin x<=0; y<=y==627 ? 0:y+1; end else x<=x+1;
 #1;
 if(overflow) $fatal(1,"Audio FIFO overflow");
 if(mode==3 || mode!=pmode || oh!=ph || ov!=pv || od!=pd || (mode==0 && (t1!=pt1 || t2!=pt2)) || (mode==1 && cycle<1800))
  $fdisplay(f,"P %0d %0d %0d %0d %0d %06x %03x %03x %03x",cycle,mode,oh,ov,od,orgb,t0,t1,t2);
 pmode=mode; ph=oh; pv=ov; pd=od; pt1=t1; pt2=t2;
 cycle=cycle+1;
 if(cycle==1326350) begin
  $display("PASS simulation cycles=%0d ticks=%0d",cycle,ticks);
  $fclose(f); $finish;
 end
end
endmodule
