//=============================================================================
// clk_gen.v —— 时钟生成(本工程只需要两路)
//
//   clk_pix = 40.000 MHz   800x600p60 像素时钟 (VESA DMT)
//   clk_p5x = 200.000 MHz  5x 像素时钟, TMDS 串行化用(DDR 后 400Mbps,
//                          远低于 EG4S20 LVDS 800Mbps 上限)
//
// ★ 上板必须用 TD(安路 Tang Dynasty) IP Generator 重新生成 PLL:
//     Tools -> IP Generator -> PLL
//   输入 50MHz, 输出 c0 = 40.000MHz, c1 = 200.000MHz, 两路同源。
//
//   40/200 全是整数分频 (VCO=800MHz: 800/20=40, 800/4=200),
//   TD 会精确匹配, 不会再像 25.175 那样被取整 —— 这正是选 800x600 的原因。
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
    // TD IP Generator 生成的 PLL (C0=40MHz, C1=200MHz, reset 高有效)
    // 端口名以实际生成的 pll_ip.v 为准, 不一致时对应修改下面几行
    //-------------------------------------------------------------
     pll_ip u_pll (
         .refclk  (clk_in),
         .clk0_out (clk_pix),      //40MHz
         .clk1_out (clk_p5x),      //200MHz
         .extlock   (locked),
         .reset    (~rst_n)
    );

`endif


endmodule
