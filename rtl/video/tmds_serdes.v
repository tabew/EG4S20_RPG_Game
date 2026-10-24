//=============================================================================
// tmds_serdes.v —— 10:1 串行化（5 相位 × DDR）
//
//   480p: clk_pix = 25.175MHz，clk_p5x = 125.875MHz
//   每像素 10bit = 5 个 clk_p5x 周期 × DDR(每周期 2bit)
//
// ★ DDR 输出必须用 IO 硬原语
//   `assign q = clk ? a : b` 在 125MHz 下会被综合成 LUT，抖动大，
//   典型症状就是**整屏密集竖条纹、黑底也有条纹**。
//   本文件用安路的 EG_LOGIC_ODDR（EG4 系列原语名，端口 d0/d1/clk/q/rst）。
//   若 TD 报找不到该原语，在 TD 安装目录搜 "ODDR" 确认名字
//   （PH1 系列叫 PH1_LOGIC_ODDR），或者直接用 IP Generator 的 LVDS/SerDes。
//
// ★ 相位微调 PH_OFFSET
//   串行化的相位必须和像素时钟对齐，差一个 clk_p5x 周期就会整屏错位。
//   综合后若画面有规律性重影/错位，把 PH_OFFSET 从 0 依次试到 4。
//=============================================================================
`timescale 1ns/1ps
module tmds_serdes #(
    parameter [2:0] PH_OFFSET = 3'd0      // 相位微调，0~4
)(
    input  wire       clk_pix,     // 像素时钟
    input  wire       clk_p5x,     // 5× 像素时钟，与 clk_pix 同源
    input  wire       rst_n,
    input  wire [9:0] din,         // TMDS 10bit（LSB 先发）
    output wire       dout_p,
    output wire       dout_n
);

    //---------------------------------------------------------
    // 5 相位计数器
    //   先把 clk_pix 用两级触发器同步到 clk_p5x 域（消除亚稳态），
    //   再检测上升沿，把相位计数器对齐到像素边界。
    //   之后每 5 个 clk_p5x 自动回绕。
    //---------------------------------------------------------
    reg [1:0] pix_s;                       // 两级同步
    wire      pix_rise = pix_s[1] & ~pix_s[0];
    reg [2:0] ph;

    always @(posedge clk_p5x or negedge rst_n) begin
        if (!rst_n) begin
            pix_s <= 2'b00;
            ph    <= PH_OFFSET;
        end else begin
            pix_s <= {pix_s[0], clk_pix};
            if (pix_rise)          ph <= PH_OFFSET;
            else if (ph == 3'd4)   ph <= 3'd0;
            else                   ph <= ph + 3'd1;
        end
    end

    //---------------------------------------------------------
    // 移位寄存器：每周期右移 2 位（DDR 一次出 2bit，LSB 先发）
    //---------------------------------------------------------
    reg [9:0] sh;

    always @(posedge clk_p5x or negedge rst_n) begin
        if (!rst_n)          sh <= 10'h3FF;
        else if (ph == 3'd0) sh <= din;               // 像素边界装载
        else                 sh <= {2'b11, sh[9:2]};  // 右移 2 位
    end

    //---------------------------------------------------------
    // DDR 输出原语
    //---------------------------------------------------------
`ifdef USE_ODDR_PRIM
    EG_LOGIC_ODDR u_ddr (
        .d0  (sh[0]),        // 时钟上升沿送出
        .d1  (sh[1]),        // 时钟下降沿送出
        .clk (clk_p5x),
        .rst (~rst_n),
        .q   (dout_p)
    );
    assign dout_n = ~dout_p;
`else
    // 行为模型：**只能仿真**。综合出来是 LUT 搭的 DDR，上板必出条纹。
    assign dout_p = clk_p5x ? sh[1] : sh[0];
    assign dout_n = ~dout_p;
`endif

endmodule
