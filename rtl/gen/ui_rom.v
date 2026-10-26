//=============================================================================
// ui_rom.v —— 由 tools/build_rom.py 自动生成, 不要手改
//
// 四个 ROM 用 $readmemh 初始化, 综合前请把 rtl/gen 目录加入 TD 的
// 文件搜索路径(或把 hex 拷到工程根目录并改下面的路径)。
//
// 指令格式(32bit): op[31:28] y[27:23] x[22:17] arg[16:0]
//   0 END  1 CLEAR(bg)  2 COLOR(fg,bg)  3 TEXT(arg=str_addr)
//   4 NUM(arg[7:0]=src, arg[11:8]=位数)  5 ART(arg=精灵号)
//   6 BAR(arg[7:0]=cur, arg[15:8]=max, 宽固定 12)  7 ENAME  8 ANAME
//   9 MSG  10 FRAME(arg[5:0]=w, arg[12:8]=h)
//=============================================================================
`timescale 1ns/1ps

module font_rom (
    input  wire        clk,
    input  wire [8:0]  glyph,
    input  wire [3:0]  row,
    output reg  [15:0] data
);
    reg [15:0] mem [0:8191];
    initial $readmemh("rtl/gen/font.hex", mem);
    always @(posedge clk) data <= mem[{glyph, row}];
endmodule

module cmd_rom (
    input  wire        clk,
    input  wire [9:0]  addr,
    output reg  [31:0] data
);
    reg [31:0] mem [0:1023];
    initial $readmemh("rtl/gen/cmd.hex", mem);
    always @(posedge clk) data <= mem[addr];
endmodule

module str_rom (
    input  wire       clk,
    input  wire [10:0] addr,
    output reg  [15:0] data
);
    reg [15:0] mem [0:2047];
    initial $readmemh("rtl/gen/str.hex", mem);
    always @(posedge clk) data <= mem[addr];
endmodule

module art_rom (
    input  wire        clk,
    input  wire [11:0] addr,
    output reg  [7:0]  data
);
    reg [7:0] mem [0:4095];
    initial $readmemh("rtl/gen/art.hex", mem);
    always @(posedge clk) data <= mem[addr];
endmodule

//-----------------------------------------------------------------------------
// 数据表(直接综合成查找表)
//-----------------------------------------------------------------------------
module rpg_tables (
    input  wire [4:0]  ename_id,
    input  wire [2:0]  area_id,
    input  wire [4:0]  stat_id,
    input  wire        sel,          // 0=名字 1=数值
    output reg  [62:0] ename,
    output reg  [53:0] area_name,
    output reg  [54:0] adesc,
    output reg  [63:0] es
);
    always @(*) begin
        case (ename_id)
      5'd0: ename = 63'h0000000000AC5429;
      5'd1: ename = 63'h0000000000005A2C;
      5'd2: ename = 63'h0000000000005E2E;
      5'd3: ename = 63'h0000000000006230;
      5'd4: ename = 63'h0000000190AC5429;
      5'd5: ename = 63'h0000000000006833;
      5'd6: ename = 63'h0000000000006C35;
      5'd7: ename = 63'h0000000000007037;
      5'd8: ename = 63'h0000000000007439;
      5'd9: ename = 63'h000003F1F0F4783B;
      5'd10: ename = 63'h0000000000008240;
      5'd11: ename = 63'h0000000001108642;
      5'd12: ename = 63'h00000002411C8C45;
      5'd13: ename = 63'h00000001C12C9449;
      5'd14: ename = 63'h0000000209309245;
      5'd15: ename = 63'h00000000013C9C4D;
      5'd16: ename = 63'h0000000291448450;
      5'd17: ename = 63'h000000000150A64D;
      5'd18: ename = 63'h000000000158AA33;
      5'd19: ename = 63'h0000000191048450;
      5'd20: ename = 63'h00000002D164B057;
      5'd21: ename = 63'h000000000174B85B;
      5'd22: ename = 63'h000000000000BE5E;
      5'd23: ename = 63'h000000000000C047;
      5'd24: ename = 63'h00000003218CC461;
        default: ename = 63'd0;
        endcase
    end

    always @(*) begin
        case (area_id)
      4'd0: area_name = 54'h000003419CCC65;
      4'd1: area_name = 54'h000001E0ECD469;
      4'd2: area_name = 54'h0000024914D86B;
      4'd3: area_name = 54'h00000001B8DA4D;
      4'd4: area_name = 54'h00000391C4E06F;
        default: area_name = 54'd0;
        endcase
    end

    always @(*) begin
        case (area_id)
      3'd0: adesc = 11'd621;
      3'd1: adesc = 11'd630;
      3'd2: adesc = 11'd639;
      3'd3: adesc = 11'd648;
      3'd4: adesc = 11'd657;
        default: adesc = 55'd0;
        endcase
    end

    always @(*) begin
        case (stat_id)
      5'd0: es = 64'h0000007024082024;
      5'd1: es = 64'h0041006020042C1E;
      5'd2: es = 64'h008F00501C04281C;
      5'd3: es = 64'h00D0006020003018;
      5'd4: es = 64'h012A05A1181C3087;
      5'd5: es = 64'h014200D048103C42;
      5'd6: es = 64'h0183010058203456;
      5'd7: es = 64'h01C40130680C503A;
      5'd8: es = 64'h021101206428445C;
      5'd9: es = 64'h026B0AA2082C50FA;
      5'd10: es = 64'h028501B088344484;
      5'd11: es = 64'h02D301D09020606C;
      5'd12: es = 64'h031201F098285878;
      5'd13: es = 64'h035401C088186860;
      5'd14: es = 64'h03AC1183984471A4;
      5'd15: es = 64'h03C60260C03064D4;
      5'd16: es = 64'h040702E0E8505D18;
      5'd17: es = 64'h045502C0E0247CC4;
      5'd18: es = 64'h04960290D01C88B0;
      5'd19: es = 64'h04ED1C26405C9280;
      5'd20: es = 64'h050803E1284C7D7C;
      5'd21: es = 64'h054904614830A140;
      5'd22: es = 64'h05970441403C915E;
      5'd23: es = 64'h05D804213828AD2C;
      5'd24: es = 64'h062E4B0E1060A348;
        default: es = 64'd0;
        endcase
    end
endmodule

//-----------------------------------------------------------------------------
// 区域 -> 怪物索引
//-----------------------------------------------------------------------------
module rpg_area (
    input  wire [2:0]  area,
    output reg  [4:0]  mob0,
    output reg  [4:0]  mob1,
    output reg  [4:0]  mob2,
    output reg  [4:0]  mob3,
    output reg  [4:0]  boss
);
    reg [24:0] am;
    always @(*) begin
        case (area)
      3'd0: am = 25'h0418820;
      3'd1: am = 25'h0941CC5;
      3'd2: am = 25'h0E6B16A;
      3'd3: am = 25'h139460F;
      3'd4: am = 25'h18BDAB4;
        default: am = 25'd0;
        endcase
        mob0 = am[4:0];
        mob1 = am[9:5];
        mob2 = am[14:10];
        mob3 = am[19:15];
        boss = am[24:20];
    end
endmodule

//-----------------------------------------------------------------------------
// 语句表地址
//-----------------------------------------------------------------------------
module rpg_screens (
    input  wire [3:0]  scene,
    output reg  [9:0]  addr
);
    always @(*) begin
        case (scene)
            4'd0: addr = 10'd0;   // title
            4'd1: addr = 10'd20;   // class
            4'd2: addr = 10'd72;   // map
            4'd3: addr = 10'd174;   // battle
            4'd4: addr = 10'd228;   // shop
            4'd5: addr = 10'd366;   // dead
            4'd6: addr = 10'd378;   // win
            4'd7: addr = 10'd404;   // pic
            4'd8: addr = 10'd302;   // shop2
            default: addr = 10'd0;
        endcase
    end
endmodule
