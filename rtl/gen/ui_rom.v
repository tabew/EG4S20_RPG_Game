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
    input  wire [7:0]  glyph,
    input  wire [3:0]  row,
    output reg  [15:0] data
);
    reg [15:0] mem [0:4095];
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
    output reg  [7:0] data
);
    reg [7:0] mem [0:2047];
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
    input  wire [3:0]  ename_id,
    input  wire [2:0]  area_id,
    input  wire [3:0]  stat_id,
    input  wire        sel,          // 0=名字 1=数值
    output reg  [55:0] ename,
    output reg  [47:0] area_name,
    output reg  [63:0] es
);
    always @(*) begin
        case (ename_id)
      4'd0: ename = 56'h000000002B2A29;
      4'd1: ename = 56'h00000000002D2C;
      4'd2: ename = 56'h00000000002F2E;
      4'd3: ename = 56'h00000000003130;
      4'd4: ename = 56'h00000000003332;
      4'd5: ename = 56'h00000000003534;
      4'd6: ename = 56'h00000000383736;
      4'd7: ename = 56'h0000003C3B3A39;
      4'd8: ename = 56'h000000403F3E3D;
      4'd9: ename = 56'h00000000434241;
      4'd10: ename = 56'h000000442B2A29;
      4'd11: ename = 56'h00004948474645;
      4'd12: ename = 56'h000000354C4B4A;
      4'd13: ename = 56'h00000044353A39;
      4'd14: ename = 56'h000000504F4E4D;
        default: ename = 56'd0;
        endcase
    end

    always @(*) begin
        case (area_id)
      4'd0: area_name = 48'h000054535251;
      4'd1: area_name = 48'h000046455655;
      4'd2: area_name = 48'h00004B4A5857;
      4'd3: area_name = 48'h0000005A5936;
      4'd4: area_name = 48'h00005E5D5C5B;
        default: area_name = 48'd0;
        endcase
    end

    always @(*) begin
        case (stat_id)
      4'd0: es = 64'h0000007024082024;
      4'd1: es = 64'h0041006020042C1E;
      4'd2: es = 64'h008200D048103C42;
      4'd3: es = 64'h00C3010058203456;
      4'd4: es = 64'h01040130680C4C4E;
      4'd5: es = 64'h014501B088344484;
      4'd6: es = 64'h01860260C0246476;
      4'd7: es = 64'h01C702E0E8445CA8;
      4'd8: es = 64'h020803E1284C7CBA;
      4'd9: es = 64'h0249046148309096;
      4'd10: es = 64'h02AA05A1181C3087;
      4'd11: es = 64'h02EB0AA2082C50FA;
      4'd12: es = 64'h032C1183984471A4;
      4'd13: es = 64'h036D1C26405C9280;
      4'd14: es = 64'h03AE4B0E1060A348;
        default: es = 64'd0;
        endcase
    end
endmodule

//-----------------------------------------------------------------------------
// 区域 -> 怪物索引
//-----------------------------------------------------------------------------
module rpg_area (
    input  wire [2:0]  area,
    output reg  [3:0]  mob0,
    output reg  [3:0]  mob1,
    output reg  [3:0]  boss
);
    reg [11:0] am;
    always @(*) begin
        case (area)
      3'd0: am = 12'hA10;
      3'd1: am = 12'hB32;
      3'd2: am = 12'hC54;
      3'd3: am = 12'hD76;
      3'd4: am = 12'hE98;
        default: am = 12'd0;
        endcase
        mob0 = am[3:0];
        mob1 = am[7:4];
        boss = am[11:8];
    end
endmodule

//-----------------------------------------------------------------------------
// 语句表地址
//-----------------------------------------------------------------------------
module rpg_screens (
    input  wire [2:0]  scene,
    output reg  [9:0]  addr
);
    always @(*) begin
        case (scene)
            3'd0: addr = 10'd0;   // title
            3'd1: addr = 10'd20;   // class
            3'd2: addr = 10'd72;   // map
            3'd3: addr = 10'd170;   // battle
            3'd4: addr = 10'd226;   // shop
            3'd5: addr = 10'd294;   // dead
            3'd6: addr = 10'd306;   // win
            3'd7: addr = 10'd332;   // pic
            default: addr = 10'd0;
        endcase
    end
endmodule
