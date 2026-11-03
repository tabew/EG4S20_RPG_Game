`timescale 1ns/1ps
// Probe mon_layer directly: which source pixel does rotation 0 fetch?
module tb_mon_probe;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst_n = 0;
    reg [1:0] rotation = 0;
    reg mirror = 0;
    reg [11:0] x = 0, y = 0;
    wire in_win, valid;
    wire [15:0] rgb;

    mon_layer dut (
        .clk(clk), .rst_n(rst_n), .mon_id(5'd1), .fade(4'd8),
        .rotation(rotation), .mirror(mirror),
        .jx(5'sd0), .jy(5'sd0),
        .x(x), .y(y), .in_win(in_win), .rgb(rgb), .valid(valid)
    );

    integer i, nz;
    initial begin
        repeat (8) @(posedge clk);
        rst_n = 1;
        repeat (200) @(posedge clk);

        for (rotation = 0; rotation < 2; rotation = rotation + 1) begin
            repeat (200) @(posedge clk);
            nz = 0;
            // Sample the centre of the window and count non-black pixels.
            for (i = 0; i < 144; i = i + 1) begin
                @(posedge clk);
                x = 12'd240 + i[11:0]; y = 12'd48 + 12'd72;
                @(posedge clk);
                if (valid && rgb != 16'd0) nz = nz + 1;
            end
            $display("rotation %0d: non-black pixels in centre row = %0d", rotation, nz);
        end

        // Dump the inverse-mapped source coordinate for a few pixels.
        rotation = 0;
        x = 12'd240; y = 12'd48;
        repeat (3) @(posedge clk);
        $display("corner: u=%0d v=%0d maddr=%0d", dut.u, dut.v, dut.maddr);
        x = 12'd250; y = 12'd60;
        repeat (3) @(posedge clk);
        $display("mid   : u=%0d v=%0d maddr=%0d", dut.u, dut.v, dut.maddr);
        $finish;
    end
endmodule