// 仿真用空壳: 只为了让 iverilog 能展开 media_sdram_ctrl 所在文件
// 真实综合走 TD 的 EG_PHY_SDRAM_2M_32 宏, 这个文件不参与工程
module EG_PHY_SDRAM_2M_32 (
    input  wire        clk,
    input  wire        ras_n,
    input  wire        cas_n,
    input  wire        we_n,
    input  wire [10:0] addr,
    input  wire [1:0]  ba,
    inout  wire [31:0] dq,
    input  wire        cs_n,
    input  wire        dm0,
    input  wire        dm1,
    input  wire        dm2,
    input  wire        dm3,
    input  wire        cke
);
    assign dq = 32'bz;
endmodule
