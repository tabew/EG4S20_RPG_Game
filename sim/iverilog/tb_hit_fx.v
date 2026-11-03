`timescale 1ns/1ps
module tb_hit_fx;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst_n = 0, frame = 0, trig = 0;
    reg [1:0] kind = 0;
    reg [11:0] x = 0, y = 0;
    wire signed [4:0] jx, jy;
    wire hit;
    wire [15:0] rgb;
    integer errors = 0;

    hit_fx dut (
        .clk(clk), .rst_n(rst_n), .frame(frame), .trig(trig), .kind(kind),
        .x(x), .y(y), .jx(jx), .jy(jy), .hit(hit), .rgb(rgb)
    );

    task tick;
        begin
            @(negedge clk); frame = 1;
            @(negedge clk); frame = 0;
        end
    endtask

    task fire;
        input [1:0] k;
        begin
            @(negedge clk); kind = k; trig = 1;
            @(negedge clk); trig = 0;
        end
    endtask

    initial begin
        repeat (4) @(negedge clk);
        rst_n = 1;
        x = 12'd312; y = 12'd120;
        fire(2'd1);
        if (!hit || rgb !== 16'hFFFF || jx == 0) begin
            $display("FAIL player spawn hit=%b rgb=%h jx=%0d jy=%0d", hit, rgb, jx, jy);
            errors = errors + 1;
        end
        x = 12'd0; y = 12'd0;
        #1;
        if (hit) begin
            $display("FAIL particle at origin");
            errors = errors + 1;
        end
        tick();
        x = 12'd318; y = 12'd120;
        #1;
        if (!hit) begin
            $display("FAIL player spark did not move right");
            errors = errors + 1;
        end

        fire(2'd2);
        if (jx == 0 || jy == 0) begin
            $display("FAIL skill shake jx=%0d jy=%0d", jx, jy);
            errors = errors + 1;
        end

        fire(2'd3);
        if (!(jy > 0 && jx < 0)) begin
            $display("FAIL monster lunge jx=%0d jy=%0d", jx, jy);
            errors = errors + 1;
        end
        tick();
        x = 12'd305; y = 12'd126;
        #1;
        if (!hit || (rgb !== 16'hFFFF)) begin
            $display("FAIL monster spark hit=%b rgb=%h", hit, rgb);
            errors = errors + 1;
        end

        if (errors == 0) $display("PASS hit sparks and shake");
        else $display("FAIL %0d hit fx checks", errors);
        $finish;
    end
endmodule
