//=============================================================================
// clk_gen.v —— 同源像素、TMDS 和 SDRAM 时钟
//
//   CEA_COMPAT=1: clk_pix=25.2MHz, clk_p5x=126MHz, CEA 640x480p60
//   CEA_COMPAT=0: clk_pix=40MHz, clk_p5x=200MHz, legacy 800x600p60
//   clk_mem50   = 50 MHz, SPI/解码/SDRAM 控制器时钟
//   clk_sdram50 = 50 MHz, 相对 clk_mem50 正向延迟 90 度 (5ns)
//
//   CEA video uses a second native-generated 630MHz NOCOMP PLL.
//   Memory retains the validated 1000MHz PLL, dividers 25/5/20/20.
//   C2 CPHASE=19, C3 CPHASE=4, FPHASE=0: 已用安路 PLL 功能模型
//   验证 40/200/50MHz 周期和 C3 比 C2 晚 5ns。
//   SIM_BEHAV 继续透传输入时钟, 不用于证明物理 SDRAM 相位。
//=============================================================================
`timescale 1ns/1ps
module clk_gen #(
    parameter integer CEA_COMPAT = 0
) (
    input  wire clk_in,
    input  wire rst_n,
    output wire clk_pix,
    output wire clk_p5x,
    output wire locked,
    output wire clk_mem50,
    output wire clk_sdram50
);

`ifdef SIM_BEHAV
    assign clk_pix = clk_in;
    assign clk_p5x = clk_in;
    assign locked  = rst_n;
    assign clk_mem50 = clk_in;
    assign clk_sdram50 = clk_in;
`else
    wire legacy_pix, legacy_p5x, legacy_locked;
    // Preserve the validated 50MHz memory domain and its +90-degree SDRAM clock.
    media_pll u_pll (
        .refclk(clk_in),
        .reset(~rst_n),
        .clk0_out(legacy_pix),
        .clk1_out(legacy_p5x),
        .clk2_out(clk_mem50),
        .clk3_out(clk_sdram50),
        .extlock(legacy_locked)
    );
    generate
        if (CEA_COMPAT != 0) begin : g_cea
            wire video_locked;
            cea_video_pll u_video_pll (
                .refclk(clk_in), .reset(~rst_n),
                .clk_pix(clk_pix), .clk_p5x(clk_p5x),
                .extlock(video_locked)
            );
            assign locked = legacy_locked & video_locked;
        end else begin : g_legacy
            assign clk_pix = legacy_pix;
            assign clk_p5x = legacy_p5x;
            assign locked = legacy_locked;
        end
    endgenerate

`endif


endmodule

`ifndef SIM_BEHAV
// Native TD 5.6 test_ipgen (-ip pll -family eg) generated this profile:
// NOCOMP, VCO_PHASE_0, PFD=10MHz, VCO=630MHz, output dividers 25/5.
// REF25/FB63 with external serial feedback was rejected: PFD=2MHz <10MHz.
// The separate legacy PLL below retains exact memory/SRC SPI frequencies.
module cea_video_pll (
    input wire refclk,
    input wire reset,
    output wire extlock,
    output wire clk_pix,
    output wire clk_p5x
);
    wire [4:0] pll_clkc;
    wire unused_psdone;
    wire [7:0] unused_do;
    EG_LOGIC_BUFG bufg_pix (.i(pll_clkc[0]), .o(clk_pix));
    assign clk_p5x = pll_clkc[1];
    EG_PHY_PLL #(
        .DPHASE_SOURCE("DISABLE"), .DYNCFG("DISABLE"), .FIN("50.000"),
        .FEEDBK_MODE("NOCOMP"), .FEEDBK_PATH("VCO_PHASE_0"),
        .STDBY_ENABLE("DISABLE"), .PLLRST_ENA("ENABLE"), .SYNC_ENABLE("DISABLE"),
        .GMC_GAIN(0), .ICP_CURRENT(9), .KVCO(2),
        .LPF_CAPACITOR(2), .LPF_RESISTOR(8),
        .REFCLK_DIV(5), .FBCLK_DIV(63),
        .CLKC0_ENABLE("ENABLE"), .CLKC0_DIV(25), .CLKC0_CPHASE(24), .CLKC0_FPHASE(0),
        .CLKC1_ENABLE("ENABLE"), .CLKC1_DIV(5), .CLKC1_CPHASE(4), .CLKC1_FPHASE(0)
    ) pll_inst (
        .refclk(refclk), .reset(reset), .stdby(1'b0), .extlock(extlock),
        .load_reg(1'b0), .psclk(1'b0), .psdown(1'b0), .psstep(1'b0),
        .psclksel(3'b000), .psdone(unused_psdone),
        .dclk(1'b0), .dcs(1'b0), .dwe(1'b0), .di(8'd0), .daddr(6'd0),
        .do(unused_do), .fbclk(1'b0), .clkc(pll_clkc)
    );
endmodule

// Keep this wrapper in the already-included clock file for TD projects.
module media_pll (
    input wire refclk,
    input wire reset,
    output wire extlock,
    output wire clk0_out,
    output wire clk1_out,
    output wire clk2_out,
    output wire clk3_out
);
    wire [4:0] pll_clkc;
    wire unused_psdone;
    wire [7:0] unused_do;
    EG_LOGIC_BUFG bufg_feedback (.i(pll_clkc[0]), .o(clk0_out));
    assign clk1_out = pll_clkc[1];
    EG_LOGIC_BUFG bufg_mem (.i(pll_clkc[2]), .o(clk2_out));
    EG_LOGIC_BUFG bufg_sdram (.i(pll_clkc[3]), .o(clk3_out));

    EG_PHY_PLL #(
        .DPHASE_SOURCE("DISABLE"), .DYNCFG("DISABLE"), .FIN("50.000"),
        .FEEDBK_MODE("NORMAL"), .FEEDBK_PATH("CLKC0_EXT"),
        .STDBY_ENABLE("DISABLE"), .PLLRST_ENA("ENABLE"), .SYNC_ENABLE("DISABLE"),
        .GMC_GAIN(0), .ICP_CURRENT(9), .KVCO(2),
        .LPF_CAPACITOR(2), .LPF_RESISTOR(8),
        .REFCLK_DIV(5), .FBCLK_DIV(4),
        .CLKC0_ENABLE("ENABLE"), .CLKC0_DIV(25), .CLKC0_CPHASE(24), .CLKC0_FPHASE(0),
        .CLKC1_ENABLE("ENABLE"), .CLKC1_DIV(5), .CLKC1_CPHASE(4), .CLKC1_FPHASE(0),
        .CLKC2_ENABLE("ENABLE"), .CLKC2_DIV(20), .CLKC2_CPHASE(19), .CLKC2_FPHASE(0),
        .CLKC3_ENABLE("ENABLE"), .CLKC3_DIV(20), .CLKC3_CPHASE(4), .CLKC3_FPHASE(0)
    ) pll_inst (
        .refclk(refclk), .reset(reset), .stdby(1'b0), .extlock(extlock),
        .load_reg(1'b0), .psclk(1'b0), .psdown(1'b0), .psstep(1'b0),
        .psclksel(3'b000), .psdone(unused_psdone),
        .dclk(1'b0), .dcs(1'b0), .dwe(1'b0), .di(8'd0), .daddr(6'd0),
        .do(unused_do), .fbclk(clk0_out), .clkc(pll_clkc)
    );
endmodule
`endif
