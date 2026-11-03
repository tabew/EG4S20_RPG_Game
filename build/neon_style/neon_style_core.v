`timescale 1ns/1ps
module neon_style_core(input [9:0] spectrum_x4,input [8:0] spectrum_y4,
input [63:0] spectrum_levels_frame,output [15:0] color,output outer);
    // Filled 32-pixel rainbow tiles, with one-pixel transverse light seams.
    // FFT groups end on tile boundaries; opposite edges mirror inward.
    // Static diagonal hue, three small gain multipliers, no divider or BRAM.
    wire spectrum_horizontal = (spectrum_y4<9'd16) || (spectrum_y4>=9'd464);
    wire spectrum_outer4 = (spectrum_x4<10'd16) || (spectrum_x4>=10'd624) ||
                           spectrum_horizontal;
    wire spectrum_edge4 = (spectrum_x4==0) || (spectrum_x4==639) ||
                          (spectrum_y4==0) || (spectrum_y4==479);
    wire [2:0] spectrum_band_x = (spectrum_x4<10'd96) ? 3'd0 :
        (spectrum_x4<10'd160) ? 3'd1 : (spectrum_x4<10'd256) ? 3'd2 :
        (spectrum_x4<10'd320) ? 3'd3 : (spectrum_x4<10'd416) ? 3'd4 :
        (spectrum_x4<10'd480) ? 3'd5 : (spectrum_x4<10'd576) ? 3'd6 : 3'd7;
    wire [2:0] spectrum_band_y = (spectrum_y4<9'd64) ? 3'd0 :
        (spectrum_y4<9'd128) ? 3'd1 : (spectrum_y4<9'd192) ? 3'd2 :
        (spectrum_y4<9'd256) ? 3'd3 : (spectrum_y4<9'd320) ? 3'd4 :
        (spectrum_y4<9'd384) ? 3'd5 : (spectrum_y4<9'd448) ? 3'd6 : 3'd7;
    wire [2:0] spectrum_band = spectrum_horizontal ? spectrum_band_x : spectrum_band_y;
    reg [7:0] spectrum_level;
    always @(*) begin
        case (spectrum_band)
            0: spectrum_level=spectrum_levels_frame[7:0];
            1: spectrum_level=spectrum_levels_frame[15:8];
            2: spectrum_level=spectrum_levels_frame[23:16];
            3: spectrum_level=spectrum_levels_frame[31:24];
            4: spectrum_level=spectrum_levels_frame[39:32];
            5: spectrum_level=spectrum_levels_frame[47:40];
            6: spectrum_level=spectrum_levels_frame[55:48];
            default: spectrum_level=spectrum_levels_frame[63:56];
        endcase
    end
    wire [7:0] spectrum_clamped = (spectrum_level>120) ? 8'd120 : spectrum_level;
    // Music's usual 40..72 levels visibly modulate gain 36..52 / 64.
    // Silence remains filled at 1/4 gain; high energy saturates at 63 / 64.
    wire [6:0] spectrum_gain_raw = 7'd16 + {1'b0,spectrum_clamped[6:1]};
    wire [5:0] spectrum_gain = (spectrum_gain_raw>7'd63) ? 6'd63 : spectrum_gain_raw[5:0];
    wire [1:0] spectrum_glow_width = spectrum_clamped[6:5];
    wire [9:0] spectrum_depth = spectrum_horizontal ?
        ((spectrum_y4<16) ? {1'b0,spectrum_y4} : 10'd479-{1'b0,spectrum_y4}) :
        ((spectrum_x4<16) ? spectrum_x4 : 10'd639-spectrum_x4);
    wire spectrum_grid = spectrum_horizontal ? (spectrum_x4[4:0]==5'd0) :
                                               (spectrum_y4[4:0]==5'd0);
    wire spectrum_glow = (spectrum_depth>=10'd15-{8'd0,spectrum_glow_width}) &&
                         (spectrum_depth<10'd15);
    // The low eight bits implement ((x >> 1) + (y >> 1)) modulo 256.
    wire [7:0] spectrum_hue = spectrum_x4[8:1] + spectrum_y4[8:1];
    function [15:0] spectrum_tile_rgb;
        input [7:0] hue;
        input [5:0] gain;
        input glow;
        reg [10:0] phase;
        reg [7:0] ramp,fall,r,g,b;
        reg [13:0] product_r,product_g,product_b;
        reg [8:0] glow_r,glow_g,glow_b;
        begin
            // Six continuous RGB-wheel segments, computed with shifts/adds.
            phase={hue,2'b00}+{1'b0,hue,1'b0};
            ramp=phase[7:0];
            fall=8'd255-ramp;
            case (phase[10:8])
                3'd0: begin r=8'd255; g=ramp;   b=8'd0;   end
                3'd1: begin r=fall;   g=8'd255; b=8'd0;   end
                3'd2: begin r=8'd0;   g=8'd255; b=ramp;   end
                3'd3: begin r=8'd0;   g=fall;   b=8'd255; end
                3'd4: begin r=ramp;   g=8'd0;   b=8'd255; end
                default: begin r=8'd255; g=8'd0; b=fall; end
            endcase
            // Slightly soften saturation to match the luminous tiled frame.
            r=(r>>1)+(r>>2)+8'd7;
            g=(g>>1)+(g>>2)+8'd15;
            b=(b>>1)+(b>>2)+8'd7;
            // Exactly one gain per pixel and three 8x6-bit multiplications.
            product_r=r*gain; product_g=g*gain; product_b=b*gain;
            r=product_r[13:6]; g=product_g[13:6]; b=product_b[13:6];
            // FFT energy spreads a soft white glint inward from the pink rim.
            glow_r={1'b0,r}+9'd255;
            glow_g={1'b0,g}+9'd255;
            glow_b={1'b0,b}+9'd255;
            if (glow) begin
                r=glow_r[8:1]; g=glow_g[8:1]; b=glow_b[8:1];
            end
            spectrum_tile_rgb={r[7:3],g[7:2],b[7:3]};
        end
    endfunction
    wire [15:0] spectrum_body_rgb = spectrum_tile_rgb(spectrum_hue,spectrum_gain,spectrum_glow);
    // Priority: outside bevel, continuous inner rim, fine grid, filled tile.
    wire [15:0] spectrum_rgb4 = spectrum_edge4 ? 16'h1063 :
        (spectrum_depth==10'd15) ? 16'hfdd9 :
        spectrum_grid ? 16'hd71d : spectrum_body_rgb;

assign color=spectrum_rgb4;
assign outer=spectrum_outer4;
endmodule
