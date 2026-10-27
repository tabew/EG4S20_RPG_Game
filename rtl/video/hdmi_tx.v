//=============================================================================
// hdmi_tx.v —— HDMI/DVI 发送端（v3: 官方加密 IP 版）
//
// ★ 历史教训：手写 TMDS 编码 + EG_LOGIC_ODDR 串化在 25/125MHz(640x480) 下
//   能出画面，但升到 40/200MHz(800x600) 后花屏（竖条纹/行错位/颜色错乱），
//   色条诊断模式同样花屏 → 排除游戏逻辑，锁定串化链路。
//
//   本版改用安路官方加密 IP（来自官方 HDMI 参考工程，同芯片 EG4S20BG256、
//   该工程以 537.5MHz 串行时钟验证过）：
//     DVITransmitter（加密 VHDL）内部含 TMDSEncoder x3 + SerializerN_1_lvds x4，
//     只需 24bit RGB + HS/VS/DE + PCLK + PCLK_X5。
//
//   参考工程 ref_hdmi/HDMII 已验证：
//     - Verilog 顶层直接例化 VHDL 实体（混合语言编译可用）
//     - RST_I 为【高有效】复位
//     - FAMILY 泛型默认即 "EG4"
//
//   引脚仍用本底板实测映射（640x480 曾验证通过）：
//     hdmi_clk_p = P1, hdmi_d_p[0] = N1, [1] = P4, [2] = J3 (LVDS33)
//=============================================================================
`timescale 1ns/1ps
module hdmi_tx #(
    parameter integer H_ACTIVE    = 800,    // 保留参数以兼容旧例化（IP 内部无需）
    parameter integer H_TOTAL     = 1056,
    parameter integer AUDIO_DI_EN = 0       // 官方 IP 不含音频数据岛, 恒为 0
)(
    input  wire        clk_pix,
    input  wire        clk_p5x,
    input  wire        rst_pix_n,           // 低有效

    input  wire [15:0] rgb,                 // RGB565
    input  wire        hs,
    input  wire        vs,
    input  wire        de,

    // 音频接口保留但无效（官方 IP 不支持）
    input  wire [55:0] aud_pkt,
    input  wire        aud_req,
    output wire        aud_got,

    // 真差分输出: 只引出 P 端, N 端由 TD 根据 LVDS 约束自动配对
    output wire [2:0]  hdmi_d_p,
    output wire        hdmi_clk_p
);

    assign aud_got = 1'b0;

    //---------------------------------------------------------
    // RGB565 -> RGB888（低位用自身最高位复制, 与原灰度校准一致）
    //---------------------------------------------------------
    wire [23:0] rgb888 = {
        rgb[15:11], rgb[15:13],     // R: 5bit + 3bit 复制
        rgb[10:5],  rgb[10:9],      // G: 6bit + 2bit 复制
        rgb[4:0],   rgb[4:2]        // B: 5bit + 3bit 复制
    };

    //---------------------------------------------------------
    // 安路官方 DVI 发送链（加密 VHDL 实体, Verilog 直接例化 ——
    // 与官方参考工程 hdmi_top.v → hdmi_tx(VHDL) 的用法一致）
    //---------------------------------------------------------
    DVITransmitter #(
        .FAMILY("EG4")
    ) u_dvi (
        .RED_I         (rgb888[23:16]),
        .GREEN_I       (rgb888[15:8]),
        .BLUE_I        (rgb888[7:0]),
        .HS_I          (hs),
        .VS_I          (vs),
        .VDE_I         (de),
        .RST_I         (~rst_pix_n),        // IP 内部高有效
        .PCLK_I        (clk_pix),           // 40 MHz
        .PCLK_X5_I     (clk_p5x),           // 200 MHz
        .TMDS_TX_CLK_P (hdmi_clk_p),
        .TMDS_TX_2_P   (hdmi_d_p[2]),       // 红通道
        .TMDS_TX_1_P   (hdmi_d_p[1]),       // 绿通道
        .TMDS_TX_0_P   (hdmi_d_p[0])        // 蓝通道(承载 HS/VS)
    );

endmodule
