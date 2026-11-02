`timescale 1ns/1ps
// Public-port PCM stimulus; no DUT state is read, aliased, or forced.
module tb_hdmi_pcm;
`ifdef PROFILE40
localparam HA=800,HT=1056,VA=600,VT=628,HS=840,HW=128,VS=601,VW=4,PH=40000000,VIC=0,POL=1;
`else
localparam HA=640,HT=800,VA=480,VT=525,HS=656,HW=96,VS=490,VW=2,PH=25200000,VIC=1,POL=0;
`endif
// Toggle just after capture 100 while its PCM is still queued for a packet.
localparam END_CYCLE=2*HT*VT+32, MUTE_ON=PH/480+1, MUTE_OFF=2*END_CYCLE/3+77;
reg clk=0; always #5 clk=~clk;
reg rst=0; integer x=0,y=0,c=0,j;
wire hs=POL ? (x>=HS && x<HS+HW) : !(x>=HS && x<HS+HW);
wire vs=POL ? (y>=VS && y<VS+VW) : !(y>=VS && y<VS+VW);
wire de=x<HA && y<VA;
wire [23:0] rgb={x[7:0],y[7:0],(x[7:0]^y[7:0])};
reg [5:0] delayed_de=0; reg [23:0] delayed_rgb[0:5];
wire mute=c>=MUTE_ON && c<MUTE_OFF;
integer source_acc=0,source_index=0;
wire [31:0] source_hz=(c>=END_CYCLE/2 && c<3*END_CYCLE/4) ? 22050:32000;
function signed [15:0] source_value;
 input integer index;
 integer dac;
 begin
  case(index)
   0: source_value=16'sd0;
   1: source_value=-16'sd32768;
   2: source_value=16'sd32767;
   3: source_value=-16'sd1;
   4: source_value=16'sd1;
   5: source_value=-16'sd7;
   6: source_value=16'sd256;
   7: source_value=-16'sd256;
   default: begin
    dac=((index*73)^(index>>2)^8'hb6)&255;
    source_value=(dac-128)*64;
   end
  endcase
 end
endfunction
reg signed [15:0] pcm=0;
wire [9:0] a,b,e,ra,rb,re;
wire tick,overflow,oh,ov,od,rtick,roverflow,rh,rv,rd;
wire [2:0] mode,rmode; wire [23:0] orgb,rrgb;
hdmi_audio_encoder #(.H_ACTIVE(HA),.H_TOTAL(HT),.PIXEL_HZ(PH),.VIDEO_ID(VIC),.PCM_INPUT_EN(1)) dut(
 .clk_pix(clk),.rst_n(rst),.rgb(delayed_rgb[5]),.hs(hs),.vs(vs),.de(delayed_de[5]),.mute(mute),.pcm_sample(pcm),
 .tmds0(a),.tmds1(b),.tmds2(e),.sample_tick(tick),.overflow(overflow),
 .mode_out(mode),.hs_out(oh),.vs_out(ov),.de_out(od),.rgb_out(orgb));
// Default diagnostic mode intentionally leaves pcm_sample unconnected.
hdmi_audio_encoder #(.H_ACTIVE(HA),.H_TOTAL(HT),.PIXEL_HZ(PH),.VIDEO_ID(VIC)) reference_tone(
 .clk_pix(clk),.rst_n(rst),.rgb(delayed_rgb[5]),.hs(hs),.vs(vs),.de(delayed_de[5]),.mute(mute),
 .tmds0(ra),.tmds1(rb),.tmds2(re),.sample_tick(rtick),.overflow(roverflow),
 .mode_out(rmode),.hs_out(rh),.vs_out(rv),.de_out(rd),.rgb_out(rrgb));
reg [2:0] pm=0; reg ph=0,pv=0,pd=0; reg [9:0] pb=0,pe=0;
initial begin
 for(j=0;j<6;j=j+1) delayed_rgb[j]=0;
 repeat(4) @(negedge clk); rst=1;
 $display("CONFIG %0d %0d %0d %0d",PH,END_CYCLE,MUTE_ON,MUTE_OFF);
end
always @(posedge clk) if(rst) begin
 // Expected PCM is captured before NBA source updates, just as by the DUT.
 if(tick) $display("S %0d %0d %0d",c,$signed(pcm),mute);
 if(source_acc+source_hz>=PH) begin
  source_acc<=source_acc+source_hz-PH;
  source_index<=source_index+1;
  pcm<=source_value(source_index+1);
 end else source_acc<=source_acc+source_hz;
 delayed_de<={delayed_de[4:0],de}; delayed_rgb[0]<=rgb;
 for(j=1;j<6;j=j+1) delayed_rgb[j]<=delayed_rgb[j-1];
 if(x==HT-1) begin x<=0; y<=y==VT-1?0:y+1; end else x<=x+1;
 #1;
 if(overflow || roverflow) $fatal(1,"audio FIFO overflow");
 if({tick,mode,oh,ov,od,orgb} !== {rtick,rmode,rh,rv,rd,rrgb}) $fatal(1,"PCM changed scan timing");
 if(mode!=3 && {a,b,e} !== {ra,rb,re}) $fatal(1,"PCM changed video/control symbols");
 if(mode==3 || mode!=pm || oh!=ph || ov!=pv || od!=pd ||
    (mode==0 && (b!=pb || e!=pe)) || c<HT*3)
  $display("P %0d %0d %0d %0d %0d %06x %03x %03x %03x",c,mode,oh,ov,od,orgb,a,b,e);
 pm=mode; ph=oh; pv=ov; pd=od; pb=b; pe=e;
 c=c+1;
 if(c==END_CYCLE) begin
  $display("PASS public PCM; overflow=0; every-cycle video/control and timing identical to diagnostic mode");
  $finish;
 end
end
endmodule
