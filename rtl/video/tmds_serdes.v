//=============================================================================
// tmds_serdes.v —— 10:1 串行化器 (5 相位 x DDR)
//
//   像素时钟 clk_pix = 74.25MHz(720p)
//   串行时钟 clk_p5x = 371.25MHz(5x), DDR 后等效 742.5Mbps
//
// 【重要】EG4S20 的 371MHz DDR 输出必须走 IO 的 SERDES/ODDR 硬原语,
// 不能用普通寄存器在 fabric 里做移位。本文件给出两种实现:
//   `define USE_ODDR_PRIM  -> 例化安路 DDR 输出原语(名字请以 TD 原语库为准)
//   默认(不定义)        -> 纯行为模型, 仅用于仿真与 480p(125MHz DDR) 验证
//
// 上板建议: 优先用 TD 的 "IP Generator -> LVDS/SerDes" 或厂家 HDMI 例程里的
//          发送 IP, 把本模块替换成 IP 的输出级, 时序约束才能收敛。
//=============================================================================
`timescale 1ns/1ps
module tmds_serdes (
    input  wire clk_pix,      // 像素时钟(用于加载)
    input  wire clk_p5x,      // 5x 像素时钟, 与 clk_pix 同源同相
    input  wire rst_n,
    input  wire load,         // 每像素一个周期的高电平
    input  wire [9:0] din,    // TMDS 10bit
    output wire dout_p,
    output wire dout_n
);

    reg [9:0] sh;

    // 每个像素周期装载, 之后每个 clk_p5x 移出 2bit
    always @(posedge clk_p5x or negedge rst_n) begin
        if (!rst_n)      sh <= 10'h3FF;
        else if (load)   sh <= din;
        else             sh <= {2'b11, sh[9:2]};
    end

`ifdef USE_ODDR_PRIM
    //---------------------------------------------------------------
    // 安路 DDR 输出原语 (端口名需按 TD 版本核对, 以下为常见形式)
    //   DI: 时钟上升沿输出  DC: 时钟下降沿输出
    //---------------------------------------------------------------
    AL_ODDR u_oddr (
        .DI  (sh[1]),
        .DC  (sh[0]),
        .CLK (clk_p5x),
        .Q   (dout_p)
    );
    assign dout_n = ~dout_p;
`else
    // 行为模型: 用时钟电平做 2:1 复用, 仅仿真/低速可用
    assign dout_p = clk_p5x ? sh[1] : sh[0];
    assign dout_n = ~dout_p;
`endif

endmodule
