`timescale 1ns/1ps
// Original 25.2MHz/32kHz source; accelerate only the public BGM BPM parameter.
module tb_music_effects;
 reg clk=0;always #19.84127 clk=~clk;
 reg rst_n=0;wire[7:0]dac[0:2];wire[6:0]n0[0:2],n1[0:2],n2[0:2];
 genvar g;
 generate for(g=0;g<3;g=g+1)begin:tracks
  sound #(.CLK_HZ(25200000),.BPM(25200)) actual(.clk(clk),.rst_n(rst_n),.sfx_id(4'd0),.sfx_trig(1'b0),.chime_step(24'd0),.chime_len(16'd0),.chime_trig(1'b0),.mus_on(1'b1),.mus_sel(g),.dac(dac[g]),.note0(n0[g]),.note1(n1[g]),.note2(n2[g]),.lev0(),.lev1(),.lev2());
 end endgenerate
 reg[3:0]sfx_id=0;reg sfx_trig=0;reg[5:0]index=0;reg ready=0;
 wire chime_trig;wire[23:0]chime_step;wire[15:0]chime_len;wire[7:0]mixed;
 img_chime #(.CLK_HZ(25200000)) notification(.clk(clk),.rst_n(rst_n),.index(index),.count(6'd25),.ready(ready),.trig(chime_trig),.step(chime_step),.len(chime_len));
 sound #(.CLK_HZ(25200000),.BPM(25200)) effect(.clk(clk),.rst_n(rst_n),.sfx_id(sfx_id),.sfx_trig(sfx_trig),.chime_step(chime_step),.chime_len(chime_len),.chime_trig(chime_trig),.mus_on(1'b1),.mus_sel(2'd0),.dac(mixed),.note0(),.note1(),.note2(),.lev0(),.lev1(),.lev2());
 integer i,t,cycles=0,samples=0,event_differences=0,chime_events=0;
 integer lo[0:2],hi[0:2],notes[0:2];reg[20:0]previous_notes[0:2];reg[31:0]hash[0:2];reg[23:0]first_chime=0;reg[23:0]second_chime=0;
 always @(posedge clk)if(rst_n)begin
  cycles=cycles+1;
  if(chime_trig)begin
   chime_events=chime_events+1;
   if(chime_events==1)first_chime=chime_step;
   if(chime_events==2)second_chime=chime_step;
  end
  if(cycles%787==0)begin
   samples=samples+1;
   for(t=0;t<3;t=t+1)begin
    if((^dac[t])===1'bx)$fatal(1,"unknown BGM PCM track%0d",t);
    if(dac[t]<lo[t])lo[t]=dac[t];if(dac[t]>hi[t])hi[t]=dac[t];
    hash[t]={hash[t][30:0],hash[t][31]}^{24'd0,dac[t]};
    if({n2[t],n1[t],n0[t]}!=previous_notes[t])notes[t]=notes[t]+1;
    previous_notes[t]={n2[t],n1[t],n0[t]};
   end
   if(mixed!==dac[0])event_differences=event_differences+1;
  end
 end
 task pulse_effect;input[3:0]id;begin
  @(negedge clk);sfx_id=id;sfx_trig=1;@(negedge clk);sfx_trig=0;
 end endtask
 initial begin
  for(i=0;i<3;i=i+1)begin lo[i]=255;hi[i]=0;notes[i]=0;previous_notes[i]=0;hash[i]=0;end
  #1;rst_n=1;#1;rst_n=0;repeat(4)@(negedge clk);rst_n=1;
  repeat(300000)@(negedge clk);
  for(i=0;i<3;i=i+1)if(hi[i]-lo[i]<8 || notes[i]<3)$fatal(1,"BGM not changing notes track%0d range%0d notechanges%0d",i,hi[i]-lo[i],notes[i]);
  if(hash[0]==hash[1] || hash[0]==hash[2] || hash[1]==hash[2])$fatal(1,"three actual ROM tracks indistinguishable");
  if(event_differences!=0)$fatal(1,"baseline effects instance differs before event");
  pulse_effect(1);repeat(1000000)@(negedge clk);
  if(event_differences<20)$fatal(1,"RPG key SFX never entered mix");
  repeat(2500)begin @(negedge clk);if(mixed!==dac[0])$fatal(1,"finite key SFX did not return to BGM");end
  event_differences=0;pulse_effect(3);repeat(1100000)@(negedge clk);
  if(event_differences<20)$fatal(1,"RPG kill SFX never entered mix");
  repeat(2500)begin @(negedge clk);if(mixed!==dac[0])$fatal(1,"finite kill SFX did not return to BGM");end
  event_differences=0;index=3;ready=1;repeat(4100000)@(negedge clk);
  if(chime_events!=2 || first_chime==0 || second_chime!=first_chime+(first_chime>>1))$fatal(1,"picture chime did not produce finite two-note fifth");
  if(event_differences<20)$fatal(1,"picture chime absent from PCM");
  repeat(2500)begin @(negedge clk);if(mixed!==dac[0])$fatal(1,"finite picture chime did not return to BGM");end
  index=5;repeat(210000)@(negedge clk);if(chime_events!=3 || chime_step==first_chime)$fatal(1,"different picture lacks distinct chime pitch");
  $display("PASS music_effects original3ROMtracks notechanges=%0d/%0d/%0d samples=%0d RPGkey+kill+picturetwo-note/return distinct-picture",notes[0],notes[1],notes[2],samples);$finish;
 end
 initial begin #350000000;$fatal(1,"music effects host-model timeout");end
endmodule
