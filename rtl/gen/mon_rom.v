//=============================================================================
// mon_rom.v —— 怪物立绘（由 tools/make_monsters.py 生成，不要手改）
//
//   25 张 x 48x48，4bpp（每字节 2 像素，高半字节在前）
//   像素 28800 字节 = 225 Kbit；调色板 25 x 16 色
//   显示时 3 倍放大 -> 144x144 像素（正好 9x9 个字符格）
//=============================================================================
`timescale 1ns/1ps
module mon_rom (
    input  wire        clk,
    input  wire [14:0] addr,      // 0 .. 28799
    output reg  [7:0]  data,
    input  wire [9:0]  paddr,     // 0 .. 399  (编号*16 + 色号)
    output reg  [15:0] pal
);
    reg [7:0]  mem  [0:28799];
    reg [15:0] pmem [0:399];

    initial $readmemh("rtl/gen/mon.hex", mem);
    initial $readmemh("rtl/gen/monpal.hex", pmem);

    always @(posedge clk) data <= mem[addr];
    always @(posedge clk) pal  <= pmem[paddr];

endmodule
