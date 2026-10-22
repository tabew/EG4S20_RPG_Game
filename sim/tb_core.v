//=============================================================================
// tb_core.v —— yosys sim 用的功能仿真
//
//   yosys sim 是周期驱动的: 不支持 #延时, 也不支持在 always 里 $display。
//   所以本 TB 只产生激励, 结果导出 VCD, 由 tools/vcd_screen.py 重建画面。
//
//   关键: 要观察的信号必须是模块输出端口, 否则 prep 之后不会进 VCD。
//
//   激励: 复位 -> 标题页 -> 按 1 -> 选职业 -> 按 1 -> 地图页
//
// 运行: yosys -s sim/run_core.ys
//=============================================================================
`timescale 1ns/1ps

module tb_core (
    input  wire        clk,
    output wire        o_we,
    output wire [10:0] o_waddr,
    output wire [15:0] o_wdata,
    output wire [2:0]  o_scene,
    output wire [9:0]  o_hp,
    output wire [9:0]  o_maxhp,
    output wire [7:0]  o_atk,
    output wire [7:0]  o_def,
    output wire [11:0] o_gold,
    output wire [3:0]  o_lv,
    output wire [31:0] o_cyc,
    output wire [3:0]  o_state,
    output wire [9:0]  o_pc
);

    reg [31:0] cyc = 0;
    reg        rst_n = 0;
    reg  [3:0] key = 4'b0000;

    wire        we;
    wire [10:0] waddr;
    wire [15:0] wdata;

    rpg_core u_core (
        .clk        (clk),
        .rst_n      (rst_n),
        .key        (key),
        .we         (we),
        .waddr      (waddr),
        .wdata      (wdata),
        .dbg_scene  (o_scene),
        .dbg_hp     (o_hp),
        .dbg_maxhp  (o_maxhp),
        .dbg_atk    (o_atk),
        .dbg_def    (o_def),
        .dbg_gold   (o_gold),
        .dbg_lv     (o_lv),
        .dbg_state  (o_state),
        .dbg_pc     (o_pc)
    );

    // 端口保证进 VCD
    assign o_we    = we;
    assign o_waddr = waddr;
    assign o_wdata = wdata;
    assign o_cyc   = cyc;


    // 周期计数(只喂激励, 不打印)
    always @(posedge clk) begin
        cyc <= cyc + 1;

        if (cyc == 3) rst_n <= 1'b1;

        // TITLE -> CLASS
        if (cyc == 5000) key <= 4'b0001;
        if (cyc == 5002) key <= 4'b0000;

        // CLASS -> MAP (剑士)
        if (cyc == 15000) key <= 4'b0001;
        if (cyc == 15002) key <= 4'b0000;
    end

endmodule
