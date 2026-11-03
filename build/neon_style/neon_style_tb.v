`timescale 1ns/1ps
module neon_style_tb;
reg [9:0] x; reg [8:0] y; reg [63:0] levels;
wire [15:0] color; wire outer;
reg [15:0] pixel, old_color;
integer f,ix,iy,k,pass,level_value,previous_luma,luma;
neon_style_core dut(x,y,levels,color,outer);
initial begin
    x=10'd19; y=9'd8; levels=0; #1;
    if(color==0) $fatal(1,"Mute body must remain filled");
    levels={8{8'd120}}; #1; old_color=color;
    levels={8{8'd255}}; #1;
    if(color!==old_color) $fatal(1,"Clamp above 120 differs");
    for(k=0;k<16;k=k+1) begin
        x=10'd19; y=k; previous_luma=-1;
        for(level_value=0;level_value<=255;level_value=level_value+1) begin
            levels={8{level_value[7:0]}}; #1;
            luma=color[15:11]+color[10:5]+color[4:0];
            if(luma<previous_luma) $fatal(1,"Brightness decreased");
            previous_luma=luma;
        end
    end
    for(pass=0;pass<3;pass=pass+1) begin
        case(pass)
            0: begin levels=0; f=$fopen("build/neon_style/rtl_mute.ppm","w"); end
            1: begin levels=64'h483e423c403a4430; f=$fopen("build/neon_style/rtl_music.ppm","w"); end
            2: begin levels={8{8'd120}}; f=$fopen("build/neon_style/rtl_peak.ppm","w"); end
        endcase
        $fwrite(f,"P3\n640 480\n255\n");
        for(iy=0;iy<480;iy=iy+1) begin
            for(ix=0;ix<640;ix=ix+1) begin
                x=ix; y=iy; #1;
                pixel=outer ? color : 16'h0842;
                $fwrite(f,"%0d %0d %0d\n",{pixel[15:11],pixel[15:13]},
                    {pixel[10:5],pixel[10:9]},{pixel[4:0],pixel[4:2]});
            end
        end
        $fclose(f);
    end
    $display("PASS actual RTL style: filled mute, clamp120==255, monotonic levels at all depths, three 640x480 rasters");
    $finish;
end
endmodule
