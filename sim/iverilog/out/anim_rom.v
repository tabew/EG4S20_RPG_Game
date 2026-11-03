//=============================================================================
// anim_rom.v ?? ???????? tools/make_anim.py ????????
//
//   4 ? x 128x96?4bpp???? 2 ??????????
//   ?? 24576 ?? = 192 Kbit
//=============================================================================
`timescale 1ns/1ps
module anim_rom (
    input  wire        clk,
    input  wire [14:0] addr,      // 0 .. 24575
    output reg  [7:0]  data,
    input  wire [3:0]  pal_idx,
    output reg  [15:0] pal_rgb
);
    reg [7:0] mem [0:24575];

    initial $readmemh("C:/Users/Tab_E/Downloads/EG4S20_RPG_Game-main/rtl/gen/anim.hex", mem);

    always @(posedge clk) data <= mem[addr];

    // ????16 ??????????? BRAM?
    reg [15:0] pal_tbl [0:15];
    initial begin
        pal_tbl[0] = 16'h0000;
        pal_tbl[1] = 16'h0841;
        pal_tbl[2] = 16'h10A2;
        pal_tbl[3] = 16'h18E3;
        pal_tbl[4] = 16'h3186;
        pal_tbl[5] = 16'h4208;
        pal_tbl[6] = 16'h8000;
        pal_tbl[7] = 16'hC000;
        pal_tbl[8] = 16'hE800;
        pal_tbl[9] = 16'hFD20;
        pal_tbl[10] = 16'hFE60;
        pal_tbl[11] = 16'hFFE0;
        pal_tbl[12] = 16'hFFFF;
        pal_tbl[13] = 16'h7BEF;
        pal_tbl[14] = 16'h39E7;
        pal_tbl[15] = 16'h0220;
    end

    always @(posedge clk) pal_rgb <= pal_tbl[pal_idx];

endmodule

