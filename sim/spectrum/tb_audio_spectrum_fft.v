`timescale 1ns/1ps
module tb_audio_spectrum_fft;
    reg clk=0;
    always #5 clk=~clk;
    reg rst_n=0, sample_tick=0;
    reg signed [15:0] pcm_sample=0;
    wire [63:0] levels;
    wire frame_valid, overflow;
    audio_spectrum_fft dut(clk,rst_n,sample_tick,pcm_sample,levels,frame_valid,overflow);
    integer vectors, result_file, bin_file, status, count, block_no;
    integer period, do_reset, sample_value, sample_no, frames, cycle;
    reg [1023:0] input_path, result_path, bin_path;
    reg [63:0] previous_levels=0;
    reg previous_valid=0;
    initial begin
        if(!$value$plusargs("INPUT=%s",input_path)) input_path="sim/spectrum/vectors.txt";
        if(!$value$plusargs("RESULT=%s",result_path)) result_path="sim/spectrum/results.txt";
        if(!$value$plusargs("BINS=%s",bin_path)) bin_path="sim/spectrum/bins.txt";
        vectors=$fopen(input_path,"r"); result_file=$fopen(result_path,"w"); bin_file=$fopen(bin_path,"w");
        if(!vectors || !result_file || !bin_file) begin $display("FAIL opening files"); $finish; end
        frames=0; cycle=0;
        status=$fscanf(vectors,"%d\n",count);
        for(block_no=0;block_no<count;block_no=block_no+1) begin
            status=$fscanf(vectors,"%d %d\n",period,do_reset);
            if(do_reset) begin
                if(block_no!=0) repeat(20000) @(negedge clk);
                @(negedge clk); rst_n=0; sample_tick=0;
                repeat(4) @(negedge clk);
                rst_n=1;
            end
            for(sample_no=0;sample_no<256;sample_no=sample_no+1) begin
                status=$fscanf(vectors,"%d\n",sample_value);
                @(negedge clk); sample_tick=1; pcm_sample=sample_value;
                @(negedge clk); sample_tick=0;
                repeat(period-2) @(negedge clk);
            end
            // Before resetting, allow completion of the block just captured.
            // The extra 20k clocks are also used after the final input block.
            // Streaming runs use do_reset=0 and have no inter-block gap.
        end
        repeat(20000) @(negedge clk);
        if(frames!=count) $display("FAIL frame count got=%0d expected=%0d",frames,count);
        else $display("PASS frames=%0d cycles=%0d",frames,cycle);
        $fclose(vectors); $fclose(result_file); $fclose(bin_file); $finish;
    end
    always @(posedge clk) begin
        cycle=cycle+1;
        if(rst_n) begin
            if(frame_valid && previous_valid) $display("FAIL frame_valid wider than one clock");
            if(levels!==previous_levels && !frame_valid) $display("FAIL non-atomic levels update");
            previous_levels=levels; previous_valid=frame_valid;
        end else begin previous_levels=0; previous_valid=0; end
        if(rst_n && dut.state==15)
            $fwrite(bin_file,"%0d %0d %0d %0d\n",frames,dut.scan_index,$signed(dut.work_q[35:18]),$signed(dut.work_q[17:0]));
        if(rst_n && frame_valid) begin
            $fwrite(result_file,"%0d %016h %0d %0d\n",frames,levels,overflow,cycle);
            frames=frames+1;
        end
    end
endmodule
