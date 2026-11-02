`timescale 1ns/1ps
module tb_spectrum_overflow;
    reg clk=0;
    always #5 clk=~clk;
    reg rst_n=0, sample_tick=0;
    reg signed [15:0] pcm_sample=0;
    wire [63:0] levels;
    wire frame_valid, overflow;
    audio_spectrum_fft dut(clk,rst_n,sample_tick,pcm_sample,levels,frame_valid,overflow);
    integer n;
    initial begin
        repeat(4) @(negedge clk);
        rst_n=1;
        // Deliberately impossible cadence: no time to finish an FFT block.
        for(n=0;n<1024;n=n+1) begin
            sample_tick=1; pcm_sample=n;
            @(negedge clk); sample_tick=0;
            @(negedge clk);
        end
        repeat(10) @(negedge clk);
        if(overflow!==1'b1) begin $display("FAIL missing overflow"); $finish; end
        repeat(15000) @(negedge clk);
        if(overflow!==1'b1) begin $display("FAIL overflow not sticky"); $finish; end
        rst_n=0;
        repeat(2) @(negedge clk);
        if(overflow!==0 || levels!==0 || frame_valid!==0) $display("FAIL reset outputs");
        else $display("PASS impossible cadence raises sticky overflow; reset clears outputs");
        $finish;
    end
endmodule
