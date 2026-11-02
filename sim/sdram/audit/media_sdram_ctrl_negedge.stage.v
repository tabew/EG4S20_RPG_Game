`timescale 1ns/1ps
// MEDIA_SDRAM_CONTROLLER_BEGIN
// Burst controller for the EG4S20 internal 2M x32 SDR SDRAM primitive.
// Address: {bank[1:0], row[10:0], column[7:0]} in 32-bit WORDS.
// One request is 1..128 consecutive words. Writes are buffered completely
// before ACTIVATE; producer stalls cannot interrupt an SDRAM write burst.
// Reads are irrevocable: the receiver MUST reserve cmd_len output words.
// cmd_ready accepts one request; rd_last marks its final word. busy remains
// asserted through recovery/precharge. Only one outstanding command is allowed.
// 50 MHz defaults: 200 us startup, CL3, full-page sequential burst, explicit
// BURST TERMINATE, tRCD/tRP/tWR=40ns, tRFC=100ns, tMRD=40ns. Timing parameters
// are deliberately exposed for signoff against the actual embedded die grade.
// Timing source: Etron EM638325 Industrial Rev3.2 table16 / power-up note11.
// Worst grade: tRCD/tRP21ns, tRFC63ns, tRAS42ns, tWR/tMRD2 clocks,
// tAC(CL3)5.4ns, tIS1.5ns, tIH1ns; tREFI15.6us. Defaults include margin.
// phy_clk is the PLL 50MHz output shifted +90 degrees relative to clk:
// Falling-edge pin registers launch 15ns before the next PHY edge.
// READ and STOP both reach SDRAM one PHY cycle later; capture ages add one.
// CL3 read data still has 15ns before the next controller sampling edge.
// Power-up keeps CKE low and DQM high for the complete 200us interval.
module media_sdram_ctrl #(
    parameter integer INIT_CYCLES = 10000,
    parameter integer REFRESH_CYCLES = 250,
    parameter integer T_RCD = 2,
    parameter integer T_RP = 2,
    parameter integer T_RFC = 5,
    parameter integer T_WR = 2,
    parameter integer T_MRD = 2
)(
    input wire clk, input wire phy_clk, input wire rst_n,
    output reg init_done,
    input wire cmd_valid, output wire cmd_ready,
    input wire cmd_write, input wire [20:0] cmd_addr,
    input wire [7:0] cmd_len,
    input wire wr_valid, output wire wr_ready,
    input wire [31:0] wr_data, input wire [3:0] wr_strb,
    output reg rd_valid, output reg [31:0] rd_data,
    output reg rd_last, output reg wr_done, output wire busy
);
    localparam [4:0] S_BOOT=0, S_INIT_PRE=1, S_WAIT=2,
        S_INIT_REF=3, S_MRS=4, S_IDLE=5, S_ACT=6,
        S_READ=7, S_READ_RUN=8, S_WRITE=9, S_WRITE_RUN=10,
        S_STOP_WRITE=11, S_PRE=12, S_NEXT=13, S_REFRESH=14;
    reg [4:0] state, wait_next;
    reg [15:0] timer;
    reg [15:0] refresh_age;
    reg [3:0] init_refs;
    reg pending, request_write;
    reg [20:0] address;
    reg [7:0] length, collected, remaining, offset, segment;
    reg [8:0] age;
    reg [31:0] write_buffer [0:127];
    reg [3:0] strobe_buffer [0:127];
    reg [31:0] write_q;
    reg [3:0] mask_q;
    // Read the following beat before the FSM advances. This synchronous,
    // reset-free RAM port supplies the following beat to the falling-edge
    // pin registers and permits block RAM inference.
    wire [6:0] write_read_index = (state == S_WRITE) ? offset[6:0]+7'd1 :
        (state == S_WRITE_RUN) ? offset[6:0]+age[6:0]+7'd1 : offset[6:0];
    always @(posedge clk) begin
        write_q <= write_buffer[write_read_index];
        mask_q <= strobe_buffer[write_read_index];
        if (rst_n && wr_valid && wr_ready) begin
            write_buffer[collected[6:0]] <= wr_data;
            strobe_buffer[collected[6:0]] <= wr_strb;
        end
    end
    wire refresh_due = refresh_age >= REFRESH_CYCLES-1;
    assign cmd_ready = init_done && state == S_IDLE && !pending && !refresh_due;
    assign wr_ready = pending && request_write && collected < length;
    assign busy = !init_done || pending || state != S_IDLE;

    reg s_ras_n, s_cas_n, s_we_n;
    reg [10:0] s_addr;
    wire [1:0] s_bank = address[20:19];
    wire [31:0] s_dq;
    reg dq_drive;
    reg [31:0] dq_out;
    reg [3:0] dqm;
    // Register every memory-facing output together. With PHY at SYS+5ns,
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
    );
    always @* begin
        s_ras_n=1'b1; s_cas_n=1'b1; s_we_n=1'b1;
        s_addr=11'd0; dq_drive=1'b0; dq_out=32'd0; dqm=init_done ? 4'b0000 : 4'b1111;
        case (state)
            S_INIT_PRE, S_PRE: begin
                s_ras_n=0; s_we_n=0; s_addr[10]=1;
            end
            S_INIT_REF, S_REFRESH: begin s_ras_n=0; s_cas_n=0; end
            S_MRS: begin
                s_ras_n=0; s_cas_n=0; s_we_n=0;
                s_addr=11'h037; // sequential full page, CAS3, burst writes
            end
            S_ACT: begin s_ras_n=0; s_addr=address[18:8]; end
            S_READ: begin s_cas_n=0; s_addr={3'b000,address[7:0]}; end
            S_READ_RUN: begin
                // A read BURST TERMINATE takes effect after the CAS pipeline.
                if (age == {1'b0,segment}-1) s_we_n=0;
            end
            S_WRITE: begin
                s_cas_n=0; s_we_n=0; s_addr={3'b000,address[7:0]};
                dq_drive=1; dq_out=write_q;
                dqm=~mask_q;
            end
            S_WRITE_RUN: begin
                dq_drive=1; dq_out=write_q;
                dqm=~mask_q;
            end
            S_STOP_WRITE: s_we_n=0;
            default: begin end
        endcase
    end
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state<=S_BOOT; wait_next<=S_IDLE; timer<=0;
            init_done<=0; init_refs<=0; refresh_age<=0;
            pending<=0; request_write<=0; address<=0; length<=0;
            collected<=0; remaining<=0; offset<=0; segment<=0; age<=0;
            rd_valid<=0; rd_data<=0; rd_last<=0; wr_done<=0;
        end else begin
            rd_valid<=0; rd_last<=0; wr_done<=0;
            if (init_done && refresh_age != 16'hffff) refresh_age<=refresh_age+1'b1;
            if (cmd_valid && cmd_ready) begin
                pending<=1; request_write<=cmd_write; address<=cmd_addr;
                length<=cmd_len; remaining<=cmd_len; offset<=0; collected<=0;
            end
            if (wr_valid && wr_ready) begin
                collected<=collected+1'b1;
            end
            case (state)
                S_BOOT: begin
                    if (timer == INIT_CYCLES-1) begin state<=S_INIT_PRE; timer<=0; end
                    else timer<=timer+1'b1;
                end
                S_INIT_PRE: begin
                    timer<=T_RP-1; wait_next<=S_INIT_REF; state<=S_WAIT;
                end
                S_INIT_REF: begin
                    init_refs<=init_refs+1'b1; timer<=T_RFC-1; state<=S_WAIT;
                    if (init_refs == 7) wait_next<=S_MRS;
                    else wait_next<=S_INIT_REF;
                end
                S_MRS: begin timer<=T_MRD-1; wait_next<=S_IDLE; state<=S_WAIT; end
                S_WAIT: begin
                    if (timer==0) begin
                        state<=wait_next;
                        if (wait_next==S_IDLE && !init_done) begin
                            init_done<=1; refresh_age<=0;
                        end
                    end else timer<=timer-1'b1;
                end
                S_IDLE: begin
                    // Refresh also runs while an arbitrarily slow writer fills
                    // its private buffer; the SDRAM is closed and available.
                    if (refresh_due) state<=S_REFRESH;
                    else if (pending && (!request_write || collected==length)) begin
                        if ({1'b0,address[7:0]}+{1'b0,remaining} > 9'd256)
                            segment<=9'd256-{1'b0,address[7:0]};
                        else segment<=remaining;
                        state<=S_ACT;
                    end
                end
                S_ACT: begin
                    timer<=T_RCD-1; state<=S_WAIT;
                    wait_next<=request_write ? S_WRITE : S_READ;
                end
                S_READ: begin age<=0; state<=S_READ_RUN; end
                S_READ_RUN: begin
                    age<=age+1'b1;
                    // Falling-edge pin registers defer READ by one PHY cycle.
                    // CL3 data therefore reaches the system capture one cycle later.
                    if (age>=3 && age < {1'b0,segment}+3) begin
                        rd_data<=s_dq; rd_valid<=1;
                        if (age == {1'b0,segment}+2) begin
                            rd_last<=remaining==segment;
                            state<=S_PRE;
                        end
                    end
                end
                S_WRITE: begin
                    age<=1;
                    if (segment==1) state<=S_STOP_WRITE;
                    else state<=S_WRITE_RUN;
                end
                S_WRITE_RUN: begin
                    age<=age+1'b1;
                    if (age=={1'b0,segment}-1) state<=S_STOP_WRITE;
                end
                S_STOP_WRITE: begin
                    timer<=T_WR-1; wait_next<=S_PRE; state<=S_WAIT;
                end
                S_PRE: begin timer<=T_RP-1; wait_next<=S_NEXT; state<=S_WAIT; end
                S_NEXT: begin
                    if (remaining==segment) begin
                        pending<=0; state<=S_IDLE;
                        if (request_write) wr_done<=1;
                    end
                    else begin
                        remaining<=remaining-segment;
                        address<=address+segment; offset<=offset+segment;
                        state<=S_IDLE;
                    end
                end
                S_REFRESH: begin
                    refresh_age<=0; timer<=T_RFC-1;
                    wait_next<=S_IDLE; state<=S_WAIT;
                end
                default: state<=S_BOOT;
            endcase
        end
    end
endmodule

