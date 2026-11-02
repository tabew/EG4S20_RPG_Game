`timescale 1ns/1ps
module tb_spectrum_ram_equivalence;
    reg clk=0;
    always #5 clk=~clk;
    reg rst_n=0, sample_tick=0;
    reg signed [15:0] pcm_sample=0;
    wire [63:0] reference_levels, candidate_levels;
    wire reference_valid, candidate_valid, reference_overflow, candidate_overflow;
    audio_spectrum_fft reference_dut(clk,rst_n,sample_tick,pcm_sample,reference_levels,reference_valid,reference_overflow);
    audio_spectrum_fft_candidate candidate_dut(clk,rst_n,sample_tick,pcm_sample,candidate_levels,candidate_valid,candidate_overflow);
    integer frame, n, bin_no, period, frames_seen=0, cycles=0;
    reg [31:0] noise_state=32'h2a71c9d3;
    real phase;
    initial begin
        repeat(4) @(negedge clk);
        rst_n=1;
        // Eight tones plus legacy cadence, DC and four muted zero blocks.
        for(frame=0;frame<17;frame=frame+1) begin
            case(frame)
                0: bin_no=1; 1: bin_no=2; 2: bin_no=3; 3: bin_no=6;
                4: bin_no=12; 5: bin_no=24; 6: bin_no=48; 7: bin_no=96;
                8: bin_no=96; 9: bin_no=1; 10: bin_no=24;
                default: bin_no=0;
            endcase
            period=(frame>=8 && frame<=10) ? 833 : 525;
            for(n=0;n<256;n=n+1) begin
                phase=6.283185307179586*bin_no*n/256.0;
                @(negedge clk); sample_tick=1;
                noise_state={noise_state[30:0],noise_state[31]^noise_state[21]^noise_state[1]^noise_state[0]};
                if(frame==11) pcm_sample=$signed(noise_state[15:0]) >>> 1;
                else if(frame==12) pcm_sample=32767;
                else if(frame>=13) pcm_sample=0;
                else pcm_sample=$rtoi(16000.0*$sin(phase));
                @(negedge clk); sample_tick=0;
                repeat(period-2) @(negedge clk);
            end
        end
        repeat(15000) @(negedge clk);
        if(frames_seen!=17) begin $display("FAIL missing frames %0d",frames_seen); $finish; end
        // Invalid cadence also compares sticky overflow behavior cycle exactly.
        for(n=0;n<1024;n=n+1) begin
            sample_tick=1; pcm_sample=n;
            @(negedge clk); sample_tick=0;
            @(negedge clk);
        end
        repeat(15000) @(negedge clk);
        if(reference_overflow!==1) begin $display("FAIL missing pathological overflow"); $finish; end
        rst_n=0;
        repeat(3) @(negedge clk);
        $display("PASS cycle-exact RAM equivalence: 17 valid-cadence frames, all 8 tones, random PCM, 525/833 cadence, DC, silence, overflow and reset; cycles=%0d",cycles);
        $finish;
    end
    always @(posedge clk) begin
        #1;
        cycles=cycles+1;
        if({reference_levels,reference_valid,reference_overflow} !== {candidate_levels,candidate_valid,candidate_overflow}) begin
            $display("FAIL public outputs differ cycle=%0d ref=%h/%b/%b cand=%h/%b/%b",cycles,reference_levels,reference_valid,reference_overflow,candidate_levels,candidate_valid,candidate_overflow);
            $finish;
        end
        if(reference_valid) frames_seen=frames_seen+1;
    end
endmodule
