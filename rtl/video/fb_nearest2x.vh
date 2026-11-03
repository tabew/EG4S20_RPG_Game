`timescale 1ns/1ps
// 320x240 最近邻到 640x480。源地址打包成 {行[8:0], 列[9:0]}。
// 640x480 不经过这里的状态机。完成脉冲一直压到最后一个放大像素被收下。
// 仿真用这一份。综合用的是 rpg_top.v 末尾的同名模块，两处逻辑要一起改。
module fb_nearest2x (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        half,
    input  wire        start,
    input  wire        in_valid,
    input  wire [18:0] in_addr,
    input  wire [23:0] in_data,
    input  wire        out_ready,
    input  wire        load_done_in,
    output wire        out_valid,
    output wire [18:0] out_addr,
    output wire [23:0] out_data,
    output wire        load_done_out
);
    reg        half_run;
    reg        phase_on;
    reg [1:0]  phase;
    reg [8:0]  sy;
    reg [9:0]  sx;
    reg [23:0] pix;
    reg        hold_valid;
    reg [8:0]  hold_sy;
    reg [9:0]  hold_sx;
    reg [23:0] hold_pix;
    reg        done_hold;

    wire [9:0]  sy2 = {sy, 1'b0};
    wire [10:0] sx2 = {sx, 1'b0};
    wire [18:0] base = {sy2, 9'b0} + {2'b0, sy2, 7'b0} + {8'b0, sx2};
    wire [18:0] step = (phase==2'd1) ? 19'd1 :
                       (phase==2'd2) ? 19'd640 :
                       (phase==2'd3) ? 19'd641 : 19'd0;
    wire accept = half_run && phase_on && out_ready;
    wire finishing = accept && (phase==2'd3);

    assign out_valid = half_run ? accept : in_valid;
    assign out_addr  = half_run ? (base + step) : in_addr;
    assign out_data  = half_run ? pix : in_data;
    assign load_done_out = half_run ? (done_hold && !phase_on && !hold_valid && !in_valid)
                                    : load_done_in;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            half_run<=1'b0; phase_on<=1'b0; phase<=2'd0;
            sy<=9'd0; sx<=10'd0; pix<=24'd0;
            hold_valid<=1'b0; hold_sy<=9'd0; hold_sx<=10'd0; hold_pix<=24'd0;
            done_hold<=1'b0;
        end else if (start) begin
            half_run<=half;
            phase_on<=1'b0; phase<=2'd0; hold_valid<=1'b0; done_hold<=1'b0;
        end else if (half_run) begin
            if (load_done_in) done_hold<=1'b1;
            if (finishing) begin
                phase<=2'd0;
                if (hold_valid) begin
                    sy<=hold_sy; sx<=hold_sx; pix<=hold_pix;
                    if (in_valid) begin
                        hold_sy<=in_addr[18:10];
                        hold_sx<=in_addr[9:0];
                        hold_pix<=in_data;
                    end else hold_valid<=1'b0;
                end else if (in_valid) begin
                    sy<=in_addr[18:10]; sx<=in_addr[9:0]; pix<=in_data;
                    phase_on<=1'b1;
                end else phase_on<=1'b0;
            end else if (accept) begin
                phase<=phase+2'd1;
                if (in_valid && !hold_valid) begin
                    hold_sy<=in_addr[18:10];
                    hold_sx<=in_addr[9:0];
                    hold_pix<=in_data;
                    hold_valid<=1'b1;
                end
            end else if (!phase_on && hold_valid) begin
                sy<=hold_sy; sx<=hold_sx; pix<=hold_pix;
                phase<=2'd0; phase_on<=1'b1;
                if (in_valid) begin
                    hold_sy<=in_addr[18:10];
                    hold_sx<=in_addr[9:0];
                    hold_pix<=in_data;
                end else hold_valid<=1'b0;
            end else if (!phase_on && in_valid) begin
                sy<=in_addr[18:10]; sx<=in_addr[9:0]; pix<=in_data;
                phase<=2'd0; phase_on<=1'b1;
            end
            if (done_hold && !phase_on && !hold_valid && !in_valid && !accept)
                done_hold<=1'b0;
        end
    end
endmodule
