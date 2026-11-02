"""Generate an isolated falling-edge SDRAM pin-register candidate; no shared RTL edits."""
from pathlib import Path
ROOT=Path(__file__).resolve().parents[3]
source=(ROOT/'rtl/common/key_debounce.v').read_text(encoding='utf-8')
start=source.index('// MEDIA_SDRAM_CONTROLLER_BEGIN')
end=source.index('// MEDIA_SDRAM_CONTROLLER_END',start)
controller='`timescale 1ns/1ps\n'+source[start:end]
def swap(old,new):
    global controller
    assert controller.count(old)==1, (old,controller.count(old))
    controller=controller.replace(old,new)
swap('// commands have 5ns setup and read data has 15ns before the next clk edge.',
     '// Falling-edge pin registers launch 15ns before the next PHY edge.\n// READ and STOP both reach SDRAM one PHY cycle later; capture ages add one.\n// CL3 read data still has 15ns before the next controller sampling edge.')
swap('// reset-free RAM port removes the 128-way memory mux from the 5ns PHY\n    // output path and permits block RAM inference without adding bus latency.',
     '// reset-free RAM port supplies the following beat to the falling-edge\n    // pin registers and permits block RAM inference.')
swap('    assign s_dq = dq_drive ? dq_out : 32\'bz;\n    EG_PHY_SDRAM_2M_32 memory (\n        .clk(phy_clk), .ras_n(s_ras_n), .cas_n(s_cas_n),\n        .we_n(s_we_n), .addr(s_addr), .ba(s_bank), .dq(s_dq),\n        .cs_n(1\'b0), .dm0(dqm[0]), .dm1(dqm[1]),\n        .dm2(dqm[2]), .dm3(dqm[3]), .cke(rst_n && state != S_BOOT)\n    );',
'''    // Register every memory-facing output together. With PHY at SYS+5ns,
    // falling-edge launch is 15ns before the following PHY rising edge.
    // Keep command, data, byte mask and output-enable in the same pipeline.
    reg phy_ras_n, phy_cas_n, phy_we_n, phy_cs_n, phy_cke;
    reg [10:0] phy_addr;
    reg [1:0] phy_bank;
    reg [3:0] phy_dqm;
    reg [31:0] phy_dq_out;
    reg phy_dq_drive;
    always @(negedge clk or negedge rst_n) begin
        if (!rst_n) begin
            phy_ras_n<=1; phy_cas_n<=1; phy_we_n<=1; phy_cs_n<=1;
            phy_cke<=0; phy_addr<=0; phy_bank<=0; phy_dqm<=4'b1111;
            phy_dq_out<=0; phy_dq_drive<=0;
        end else begin
            phy_ras_n<=s_ras_n; phy_cas_n<=s_cas_n; phy_we_n<=s_we_n;
            phy_cs_n<=0; phy_cke<=state!=S_BOOT;
            phy_addr<=s_addr; phy_bank<=s_bank; phy_dqm<=dqm;
            phy_dq_out<=dq_out; phy_dq_drive<=dq_drive;
        end
    end
    assign s_dq = phy_dq_drive ? phy_dq_out : 32'bz;
    EG_PHY_SDRAM_2M_32 memory (
        .clk(phy_clk), .ras_n(phy_ras_n), .cas_n(phy_cas_n),
        .we_n(phy_we_n), .addr(phy_addr), .ba(phy_bank), .dq(s_dq),
        .cs_n(phy_cs_n), .dm0(phy_dqm[0]), .dm1(phy_dqm[1]),
        .dm2(phy_dqm[2]), .dm3(phy_dqm[3]), .cke(phy_cke)
    );''')
swap('                    // SDRAM samples READ on the shifted PHY rising edge.\n                    // CL3 data arrives three memory edges later, then is sampled.\n                    if (age>=2 && age < {1\'b0,segment}+2) begin',
'''                    // Falling-edge pin registers defer READ by one PHY cycle.
                    // CL3 data therefore reaches the system capture one cycle later.
                    if (age>=3 && age < {1'b0,segment}+3) begin''')
swap('                        if (age == {1\'b0,segment}+1) begin',
     '                        if (age == {1\'b0,segment}+2) begin')
output=ROOT/'sim/sdram/audit/media_sdram_ctrl_negedge.stage.v'
assert not output.exists(), f'Refusing to overwrite {output}'
output.write_text(controller,encoding='utf-8')
print(output)
