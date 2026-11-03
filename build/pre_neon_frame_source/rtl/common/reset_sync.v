//=============================================================================
// reset_sync.v  —— 异步复位 / 同步释放
// 用途: 每个时钟域一个实例, 避免复位撤销时的亚稳态导致整机跑飞
//=============================================================================
`timescale 1ns/1ps
module reset_sync (
    input  wire clk,
    input  wire arst_n,     // 异步复位的原始信号(按键/上电), 低有效
    output wire rst_n       // 同步释放后的复位, 低有效
);

    reg [2:0] sync_q;

    always @(posedge clk or negedge arst_n) begin
        if (!arst_n)
            sync_q <= 3'b000;
        else
            sync_q <= {sync_q[1:0], 1'b1};
    end

    assign rst_n = sync_q[2];

endmodule
