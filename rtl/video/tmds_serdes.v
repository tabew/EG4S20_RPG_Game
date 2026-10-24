//=============================================================================
// tmds_serdes.v —— 10:1 串行化（5 相位 × DDR）
//
//   480p: clk_pix = 25.175MHz, clk_p5x = 125.875MHz
//   每像素 10bit，5 个 clk_p5x 周期 × DDR(2bit/周期) = 10bit ✓
//
// ★ 关键：DDR 输出必须用 IO 的硬原语，绝不能用 LUT 搭
//     `dout = clk ? a : b` 这种写法在 125MHz 下会出毛刺和偏斜，
//     症状就是**整屏密集竖条纹、黑底也有条纹**。
//
//   两条路，任选其一：
//     A. 定义 USE_ODDR_PRIM，例化安路的 DDR 输出原语
//     B. 用 TD 的 IP Generator → LVDS/SerDes，把本模块整个替换成 IP 的输出级
//
//   原语名和端口名不同 TD 版本有差异（ODDR / AL_ODDR，端口常见 D0/D1/CLK/Q
//   或 DAT0/DAT1/CLK/Q），以 TD 原语库为准；也可以让 IP Generator 生成
//   DDR 输出后把生成的 wrapper 抄进来。
//=============================================================================
`timescale 1ns/1ps
module tmds_serdes (
    input  wire       clk_pix,     // 像素时钟
    input  wire       clk_p5x,     // 5× 像素时钟，与 clk_pix 同源
    input  wire       rst_n,
    input  wire [9:0] din,         // TMDS 10bit（LSB 先发）
    output wire       dout_p,
    output wire       dout_n
);

    //---------------------------------------------------------
    // 5 相位计数器
    //   用 clk_pix 的上升沿把相位对齐到像素边界，之后每 5 个
    //   clk_p5x 自动回绕。靠这个计数器决定什么时候装载新字。
    //---------------------------------------------------------
    reg [2:0] ph;
    reg       pix_d;
    wire      pix_rise = clk_pix & ~pix_d;

    always @(posedge clk_p5x or negedge rst_n) begin
        if (!rst_n) begin
            ph    <= 3'd4;
            pix_d <= 1'b0;
        end else begin
            pix_d <= clk_pix;
            if (pix_rise || ph == 3'd4) ph <= 3'd0;
            else                        ph <= ph + 3'd1;
        end
    end

    //---------------------------------------------------------
    // 移位寄存器：每周期右移 2 位（DDR 一次出 2 bit）
    //---------------------------------------------------------
    reg [9:0] sh;

    always @(posedge clk_p5x or negedge rst_n) begin
        if (!rst_n)              sh <= 10'h3FF;
        else if (ph == 3'd0)     sh <= din;              // 像素边界装载
        else                     sh <= {2'b11, sh[9:2]}; // 右移 2 位
    end

`ifdef USE_ODDR_PRIM
    //---------------------------------------------------------------
    // A. 安路 DDR 输出原语（端口名请按 TD 原语库核对）
    //---------------------------------------------------------------
    ODDR u_ddr (
        .D0  (sh[0]),        // 时钟上升沿送出
        .D1  (sh[1]),        // 时钟下降沿送出
        .CLK (clk_p5x),
        .RST (~rst_n),
        .Q   (dout_p)
    );
    assign dout_n = ~dout_p;
`else
    //---------------------------------------------------------------
    // 行为模型：**只能仿真**
    //   综合出来会是一个 clock-as-data 的 LUT，125MHz 下必出条纹。
    //   上板前必须换成 A 或 TD 的 SerDes IP。
    //---------------------------------------------------------------
    assign dout_p = clk_p5x ? sh[1] : sh[0];
    assign dout_n = ~dout_p;
`endif

endmodule
