//=============================================================================
// mon_rom.v ?? ?????? tools/make_monsters.py ????????
//
//   25 ? x 48x48?4bpp???? 2 ??????????
//   ?? 28800 ?? = 225 Kbit???? 25 x 16 ?
//   ??? 3 ??? -> 144x144 ????? 9x9 ?????
//=============================================================================
`timescale 1ns/1ps
module mon_rom (
    input  wire        clk,
    input  wire [14:0] addr,      // 0 .. 28799
    output reg  [7:0]  data,
    input  wire [9:0]  paddr,     // 0 .. 399  (??*16 + ??)
    output reg  [15:0] pal
);
    reg [7:0]  mem  [0:28799];
    reg [15:0] pmem [0:399];

    initial $readmemh("C:/Users/Tab_E/Downloads/EG4S20_RPG_Game-main/rtl/gen/mon.hex", mem);
    initial $readmemh("C:/Users/Tab_E/Downloads/EG4S20_RPG_Game-main/rtl/gen/monpal.hex", pmem);

    always @(posedge clk) data <= mem[addr];
    always @(posedge clk) pal  <= pmem[paddr];

endmodule

