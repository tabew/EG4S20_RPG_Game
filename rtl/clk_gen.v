//=============================================================================
// clk_gen.v —— 时钟生成(本工程只需要两路)
//
//   clk_pix = 25.175 MHz   640x480p60 像素时钟
//   clk_p5x = 125.875 MHz  5x 像素时钟, TMDS 串行化用(DDR 后 251.75Mbps)
//
// ★ 上板必须替换成 TD(安路 Tang Dynasty) IP Generator 生成的 PLL:
//     Tools -> IP Generator -> PLL
//   输入 50MHz, 输出 c0 = 25.175MHz, c1 = 125.875MHz, 两路同源。
//
//   25.175 = 50 * 161 / 320 、 125.875 = 50 * 161 / 64
//   若分数分频配不出来, 可以退用 25.000MHz + 125.000MHz, 显示器一般也认
//   (帧率变 59.5Hz, 对字符游戏毫无影响)。
//
// 仿真时 `define SIM_BEHAV, 直接透传, 功能验证够用。
//=============================================================================
`timescale 1ns/1ps
module clk_gen (
    input  wire clk_in,
    input  wire rst_n,
    output wire clk_pix,
    output wire clk_p5x,
    output wire locked
);

`ifdef SIM_BEHAV
    assign clk_pix = clk_in;
    assign clk_p5x = clk_in;
    assign locked  = rst_n;
`else
    //-------------------------------------------------------------
    // 把下面替换成 TD 生成的 PLL 实例
    //-------------------------------------------------------------
    // pll_ip u_pll (
    //     .clk_in1  (clk_in),
    //     .clk_out1 (clk_pix),     // 25.175MHz
    //     .clk_out2 (clk_p5x),     // 125.875MHz
    //     .locked   (locked),
    //     .reset    (~rst_n)
    // );

    // 未替换前的占位(透传): 能过综合、能做资源评估, 但上板无画面
    assign clk_pix = clk_in;
    assign clk_p5x = clk_in;
    assign locked  = rst_n;
`endif

endmodule
