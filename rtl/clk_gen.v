//=============================================================================
// clk_gen.v —— 时钟生成
//
//   PLL 实际输出 (IP Generator 取整后):
//     clk0_out = 25.000MHz  -> clk_pix (640x480 像素时钟, 帧率约 59.5Hz)
//     clk1_out = 125.000MHz -> clk_p5x (TMDS 串行化, DDR 后 250Mbps)
//
//   宏开关:
//     SIM_BEHAV  仿真用, 直接透传
//     USE_PLL_IP 上板用, 例化 TD IP Generator 生成的 pll_ip
//     都不定义   故意例化不存在的模块, 逼综合报错, 防止忘配宏烧板黑屏
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
`ifdef USE_PLL_IP
    // TD IP Generator 生成的 PLL (C0=25MHz, C1=125MHz, reset 高有效)
    pll_ip u_pll (
        .refclk   (clk_in),
        .reset    (~rst_n),
        .extlock  (locked),
        .clk0_out (clk_pix),
        .clk1_out (clk_p5x)
    );
`else
    clk_gen_undefined_mode_error u_undefined_mode_error();
`endif
`endif

endmodule
