#!/usr/bin/env python3
"""Exercise the production broker's base decode/vblank/cancel protocol."""
from verify_sd_rtl import ROOT,SIM,find_tool,execute
OUT=SIM/'out/frame_publication'
def main():
 OUT.mkdir(parents=True,exist_ok=True)
 wrapper='''`timescale 1ns/1ps
module publication_dut(input clk_mem50,rst_n50,fb_start,fb_frame_done,fb_frame_ok,sd_load_done,tf_valid50,fb_s_front_valid,sd_load_go,sd_cancel_go,sd_load_cancelled,
 input[1:0]tf_err50,input[5:0]sd_shown_index,input[63:0]sd_shown_name,
 output wire fb_frame_end,fb_frame_abort,publication_pending,published_valid,published_done,
 output wire[1:0]published_error,output wire[5:0]published_index,output wire[63:0]published_name);
 media_frame_cache #(.ENABLE_CACHE(0)) actual(
 .clk(clk_mem50),.rst_n(rst_n50),.request_go(sd_load_go),.request_index(sd_shown_index),.cancel_go(sd_cancel_go),
 .cat_ready(1'b1),.raw_busy(1'b0),.raw_done(sd_load_done),.raw_cancelled(sd_load_cancelled),
 .raw_valid(tf_valid50),.raw_error(tf_err50),.raw_index(sd_shown_index),.raw_name(sd_shown_name),
 .frame_begin(fb_start),.frame_done(fb_frame_done),.frame_ok(fb_frame_ok),.front_valid(fb_s_front_valid),.front_bank(2'b00),
 .decode_go(),.decode_index(),.write_bank(),.swap_only(),.swap_bank(),
 .frame_end(fb_frame_end),.frame_abort(fb_frame_abort),.publication_pending(publication_pending),.transaction_busy(),
 .published_valid(published_valid),.published_done(published_done),.published_error(published_error),
 .published_index(published_index),.published_name(published_name),.cache_hits(),.cache_misses());
endmodule
'''
 dut=OUT/'publication_dut.v';dut.write_text(wrapper,encoding='utf-8')
 exe=OUT/'publication.vvp';rc,log=execute([find_tool('iverilog'),'-g2001','-s','tb_frame_publication','-o',exe,ROOT/'sim/sdram/tb_frame_publication.v',dut,ROOT/'rtl/rpg_top.v'])
 if not rc:rc,log=execute([find_tool('vvp'),exe])
 (OUT/'simulation.log').write_text(log,encoding='utf-8');print(log)
 return rc if rc else(0 if 'PASS frame_publication'in log else 1)
if __name__=='__main__':raise SystemExit(main())
