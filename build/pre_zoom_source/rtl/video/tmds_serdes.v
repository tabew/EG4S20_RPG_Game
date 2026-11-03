//=============================================================================
// tmds_serdes.v —— 10:1 串行化器 (5x 时钟 x DDR), 每通道一个
//
// ★ v2 改动: 装载脉冲不再由各通道自行跨时钟域检测 toggle, 而是由 hdmi_tx
//   统一产生一个 5x 域单拍 load 脉冲(带启动校准), 四个通道共用同一脉冲
//   → 通道间位相位天然一致。
//   原因: 200MHz 下对 40MHz 域 toggle 的采样 setup 只剩 ~3ns, 各通道独立
//   检测可能偶发差 1 拍, 造成该通道 10bit 字错位 2bit → 画面竖条纹 /
//   行错位 / 颜色错乱。改成"模-5 计数器 + 上电一次校准"后, 装载时机
//   完全确定, 且永远落在 din 稳定窗口的正中间(远离翻转沿 ≥13ns)。
//
//   结构 (本模块全 5x 单时钟域, 无跨时钟域逻辑):
//     load 拍  : tx_pdat <= {din[0],din[1],...,din[9]} (din[0] 在最高位)
//     其余拍   : tx_pdat 每拍左移 2 位; tx_sdat 取反锁存高 2 位
//     IO 单元  : EG_LOGIC_ODDR (d0=上升沿输出位, d1=下降沿输出位), 5x DDR
//               → 5 拍 x 2 沿 = 10 bit / 像素
//
//   ★ 必须配合 IOSTANDARD=LVDS33 的 P 端引脚约束使用, N 端由 TD 自动配对。
//=============================================================================
`timescale 1ns/1ps
module tmds_serdes (
    input  wire clk_p5x,      // 5x 像素时钟
    input  wire rst_n,
    input  wire load,         // 5x 域装载脉冲(每像素一拍, 四通道共用)
    input  wire [9:0] din,    // TMDS 10bit, din[0] 先发
    output wire dout_p        // P 端输出, N 端由 TD 的 LVDS 约束自动生成
);

`ifdef SIM_BEHAV
    // 行为模型: 仅用于 RTL 仿真
    reg [9:0] sh;
    reg       ph;
    always @(posedge clk_p5x or negedge rst_n) begin
        if (!rst_n)      sh <= 10'h0;
        else if (load)   sh <= din;
        else             sh <= {2'b00, sh[9:2]};
    end
    always @(posedge clk_p5x or negedge rst_n) begin
        if (!rst_n) ph <= 1'b0;
        else        ph <= ~ph;
    end
    assign dout_p = ph ? sh[0] : sh[1];
`else
    //------------------------------------------------------------------
    // 移位 + 输出流水 (与原版/官方源码一致)
    //   装载: {din[0],din[1],...,din[9]} → din[0] 在最高位, LSB 先发
    //   其余拍: 左移 2 位; tx_sdat 取反最高 2 位
    //------------------------------------------------------------------
    reg [9:0] tx_pdat;
    reg [1:0] tx_sdat, tx_sdat_1d;
    always @(posedge clk_p5x or negedge rst_n) begin
        if (!rst_n) begin
            tx_pdat    <= 10'h0;
            tx_sdat    <= 2'b00;
            tx_sdat_1d <= 2'b00;
        end else begin
            if (load)
                tx_pdat <= {din[0], din[1], din[2], din[3], din[4],
                            din[5], din[6], din[7], din[8], din[9]};
            else
                tx_pdat <= {tx_pdat[7:0], 2'b00};
            tx_sdat    <= ~tx_pdat[9:8];
            tx_sdat_1d <= tx_sdat;
        end
    end

    //------------------------------------------------------------------
    // IO DDR 输出原语 (安路 EG4 系列)
    //   d0 = 上升沿输出位(先发), d1 = 下降沿输出位, rst 恒 0
    //------------------------------------------------------------------
    EG_LOGIC_ODDR u_oddr (
        .q   (dout_p),
        .clk (clk_p5x),
        .d0  (tx_sdat_1d[1]),
        .d1  (tx_sdat_1d[0]),
        .rst (1'b0)
    );
`endif

endmodule
