`timescale 1ns/1ps

module tb_scale2;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst_n = 0;
    reg half = 0, start = 0, in_valid = 0, out_ready = 1, load_done_in = 0;
    reg [18:0] in_addr = 0;
    reg [23:0] in_data = 0;
    wire out_valid, load_done_out;
    wire [18:0] out_addr;
    wire [23:0] out_data;
    integer errors = 0;
    integer got = 0;
    reg [18:0] seen_addr [0:15];
    reg [23:0] seen_data [0:15];

    fb_nearest2x dut (
        .clk(clk), .rst_n(rst_n), .half(half), .start(start),
        .in_valid(in_valid), .in_addr(in_addr), .in_data(in_data),
        .out_ready(out_ready), .load_done_in(load_done_in),
        .out_valid(out_valid), .out_addr(out_addr), .out_data(out_data),
        .load_done_out(load_done_out)
    );

    always @(posedge clk) begin
        if (rst_n && out_valid) begin
            seen_addr[got] <= out_addr;
            seen_data[got] <= out_data;
            got <= got + 1;
        end
    end

    task pulse_start;
        begin
            @(negedge clk);
            start = 1;
            @(negedge clk);
            start = 0;
        end
    endtask

    task send_px;
        input [8:0] sy;
        input [9:0] sx;
        input [23:0] data;
        begin
            @(negedge clk);
            in_valid = 1;
            in_addr = {sy, sx};
            in_data = data;
            @(negedge clk);
            in_valid = 0;
        end
    endtask

    integer i;
    initial begin
        repeat (4) @(posedge clk);
        rst_n = 1;
        @(negedge clk);

        half = 0;
        pulse_start();
        got = 0;
        send_px(9'd1, 10'd2, 24'h010203);
        @(posedge clk);
        if (got != 1 || seen_addr[0] != {9'd1, 10'd2} || seen_data[0] != 24'h010203) begin
            $display("FAIL passthrough got=%0d addr=%0d data=%h", got, seen_addr[0], seen_data[0]);
            errors = errors + 1;
        end
        @(negedge clk);
        load_done_in = 1;
        @(posedge clk);
        if (!load_done_out) begin
            $display("FAIL passthrough done missing");
            errors = errors + 1;
        end
        @(negedge clk);
        load_done_in = 0;

        half = 1;
        pulse_start();
        got = 0;
        out_ready = 0;
        send_px(9'd3, 10'd5, 24'hAABBCC);
        repeat (3) @(posedge clk);
        if (got != 0) begin
            $display("FAIL emitted while stalled");
            errors = errors + 1;
        end
        @(negedge clk);
        out_ready = 1;
        load_done_in = 1;
        @(negedge clk);
        load_done_in = 0;
        while (got < 4) @(posedge clk);
        if (!load_done_out) begin
            $display("FAIL delayed done missing");
            errors = errors + 1;
        end
        for (i = 0; i < 4; i = i + 1) begin
            if (seen_data[i] != 24'hAABBCC) begin
                $display("FAIL data[%0d]=%h", i, seen_data[i]);
                errors = errors + 1;
            end
        end
        if (seen_addr[0] != 19'd3850 || seen_addr[1] != 19'd3851 ||
            seen_addr[2] != 19'd4490 || seen_addr[3] != 19'd4491) begin
            $display("FAIL addrs %0d %0d %0d %0d",
                     seen_addr[0], seen_addr[1], seen_addr[2], seen_addr[3]);
            errors = errors + 1;
        end
        half = 1;
        pulse_start();
        got = 0;
        send_px(9'd239, 10'd319, 24'hFFFFFF);
        while (got < 4) @(posedge clk);
        if (seen_addr[3] != 19'd307199) begin
            $display("FAIL corner addr %0d", seen_addr[3]);
            errors = errors + 1;
        end

        half = 1;
        pulse_start();
        got = 0;
        @(negedge clk);
        in_valid = 1; in_addr = {9'd0, 10'd0}; in_data = 24'h111111;
        @(negedge clk);
        in_valid = 1; in_addr = {9'd0, 10'd1}; in_data = 24'h222222;
        @(negedge clk);
        in_valid = 0;
        while (got < 8) @(posedge clk);
        if (seen_data[0] != 24'h111111 || seen_data[3] != 24'h111111 ||
            seen_data[4] != 24'h222222 || seen_addr[4] != 19'd2 ||
            seen_addr[5] != 19'd3) begin
            $display("FAIL queued pixel data %h %h %h addr %0d %0d",
                     seen_data[0], seen_data[3], seen_data[4], seen_addr[4], seen_addr[5]);
            errors = errors + 1;
        end

        if (errors == 0) $display("PASS 320x240 nearest expand");
        else $display("FAIL %0d scale checks", errors);
        $finish;
    end

    initial begin
        #100000;
        $display("FAIL scale watchdog got=%0d", got);
        $finish;
    end
endmodule
