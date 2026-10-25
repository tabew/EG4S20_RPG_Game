//=============================================================================
// tmds_serdes.v —— 10:1 串行化（5 相位 × DDR）
//
//   480p: clk_pix = 25MHz，clk_p5x = 125MHz
//   每像素 10bit = 5 个 clk_p5x 周期 × DDR(每周期 2bit)
//
// 【为什么要有 pair 这一级】
//   ODDR 在上升沿锁 d0、下降沿锁 d1，两位必须在**整个周期内保持稳定**。
//   如果直接把移位寄存器的 sh[0]/sh[1] 接给 ODDR，sh 会在上升沿变化，
//   结果 d0 取到旧值、d1 取到新值 —— 每个像素的两位会错开。
//   所以先用 pair 在上升沿锁住"本周期的两位"，再把 pair 送 ODDR，
//   sh 同一拍右移，两者互不干扰。
//
// 【上板必须定义 USE_ODDR_PRIM】
//   不定义时用的是行为模型（仿真用）。综合出来是 LUT 搭的 DDR，
//   125MHz 下抖动极大，症状是整屏密集竖条纹、黑底也有条纹。
//
// 【原语】安路 EG4 系列：EG_LOGIC_ODDR(q, clk, d0, d1, rst)
//   见《EG4D20 FPGA 数据手册》"输出双沿驱动单元"一节。
//   若 TD 报找不到，在安装目录搜 "ODDR" 确认名字（PH1 系列叫 PH1_LOGIC_ODDR）。
//=============================================================================
`timescale 1ns/1ps
module tmds_serdes #(
    parameter [2:0] PH_OFFSET = 3'd0      // 相位微调，画面规律性错位时试 0~4
)(
    input  wire       clk_pix,
    input  wire       clk_p5x,
    input  wire       rst_n,
    input  wire [9:0] din,                // TMDS 10bit（LSB 先发）
    output wire       dout_p,
    output wire       dout_n
);

    //---------------------------------------------------------
    // 5 相位计数器：clk_pix 两级同步后判上升沿，把相位对齐到像素边界
    //---------------------------------------------------------
    reg [1:0] pix_s;
    wire      pix_rise = pix_s[1] & ~pix_s[0];
    reg [2:0] ph;

    always @(posedge clk_p5x or negedge rst_n) begin
        if (!rst_n) begin
            pix_s <= 2'b00;
            ph    <= PH_OFFSET;
        end else begin
            pix_s <= {pix_s[0], clk_pix};
            // 用 pix_rise 对齐，但不能在 ph 已经是 0 的时候再置 0 ——
            // 那样会出现"连续两个 ph=0"，该像素多出一拍，
            // 之后整条串行流的字边界全部错开（症状就是满屏条纹）。
            if (pix_rise && ph != 3'd0) ph <= PH_OFFSET;
            else if (ph == 3'd4)        ph <= 3'd0;
            else                        ph <= ph + 3'd1;
        end
    end

    //---------------------------------------------------------
    // 移位队列 + 本周期两位
    //---------------------------------------------------------
    reg [9:0] sh;
    reg [1:0] pair;

    always @(posedge clk_p5x or negedge rst_n) begin
        if (!rst_n) begin
            sh   <= 10'h3FF;
            pair <= 2'b11;
        end else begin
            pair <= sh[1:0];                  // 本周期要发的两位
            if (ph == 3'd0) sh <= din;        // 像素边界装载
            else            sh <= {2'b11, sh[9:2]};
        end
    end

    //---------------------------------------------------------
    // DDR 输出
    //---------------------------------------------------------
`ifdef USE_ODDR_PRIM
    EG_LOGIC_ODDR u_ddr (
        .d0  (pair[0]),       // 上升沿送出
        .d1  (pair[1]),       // 下降沿送出
        .clk (clk_p5x),
        .rst (~rst_n),
        .q   (dout_p)
    );
    assign dout_n = ~dout_p;
`else
    // 行为模型：两个寄存器 + 选择器，等价于 ODDR（上升沿锁 d0、下降沿锁 d1）
    //   注意不能用一个 reg 在两个 always 里赋值 —— 那是多驱动，仿真会打架
    reg q_pos, q_neg;
    always @(posedge clk_p5x or negedge rst_n)
        if (!rst_n) q_pos <= 1'b1; else q_pos <= pair[0];
    always @(negedge clk_p5x or negedge rst_n)
        if (!rst_n) q_neg <= 1'b1; else q_neg <= pair[1];
    assign dout_p = clk_p5x ? q_pos : q_neg;
    assign dout_n = ~dout_p;
`endif

endmodule
