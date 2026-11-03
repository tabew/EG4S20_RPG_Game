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
//   9 MSG  10 FRAME(arg[5:0]=w, arg[12:8]=h)  11 ADESC  12 SIDE
//=============================================================================
`timescale 1ns/1ps

module font_rom (
    input  wire        clk,
    input  wire [8:0]  glyph,
    input  wire [3:0]  row,
    output reg  [15:0] data
);
    reg [15:0] mem [0:8191];
    initial $readmemh("C:/Users/Tab_E/Downloads/EG4S20_RPG_Game-main/rtl/gen/font.hex", mem);
    always @(posedge clk) data <= mem[{glyph, row}];
endmodule

module cmd_rom (
    input  wire        clk,
    input  wire [8:0]  addr,
    output reg  [31:0] data
);
    reg [31:0] mem [0:511];
    initial $readmemh("C:/Users/Tab_E/Downloads/EG4S20_RPG_Game-main/rtl/gen/cmd.hex", mem);
    always @(posedge clk) data <= mem[addr];
endmodule

module str_rom (
    input  wire       clk,
    input  wire [9:0] addr,
    output reg  [15:0] data
);
    reg [15:0] mem [0:1023];
    initial $readmemh("C:/Users/Tab_E/Downloads/EG4S20_RPG_Game-main/rtl/gen/str.hex", mem);
    always @(posedge clk) data <= mem[addr];
endmodule

module art_rom (
    input  wire        clk,
    input  wire [11:0] addr,
    output reg  [7:0]  data
);
    reg [7:0] mem [0:4095];
    initial $readmemh("C:/Users/Tab_E/Downloads/EG4S20_RPG_Game-main/rtl/gen/art.hex", mem);
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
      5'd0: ename = 63'h0000000000005429;
      5'd1: ename = 63'h000000000000582B;
      5'd2: ename = 63'h0000031180BC5C2D;
      5'd3: ename = 63'h0000000000006632;
      5'd4: ename = 63'h00000001B8D86A34;
      5'd5: ename = 63'h0000000198E47034;
      5'd6: ename = 63'h0000000000F0763A;
      5'd7: ename = 63'h0000000200FC7C3D;
      5'd8: ename = 63'h0000000208CC7C3D;
      5'd9: ename = 63'h0000000229108642;
      5'd10: ename = 63'h0000000000008E46;
      5'd11: ename = 63'h0000000259289248;
        default: ename = 63'd0;
        endcase
    end

    always @(*) begin
        case (area_id)
      4'd0: area_name = 54'h00000170B49A4C;
      4'd1: area_name = 54'h000001C0D09E4E;
      4'd2: area_name = 54'h0000000144A03A;
      4'd3: area_name = 54'h000002A950A652;
        default: area_name = 54'd0;
        endcase
    end

    always @(*) begin
        case (area_id)
      3'd0: adesc = 11'd593;
      3'd1: adesc = 11'd623;
      3'd2: adesc = 11'd653;
      3'd3: adesc = 11'd683;
        default: adesc = 55'd0;
        endcase
    end

    always @(*) begin
        case (stat_id)
      5'd0: es = 64'h0003010058203456;
      5'd1: es = 64'h005101206428445C;
      5'd2: es = 64'h00AB0AA2082C50FA;
      5'd3: es = 64'h00C501B088344484;
      5'd4: es = 64'h011201F098285878;
      5'd5: es = 64'h016C1183984471A4;
      5'd6: es = 64'h01860260C03064D4;
      5'd7: es = 64'h01C702E0E8505D18;
      5'd8: es = 64'h022D1C26405C9280;
      5'd9: es = 64'h024803E1284C7D7C;
      5'd10: es = 64'h02970441403C915E;
      5'd11: es = 64'h02EE4B0E1060A348;
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
      3'd0: am = 25'h0208020;
      3'd1: am = 25'h0520C83;
      3'd2: am = 25'h08398E6;
      3'd3: am = 25'h0B52549;
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

//-----------------------------------------------------------------------------
// 上下文选句: {区域, 变体} -> 字符串地址。变体 0 血量足, 1 伤重且小怪已清, 2 伤重且仍有小怪。
//-----------------------------------------------------------------------------
module rpg_ctx (
    input  wire [2:0]  area,
    input  wire [1:0]  varq,
    output reg  [10:0] ctx,
    output reg  [10:0] danger
);
    always @(*) begin
        case ({area, varq})
            {3'd0, 2'd0}: ctx = 11'd593;
            {3'd0, 2'd1}: ctx = 11'd602;
            {3'd0, 2'd2}: ctx = 11'd614;
            {3'd1, 2'd0}: ctx = 11'd623;
            {3'd1, 2'd1}: ctx = 11'd632;
            {3'd1, 2'd2}: ctx = 11'd644;
            {3'd2, 2'd0}: ctx = 11'd653;
            {3'd2, 2'd1}: ctx = 11'd662;
            {3'd2, 2'd2}: ctx = 11'd673;
            {3'd3, 2'd0}: ctx = 11'd683;
            {3'd3, 2'd1}: ctx = 11'd692;
            {3'd3, 2'd2}: ctx = 11'd703;
            default: ctx = 11'd0;
        endcase
    end
    always @(*) begin
        case (area)
            3'd0: danger = 11'd0;
            3'd1: danger = 11'd712;
            3'd2: danger = 11'd722;
            3'd3: danger = 11'd732;
            default: danger = 11'd0;
        endcase
    end
endmodule
