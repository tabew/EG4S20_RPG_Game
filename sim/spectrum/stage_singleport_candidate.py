"""Stage an optional RAM inference candidate. Never edits production RTL.
The current native build uses the frozen production module, not this candidate.
"""
from pathlib import Path
import hashlib
ROOT=Path(__file__).resolve().parents[2]
source=(ROOT/'rtl/video/hdmi_tx.v').read_text(encoding='utf-8')
module='module audio_spectrum_fft'+source.split('module audio_spectrum_fft',1)[1]
old='''    always @(posedge clk) begin
        product <= mul_a * mul_b;
        if(sample_tick && rst_n) capture_mem[{capture_bank,capture_index}] <= pcm_sample;
        capture_q <= capture_mem[{copy_bank,copy_index}];
        if(state==COPY_WRITE) work_mem[bit_reverse(copy_index)] <=
            {{2{capture_q[15]}},capture_q,18'd0};
        else if(state==WRITE_A) work_mem[address_a] <= {sum_re[17:0],sum_im[17:0]};
        else if(state==WRITE_B) work_mem[address_b] <= {dif_re[17:0],dif_im[17:0]};
        if(state==SCAN_READ || state==SCAN_BIN) work_q <= work_mem[scan_index];
        else if(state==READ_B || state==LATCH_B) work_q <= work_mem[address_b];
        else work_q <= work_mem[address_a];
    end'''
new='''    // Optional inference candidate: addresses are selected before the RAM
    // access, exposing exactly one synchronous read and one write port.
    reg [7:0] work_read_addr, work_write_addr;
    reg [35:0] work_write_data;
    reg work_write_en;
    always @* begin
        work_read_addr=address_a;
        if(state==SCAN_READ || state==SCAN_BIN) work_read_addr=scan_index;
        else if(state==READ_B || state==LATCH_B) work_read_addr=address_b;
        work_write_en=1'b0;
        work_write_addr=address_a;
        work_write_data={sum_re[17:0],sum_im[17:0]};
        case(state)
            COPY_WRITE: begin
                work_write_en=1'b1;
                work_write_addr=bit_reverse(copy_index);
                work_write_data={{2{capture_q[15]}},capture_q,18'd0};
            end
            WRITE_A: begin
                work_write_en=1'b1;
                work_write_addr=address_a;
                work_write_data={sum_re[17:0],sum_im[17:0]};
            end
            WRITE_B: begin
                work_write_en=1'b1;
                work_write_addr=address_b;
                work_write_data={dif_re[17:0],dif_im[17:0]};
            end
            default: begin end
        endcase
    end
    always @(posedge clk) begin
        product <= mul_a * mul_b;
        if(sample_tick && rst_n) capture_mem[{capture_bank,capture_index}] <= pcm_sample;
        capture_q <= capture_mem[{copy_bank,copy_index}];
        if(work_write_en) work_mem[work_write_addr] <= work_write_data;
        work_q <= work_mem[work_read_addr];
    end'''
assert module.count(old)==1,'Production source differs: inspect before staging'
candidate='`timescale 1ns/1ps\n// STAGED ONLY. NOT IN THE NATIVE PROJECT. Compile without hdmi_tx.v.\n'+module.replace(old,new)
path=ROOT/'sim/spectrum/audio_spectrum_fft_singleport_candidate.v'
if path.exists(): raise SystemExit('Candidate exists: inspect before replacing')
path.write_text(candidate,encoding='utf-8')
print('Staged:',path)
print('Production module LF-normalized SHA256:',hashlib.sha256(module.encode('utf-8')).hexdigest())
print('Only RAM address/data mux structure changes; state, cycle timing and arithmetic preserved.')
