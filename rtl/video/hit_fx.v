//=============================================================================
// hit_fx.v —— 战斗打击：8 颗粒子 + 立绘抖动
//
//   kind 1 普攻：黄白火花向外炸，立绘左右抖
//   kind 2 技能：青/品红火花，立绘对角抖
//   kind 3 怪物反击：红火花朝左下飞，立绘先往下扑再收回
//   粒子坐标是 640x480 逻辑像素。调用方把命中延迟到和立绘同一级流水。
//=============================================================================
`timescale 1ns/1ps
module hit_fx (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        frame,       // 每帧一拍
    input  wire        trig,        // 单拍
    input  wire [1:0]  kind,
    input  wire [11:0] x,
    input  wire [11:0] y,
    output wire signed [4:0] jx,
    output wire signed [4:0] jy,
    output wire        hit,
    output wire [15:0] rgb
);
    localparam [9:0] CX = 10'd312;
    localparam [9:0] CY = 10'd120;

    reg [9:0] px [0:7];
    reg [9:0] py [0:7];
    reg signed [4:0] vx [0:7];
    reg signed [4:0] vy [0:7];
    reg [3:0] life;
    reg [1:0] kind_r;

    function signed [4:0] off_x;
        input [2:0] n;
        begin
            case (n)
                3'd1, 3'd4: off_x = 5'sd8;
                3'd2, 3'd5: off_x = -5'sd8;
                3'd6:       off_x = 5'sd5;
                3'd7:       off_x = -5'sd5;
                default:    off_x = 5'sd0;
            endcase
        end
    endfunction

    function signed [4:0] off_y;
        input [2:0] n;
        begin
            case (n)
                3'd3, 3'd4: off_y = 5'sd8;
                3'd5, 3'd6: off_y = -5'sd8;
                3'd7:       off_y = 5'sd5;
                default:    off_y = 5'sd0;
            endcase
        end
    endfunction

    function signed [4:0] vel_x;
        input [1:0] k;
        input [2:0] n;
        begin
            case (k)
                2'd2: case (n)
                    3'd0: vel_x = 5'sd8;  3'd1: vel_x = -5'sd8;
                    3'd2: vel_x = 5'sd3;  3'd3: vel_x = -5'sd3;
                    3'd4: vel_x = 5'sd7;  3'd5: vel_x = -5'sd7;
                    3'd6: vel_x = 5'sd2;  default: vel_x = -5'sd2;
                endcase
                2'd3: case (n[0])
                    1'b0: vel_x = -5'sd7;
                    default: vel_x = -5'sd5;
                endcase
                default: case (n)
                    3'd0: vel_x = 5'sd6;  3'd1: vel_x = -5'sd6;
                    3'd2: vel_x = 5'sd0;  3'd3: vel_x = 5'sd0;
                    3'd4: vel_x = 5'sd5;  3'd5: vel_x = -5'sd5;
                    3'd6: vel_x = 5'sd5;  default: vel_x = -5'sd5;
                endcase
            endcase
        end
    endfunction

    function signed [4:0] vel_y;
        input [1:0] k;
        input [2:0] n;
        begin
            case (k)
                2'd2: case (n)
                    3'd0: vel_y = -5'sd3; 3'd1: vel_y = 5'sd3;
                    3'd2: vel_y = 5'sd8;  3'd3: vel_y = -5'sd8;
                    3'd4: vel_y = 5'sd7;  3'd5: vel_y = -5'sd7;
                    3'd6: vel_y = 5'sd8;  default: vel_y = -5'sd8;
                endcase
                2'd3: case (n[1])
                    1'b0: vel_y = 5'sd6;
                    default: vel_y = 5'sd8;
                endcase
                default: case (n)
                    3'd0: vel_y = 5'sd0;  3'd1: vel_y = 5'sd0;
                    3'd2: vel_y = 5'sd6;  3'd3: vel_y = -5'sd6;
                    3'd4: vel_y = 5'sd5;  3'd5: vel_y = 5'sd5;
                    3'd6: vel_y = -5'sd5; default: vel_y = -5'sd5;
                endcase
            endcase
        end
    endfunction

    function [9:0] step_pos;
        input [9:0] p;
        input signed [4:0] v;
        input [9:0] lim;
        reg signed [11:0] s;
        begin
            s = $signed({2'b0, p}) + $signed(v);
            if (s <= 0)
                step_pos = 10'd0;
            else if (s >= $signed({2'b0, lim}))
                step_pos = lim;
            else
                step_pos = s[9:0];
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin : move
        integer i;
        if (!rst_n) begin
            life   <= 4'd0;
            kind_r <= 2'd0;
            for (i = 0; i < 8; i = i + 1) begin
                px[i] <= CX;
                py[i] <= CY;
                vx[i] <= 5'sd0;
                vy[i] <= 5'sd0;
            end
        end else if (trig) begin
            life   <= 4'd8;
            kind_r <= kind;
            for (i = 0; i < 8; i = i + 1) begin
                px[i] <= step_pos(CX, off_x(i[2:0]), 10'd639);
                py[i] <= step_pos(CY, off_y(i[2:0]), 10'd479);
                vx[i] <= vel_x(kind, i[2:0]);
                vy[i] <= vel_y(kind, i[2:0]);
            end
        end else if (frame && life != 4'd0) begin
            life <= life - 4'd1;
            for (i = 0; i < 8; i = i + 1) begin
                px[i] <= step_pos(px[i], vx[i], 10'd639);
                py[i] <= step_pos(py[i], vy[i], 10'd479);
            end
        end
    end

    reg signed [4:0] jx_c, jy_c;
    always @(*) begin
        jx_c = 5'sd0;
        jy_c = 5'sd0;
        if (life != 4'd0) begin
            case (kind_r)
                2'd2: begin
                    jx_c = life[1] ? 5'sd6 : -5'sd6;
                    jy_c = life[0] ? -5'sd6 : 5'sd6;
                end
                2'd3: begin
                    if (life > 4'd4) begin
                        jx_c = -5'sd6;
                        jy_c = 5'sd8;
                    end else begin
                        jx_c = 5'sd3;
                        jy_c = -5'sd3;
                    end
                end
                default: begin
                    jx_c = life[0] ? 5'sd8 : -5'sd8;
                    jy_c = life[0] ? -5'sd3 : 5'sd3;
                end
            endcase
        end
    end
    assign jx = jx_c;
    assign jy = jy_c;

    function [15:0] spark;
        input [1:0] k;
        input [3:0] lf;
        input [2:0] n;
        begin
            if (lf > 4'd5)
                spark = 16'hFFFF;
            else case (k)
                2'd2: spark = n[0] ? 16'h07FF : 16'hF81F;
                2'd3: spark = n[0] ? 16'hF800 : 16'hFD20;
                default: spark = n[0] ? 16'hFFE0 : 16'hFD20;
            endcase
        end
    endfunction

    reg        hit_c;
    reg [15:0] rgb_c;
    reg [2:0]  which;
    always @(*) begin : pick
        integer i;
        reg signed [12:0] dx, dy;
        hit_c = 1'b0;
        rgb_c = 16'h0000;
        which = 3'd0;
        if (life != 4'd0) begin
            for (i = 0; i < 8; i = i + 1) begin
                dx = $signed({1'b0, x}) - $signed({3'b0, px[i]});
                dy = $signed({1'b0, y}) - $signed({3'b0, py[i]});
                if (!hit_c && dx >= -13'sd2 && dx <= 13'sd2 &&
                    dy >= -13'sd2 && dy <= 13'sd2) begin
                    hit_c = 1'b1;
                    which = i[2:0];
                end
            end
            rgb_c = spark(kind_r, life, which);
        end
    end
    assign hit = hit_c;
    assign rgb = rgb_c;

endmodule
