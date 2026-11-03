`timescale 1ns/1ps
// Independent RGB oracle: FORWARD-transform every source pixel into a display
// image, then integer /3 lookup. Never use DUT coordinates/address/palette.
// Contract: a pixel sampled at P1 appears at P3, like rpg_video.de3.
module tb_mon_sprite_rgb;
    reg clk=0;
    always #5 clk=~clk;
    reg rst_n=0;
    reg [4:0] mon_id=0;
    reg [3:0] fade=8;
    reg [11:0] x=0,y=0;
    reg [1:0] rotation=0;
    reg mirror=0;
    wire in_win,valid;
    wire [15:0] rgb;
    mon_layer dut(.clk(clk),.rst_n(rst_n),.mon_id(mon_id),.fade(fade),
        .x(x),.y(y),.in_win(in_win),.rgb(rgb),.valid(valid),
        .jx(5'sd0),.jy(5'sd0)
`ifndef LEGACY
        ,.rotation(rotation),.mirror(mirror)
`endif
    );
    reg [7:0] source_bytes[0:28799];
    reg [15:0] source_palette[0:399];
    reg [15:0] display_image[0:2303];
    integer display_parity[0:2303];
    integer display_index[0:2303];
    integer color15_pixels=0;
    reg ev0=0,ev1=0,ev2=0;
    reg [15:0] ec0=0,ec1=0,ec2=0;
    integer ex0=0,ex1=0,ex2=0,ey0=0,ey1=0,ey2=0;
    integer cycles=0,pixels=0,outside=0,even_pixels=0,odd_pixels=0;
    integer black_pixels=0,nonblack_pixels=0,configs=0,errors=0;
    integer inside_now,lookup,addr_now;
    integer id,rot,mir,fi,xx,yy;
    integer fvalues[0:2];
    integer baseline=0,latency_only=0;

    function [15:0] faded;
        input [15:0] color;
        input integer level;
        integer red,green,blue;
        begin
            red=((color>>11)&31)*level/8;
            green=((color>>5)&63)*level/8;
            blue=(color&31)*level/8;
            faded=(red<<11)|(green<<5)|blue;
        end
    endfunction

    task build_display;
        input integer image_id,turns,flip,level;
        integer sx,sy,dx,dy,tmp,k,p,idx;
        reg [7:0] packed_byte;
        begin
            for(sy=0;sy<48;sy=sy+1) begin
                for(sx=0;sx<48;sx=sx+1) begin
                    p=sy*48+sx;
                    packed_byte=source_bytes[image_id*1152+p/2];
                    if(p%2==0) idx=packed_byte/16;
                    else idx=packed_byte%16;
                    dx=sx;dy=sy;
                    for(k=0;k<turns;k=k+1) begin
                        tmp=dx;dx=47-dy;dy=tmp;
                    end
                    if(flip) dx=47-dx;
                    display_image[dy*48+dx]=faded(source_palette[image_id*16+idx],level);
                    display_parity[dy*48+dx]=p%2;
                    display_index[dy*48+dx]=idx;
                end
            end
        end
    endtask

    // Blocking scoreboard shifts run before NBA; check after NBA settles.
    always @(posedge clk) begin
        if(!rst_n) begin
            ev0=0;ev1=0;ev2=0;
        end else begin
            cycles=cycles+1;
            inside_now=(x>=240 && x<384 && y>=48 && y<192);
            ev2=ev1;ev1=ev0;ev0=inside_now;
            ec2=ec1;ec1=ec0;
            ex2=ex1;ex1=ex0;ex0=x;
            ey2=ey1;ey1=ey0;ey0=y;
            if(inside_now) begin
                lookup=((y-48)/3)*48+(x-240)/3;
                ec0=display_image[lookup];
                pixels=pixels+1;
                if(display_index[lookup]==15) color15_pixels=color15_pixels+1;
                if(display_parity[lookup]) odd_pixels=odd_pixels+1;
                else even_pixels=even_pixels+1;
                if(ec0==0) black_pixels=black_pixels+1;
                else nonblack_pixels=nonblack_pixels+1;
            end else outside=outside+1;
`ifndef LEGACY
            addr_now=dut.maddr;
            if((^dut.maddr)===1'bx || addr_now>=28800 || addr_now<mon_id*1152 || addr_now>=(mon_id+1)*1152) begin
                $display("FAIL ROM address id=%0d x=%0d y=%0d addr=%0d",mon_id,x,y,addr_now);
                $fatal(1);
            end
`endif
            #1;
            if(in_win!==inside_now) begin
                $display("FAIL public in_win x=%0d y=%0d",x,y);$fatal(1);
            end
            if(valid!==ev2 || (ev2 && rgb!==ec2)) begin
                if(errors<12) $display("MISMATCH P3 id=%0d fade=%0d rot=%b mirror=%b x=%0d y=%0d valid=%b expected_valid=%b RGB=%h expected=%h",mon_id,fade,rotation,mirror,ex2,ey2,valid,ev2,rgb,ec2);
                errors=errors+1;
            end
        end
    end

    task pixel;
        input integer px,py;
        begin
            @(negedge clk);x=px;y=py;
            @(posedge clk);#2;
        end
    endtask
    task settle;
        integer n;
        begin for(n=0;n<40;n=n+1) pixel(0,0); end
    endtask
    task raster;
        begin
            // One-pixel border on all four sides and every scaled pixel.
            for(yy=47;yy<=192;yy=yy+1)
                for(xx=239;xx<=384;xx=xx+1) pixel(xx,yy);
            pixel(4095,4095);pixel(0,4095);pixel(4095,0);
            pixel(0,0);pixel(0,0);pixel(0,0);
            configs=configs+1;
        end
    endtask
    initial begin
        $readmemh("rtl/gen/mon.hex",source_bytes);
        $readmemh("rtl/gen/monpal.hex",source_palette);
        fvalues[0]=8;fvalues[1]=4;fvalues[2]=0;
        baseline=$test$plusargs("baseline");
        latency_only=$test$plusargs("latency_only");
        if($test$plusargs("palette_only")) begin
            mon_id=21;build_display(21,0,0,8);
        end else build_display(0,0,0,8);
        repeat(4) @(negedge clk);
        rst_n=1;
        if(baseline || latency_only) begin
            settle;raster;
        end else begin
            for(fi=0;fi<3;fi=fi+1) begin
                for(id=0;id<25;id=id+1) begin
                    for(rot=0;rot<4;rot=rot+1) begin
                        for(mir=0;mir<2;mir=mir+1) begin
                            @(negedge clk);mon_id=id;fade=fvalues[fi];rotation=rot;mirror=mir;
                            build_display(id,rot,mir,fvalues[fi]);
                            settle;raster;
                        end
                    end
                end
                $display("PROGRESS fade=%0d configs=%0d pixels=%0d errors=%0d",fvalues[fi],configs,pixels,errors);
            end
`ifndef LEGACY
            // Every 4-state rotation containing X/Z must select the whole
            // rotation default 0; only an exact mirror=1 enables mirroring.
            for(rot=0;rot<16;rot=rot+1) begin
                if(rot<4) rotation=2'b0x;
                else if(rot<8) rotation=2'bz1;
                else if(rot<12) rotation=2'b1z;
                else rotation=2'bx0;
                case(rot%4)
                    0:mirror=0;
                    1:mirror=1;
                    2:mirror=1'bx;
                    3:mirror=1'bz;
                endcase
                mon_id=24;fade=8;
                build_display(24,0,rot%4==1,8);
                settle;raster;
            end
            // Actual unconnected-port state, plus reset with a full pipeline.
            rotation=2'bzz;mirror=1'bz;mon_id=0;fade=8;
            build_display(0,0,0,8);settle;raster;
            @(negedge clk);rst_n=0;
            #1;if(valid!==0 || rgb!==0) $fatal(1,"asynchronous reset");
            repeat(3) @(negedge clk);
            rst_n=1;settle;raster;
`endif
        end
        $display("COUNTS configs=%0d cycles=%0d pixels=%0d outside=%0d even=%0d odd=%0d black=%0d nonblack=%0d color15=%0d errors=%0d",configs,cycles,pixels,outside,even_pixels,odd_pixels,black_pixels,nonblack_pixels,color15_pixels,errors);
        if(!baseline && !latency_only) begin
            if(configs!=618 || pixels!=12814848 || even_pixels!=6407424 || odd_pixels!=6407424 || color15_pixels!=3672)
                $fatal(1,"exhaustive coverage count incomplete");
        end
        if(baseline) begin
            if(errors==0) $fatal(1,"legacy bug was not reproduced");
            $display("PASS legacy regression demonstrated against independent P3 oracle");
        end else begin
            if(errors!=0) $fatal(1,"RGB oracle mismatches");
            $display("PASS monster RGB oracle and three-clock renderer contract");
        end
        $finish;
    end
endmodule
