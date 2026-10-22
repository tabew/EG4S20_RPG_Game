//=============================================================================
// tmds_encoder.v —— DVI/HDMI TMDS 8b/10b 编码器
//
//   输入: 8bit 像素分量 + 2bit 控制(HS/VS) + de
//   de=1 : 视频期, 走数据编码; de=0 : 消隐期, 走控制字编码
//   输出: 10bit(LSB 先串出)
//
// 依据 HDMI 1.4b 5.4.1:
//   步骤1 统计 din 中 1 的个数 n1d
//   步骤2 若 n1d>4 或 (n1d==4 且 din[0]==0) 则取反, q_m[8] 记录取反标志
//   步骤3 依据 q_m 的 1 个数 n1q 与累计极性 cnt, 在三类输出中选择
//         A: cnt==0 或 n1q==4  -> {~q_m[8],  q_m[8],  q_m[7:0]}
//         B: 与 cnt 同向失衡     -> {  1'b1,    q_m[8],  q_m[7:0]}
//         C: 与 cnt 反向失衡     -> {  1'b0,   ~q_m[8], ~q_m[7:0]}
//   注意 q_out[8] 始终表示"输出低 8 位相对 din 是否被取反", 三类保持一致
//=============================================================================
`timescale 1ns/1ps
module tmds_encoder (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [7:0]  din,
    input  wire [1:0]  ctl,     // {vs, hs}
    input  wire        de,
    output reg  [9:0]  dout
);

    reg  [3:0]        n1d;
    reg  [8:0]        q_m;      // {取反标志, 数据}
    reg  [3:0]        n1q;
    reg  signed [4:0] cnt;      // 累计极性 -8..+8
    reg  [9:0]        q_next;
    wire signed [4:0] bal = $signed({1'b0, n1q}) - 5'sd4;   // -4..+4

    integer i;

    // ---- 步骤1 ----
    always @(*) begin
        n1d = 4'd0;
        for (i = 0; i < 8; i = i + 1) n1d = n1d + {3'd0, din[i]};
    end

    // ---- 步骤2 ----
    always @(*) begin
        if (n1d > 4'd4 || (n1d == 4'd4 && din[0] == 1'b0))
            q_m = {1'b1, ~din};
        else
            q_m = {1'b0,  din};
    end

    always @(*) begin
        n1q = 4'd0;
        for (i = 0; i < 8; i = i + 1) n1q = n1q + {3'd0, q_m[i]};
    end

    // ---- 步骤3 ----
    always @(*) begin
        if (cnt == 5'sd0 || n1q == 4'd4)
            q_next = {~q_m[8],  q_m[8],  q_m[7:0]};   // A
        else if ((cnt > 5'sd0 && n1q > 4'd4) || (cnt < 5'sd0 && n1q < 4'd4))
            q_next = { 1'b1,    q_m[8],  q_m[7:0]};   // B
        else
            q_next = { 1'b0,   ~q_m[8], ~q_m[7:0]};   // C
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dout <= 10'b0;
            cnt  <= 5'sd0;
        end else if (de) begin
            dout <= q_next;
            if (cnt == 5'sd0 || n1q == 4'd4)
                cnt <= cnt + (q_m[8] ? -bal : bal);
            else if ((cnt > 5'sd0 && n1q > 4'd4) || (cnt < 5'sd0 && n1q < 4'd4))
                cnt <= cnt + (q_m[8] ? -bal : bal);
            else
                cnt <= cnt + (q_m[8] ?  bal : -bal);
        end else begin
            // 控制期, 极性复位
            cnt  <= 5'sd0;
            case (ctl)
                2'b00:   dout <= 10'b1101010100;
                2'b01:   dout <= 10'b0010101011;
                2'b10:   dout <= 10'b0101010100;
                default: dout <= 10'b1010101011;
            endcase
        end
    end

endmodule
