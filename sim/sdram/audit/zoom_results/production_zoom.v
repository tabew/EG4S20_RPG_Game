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

// MEDIA_SDRAM_CONTROLLER_END

// MEDIA_FRAMEBUFFER_BEGIN
`timescale 1ns/1ps
// Full 640x480 RGB888 framebuffer. SDRAM holds one zero-padded RGB per word.
// Bank addresses: {bank[1:0], pixel[18:0]}; four full-image 2MiB slots.
// Legacy mode alternates slots 0/1. Cache mode writes the requested slot and
// swap_only selects an already complete slot without accepting source pixels.
// frame_begin/end/abort and pixel writes are synchronous to sclk. frame_done
// acknowledges either abort completion or the pclk acknowledgement of a swap.
// A successful source must deliver exactly 307200 in-range pixels. The producer
// may send ascending pixels within descending BMP rows. It must honor ready;
// any valid without ready aborts that back frame and preserves the front.
// Reset both domains together. Independent resets require a fresh frame_begin.
module media_framebuffer (
    input wire sclk, input wire phy_clk, input wire srst_n, input wire pclk, input wire prst_n,
    input wire frame_begin, input wire pixel_wr_valid,
    input wire [18:0] pixel_wr_addr, input wire [23:0] pixel_wr_data,
    output wire pixel_wr_ready, input wire frame_end, input wire frame_abort,
    output wire s_ready, output reg frame_done, output reg frame_ok,
    output wire s_front_valid, output wire busy, output reg [3:0] error_flags,
    input wire frame_tick, input wire pixel_req,
    output wire [23:0] pixel_rgb, output reg pixel_valid,
    output wire front_valid, output reg underrun,
    input wire cache_mode, input wire [1:0] write_bank,
    input wire swap_only, input wire [1:0] swap_bank,
    output wire [1:0] s_front_bank,
    input wire [1:0] view_mode, output wire [1:0] view_active
);
    localparam [3:0] IDLE=0, BUILD_FETCH=1, BUILD_HAVE=2, CMD_WRITE=3,
        WRITE_FETCH=4, WRITE_SEND=5, WRITE_WAIT=6, CMD_READ=7,
        READ_WAIT=8, READ_RECOVER=9, READ_PREP=10, READ_ADDR=11;
    localparam [1:0] E_RUN=0, E_WAIT=1, E_CLEAR=2, E_RETURN=3;
    reg [3:0] state;
    reg [1:0] epoch_state;
    reg [2:0] clear_count;
    reg loading, end_pending, abort_pending, commit_pending;
    reg [1:0] front_bank, active_write_bank, candidate_bank;
    reg front_live, swap_waiting;
    // An omitted port in legacy named-port instantiations disables caching.
    wire cache_enabled = cache_mode === 1'b1;
    reg [18:0] source_count, fetch_addr;
    // Full original banks remain unchanged. Queue sourceWidth words for each
    // output row, including repeated rows; only horizontal repeats use holding.
    reg [8:0] fetch_row;
    reg [9:0] fetch_col;
    reg [18:0] read_row_base, read_address;
    reg [1:0] mode_payload_p, active_mode_s, active_mode_p;
    reg [1:0] repeat_phase;
    reg have_pixel;
    wire [9:0] source_width = active_mode_s==2 ? 10'd160 :
                              active_mode_s==1 ? 10'd320 : 10'd640;
    wire [8:0] crop_y = active_mode_s==2 ? 9'd180 :
                         active_mode_s==1 ? 9'd120 : 9'd0;
    wire [9:0] crop_x = active_mode_s==2 ? 10'd240 :
                         active_mode_s==1 ? 10'd160 : 10'd0;
    wire [8:0] source_y = crop_y + (fetch_row >> active_mode_s);
    wire [9:0] row_remaining = source_width-fetch_col;
    wire [7:0] read_length = row_remaining>=128 ? 8'd128 : row_remaining[7:0];
    wire [18:0] frame_words = active_mode_s==2 ? 19'd76800 :
                              active_mode_s==1 ? 19'd153600 : 19'd307200;
    wire [1:0] repeat_last = active_mode_p==2 ? 2'd3 :
                             active_mode_p==1 ? 2'd1 : 2'd0;
    assign view_active = active_mode_p;
    reg [42:0] source_mem [0:127];
    reg [6:0] source_wptr, source_rptr;
    reg [7:0] source_used;
    reg [42:0] source_head;
    reg [23:0] burst_mem [0:15];
    reg [23:0] burst_data;
    reg [18:0] burst_addr;
    reg [4:0] burst_count;
    reg [3:0] burst_index;
    wire head_matches = burst_count==0 || source_head[42:24]==burst_addr+burst_count;
    wire source_push = pixel_wr_valid && pixel_wr_ready;
    wire source_pop = state==BUILD_HAVE && head_matches && !abort_pending && !frame_abort;
    assign pixel_wr_ready = s_ready && loading && !end_pending &&
        !abort_pending && !frame_abort && source_used<128;
    assign busy = loading || !s_ready;
    assign s_front_valid = front_live;
    assign s_front_bank = front_bank;

    reg p_epoch, p_return, p_wait, p_gate, p_front, p_bad, p_show;
    (* async_reg = "true" *) reg epoch_meta, epoch_sync;
    (* async_reg = "true" *) reg return_meta, return_sync;
    reg epoch_seen, s_ack;
    (* async_reg = "true" *) reg ack_meta, ack_sync;
    (* async_reg = "true" *) reg front_meta, front_sync;
    wire epoch_changed = epoch_sync != epoch_seen;
    wire epoch_readable = (epoch_state==E_RUN || epoch_state==E_RETURN) && !epoch_changed;

    wire cmd_ready, ctrl_busy, ctrl_wr_ready, ctrl_wr_done;
    wire ctrl_rd_valid, ctrl_rd_last;
    wire [31:0] ctrl_rd_data;
    wire cmd_valid = (state==CMD_WRITE || state==CMD_READ) &&
        epoch_state!=E_CLEAR;
    wire cmd_write = state==CMD_WRITE;
    wire [20:0] cmd_addr = cmd_write ? {active_write_bank, burst_addr} :
                                                     {front_bank, read_address};
    wire [7:0] cmd_len = cmd_write ? {3'd0,burst_count} : read_length;
    media_sdram_ctrl controller (
        .clk(sclk), .phy_clk(phy_clk), .rst_n(srst_n), .init_done(s_ready),
        .cmd_valid(cmd_valid), .cmd_ready(cmd_ready), .cmd_write(cmd_write),
        .cmd_addr(cmd_addr), .cmd_len(cmd_len),
        .wr_valid(state==WRITE_SEND), .wr_ready(ctrl_wr_ready),
        .wr_data({8'd0,burst_data}), .wr_strb(4'b1111), .wr_done(ctrl_wr_done),
        .rd_valid(ctrl_rd_valid), .rd_data(ctrl_rd_data), .rd_last(ctrl_rd_last),
        .busy(ctrl_busy)
    );

    wire video_full, video_empty, video_rvalid;
    wire [11:0] video_used;
    wire [23:0] video_data;
    wire video_write = ctrl_rd_valid && state==READ_WAIT && epoch_readable;
    wire output_request = pixel_req && p_gate && p_front && !p_wait && !frame_tick;
    wire need_new_pixel = repeat_phase==0;
    wire video_read = output_request && need_new_pixel && !video_empty;
    wire output_usable = output_request && (need_new_pixel ? !video_empty : have_pixel);
    media_async_fifo #(.WIDTH(24), .ADDR_BITS(11)) video_fifo (
        .wclk(sclk), .wrst_n(srst_n), .wclear(epoch_state==E_CLEAR),
        .w_en(video_write), .w_data(ctrl_rd_data[23:0]),
        .w_full(video_full), .w_level(video_used),
        .rclk(pclk), .rrst_n(prst_n), .rclear(p_wait),
        .r_en(video_read), .r_data(video_data), .r_valid(video_rvalid),
        .r_empty(video_empty)
    );
    assign pixel_rgb = p_show ? video_data : 24'd0;
    assign front_valid = p_front;

    // Gray-pointer FIFO read is synchronous: request S2 -> registered data S3.
    // On underrun, consume any subsequently available pixels but hide the rest
    // of this frame. The next blank epoch discards all residual FIFO contents.
    always @(posedge pclk or negedge prst_n) begin
        if (!prst_n) begin
            p_epoch<=0; p_return<=0; p_wait<=0; p_gate<=0;
            p_front<=0; p_bad<=0; p_show<=0; pixel_valid<=0; underrun<=0;
            ack_meta<=0; ack_sync<=0; front_meta<=0; front_sync<=0;
            mode_payload_p<=0; active_mode_p<=0; repeat_phase<=0; have_pixel<=0;
        end else begin
            ack_meta<=s_ack; ack_sync<=ack_meta;
            front_meta<=front_live; front_sync<=front_meta;
            p_show<=output_usable && !p_bad;
            pixel_valid<=output_usable && !p_bad;
            if (output_request) begin
                if (repeat_phase==repeat_last) repeat_phase<=0;
                else repeat_phase<=repeat_phase+1'b1;
            end
            if (video_read) have_pixel<=1;
            if (frame_tick) begin
                p_epoch<=!p_epoch; p_wait<=1; p_gate<=0;
                p_bad<=0; underrun<=0; p_show<=0; pixel_valid<=0;
                repeat_phase<=0; have_pixel<=0;
                // Case default also sanitizes unconnected X/Z legacy inputs.
                case (view_mode)
                    2'd1: mode_payload_p<=2'd1;
                    2'd2: mode_payload_p<=2'd2;
                    default: mode_payload_p<=2'd0;
                endcase
            end else if (p_wait && ack_sync==p_epoch) begin
                p_wait<=0; p_gate<=1; p_front<=front_sync; p_return<=ack_sync;
                active_mode_p<=mode_payload_p;
            end else if (output_request && need_new_pixel && video_empty) begin
                p_bad<=1; underrun<=1; p_show<=0; pixel_valid<=0;
            end
        end
    end

    // Read registers have no reset, allowing inference of embedded RAM ports.
    // Their consumers run only after the corresponding synchronous fetch.
    always @(posedge sclk) begin
        if (state==BUILD_FETCH && source_used!=0) source_head<=source_mem[source_rptr];
        if (state==WRITE_FETCH) burst_data<=burst_mem[burst_index];
    end

    // RAM reads stay in clocked statements; no combinational multi-entry scan.
    // Gather at most16 consecutive addresses before issuing a write command.
    // The controller owns a second payload buffer and accepts producer gaps.
    always @(posedge sclk or negedge srst_n) begin
        if (!srst_n) begin
            state<=IDLE; epoch_state<=E_RUN; clear_count<=0;
            loading<=0; end_pending<=0; abort_pending<=0; commit_pending<=0;
            front_bank<=0; active_write_bank<=0; candidate_bank<=0;
            front_live<=0; swap_waiting<=0;
            source_count<=0; fetch_addr<=0; source_wptr<=0; source_rptr<=0;
            fetch_row<=0; fetch_col<=0; read_row_base<=0; read_address<=0;
            active_mode_s<=0;
            source_used<=0;
            burst_addr<=0; burst_count<=0; burst_index<=0;
            epoch_meta<=0; epoch_sync<=0; return_meta<=0; return_sync<=0;
            epoch_seen<=0; s_ack<=0;
            frame_done<=0; frame_ok<=0; error_flags<=0;
        end else begin
            epoch_meta<=p_epoch; epoch_sync<=epoch_meta;
            return_meta<=p_return; return_sync<=return_meta;
            frame_done<=0;
            if (source_push) begin
                source_mem[source_wptr]<={pixel_wr_addr,pixel_wr_data};
                source_wptr<=source_wptr+1'b1;
                source_count<=source_count+1'b1;
                if (pixel_wr_addr>=307200 || source_count>=307200) begin
                    error_flags[1]<=1; abort_pending<=1;
                end
            end
            if (source_pop) source_rptr<=source_rptr+1'b1;
            case ({source_push,source_pop})
                2'b10: source_used<=source_used+1'b1;
                2'b01: source_used<=source_used-1'b1;
                default: begin end
            endcase
            if (frame_begin) begin
                if (!loading && !swap_waiting && s_ready) begin
                    loading<=1; end_pending<=0; abort_pending<=0; commit_pending<=0;
                    active_write_bank<=cache_enabled ? write_bank : {1'b0,!front_bank[0]};
                    source_count<=0; error_flags<=0;
                end else begin error_flags[0]<=1; if (loading) abort_pending<=1; end
            end else if (swap_only && cache_enabled && !frame_abort) begin
                if (!loading && !swap_waiting && s_ready) begin
                    // Reserve the load slot without opening the pixel producer.
                    // Existing reads may finish; the epoch drains them before
                    // selecting the cached bank and resetting the video FIFO.
                    loading<=1; end_pending<=1; abort_pending<=0;
                    commit_pending<=1; candidate_bank<=swap_bank;
                    source_count<=0; error_flags<=0;
                end else error_flags[0]<=1;
            end
            if (pixel_wr_valid && !pixel_wr_ready && loading) begin
                error_flags[0]<=1; abort_pending<=1;
            end
            if (frame_end && loading) end_pending<=1;
            // Also acknowledge decoder/header failure before frame_begin.
            if (frame_abort) begin error_flags[2]<=1; abort_pending<=1; end
            if (video_write && video_full) error_flags[3]<=1;

            // An epoch invalidates in-flight read results immediately. Its bus
            // command still finishes normally before either FIFO pointer clears.
            if (epoch_changed && epoch_state==E_RUN) begin
                epoch_seen<=epoch_sync; epoch_state<=E_WAIT;
            end
            if (epoch_state==E_WAIT && state==IDLE && !ctrl_busy) begin
                epoch_state<=E_CLEAR; clear_count<=0; fetch_addr<=0;
                fetch_row<=0; fetch_col<=0;
                // Bundled payload is stable before the synchronized epoch and
                // remains held until the next frame_tick in the pixel domain.
                active_mode_s<=mode_payload_p;
                if (commit_pending && !abort_pending && !frame_abort) begin
                    front_bank<=candidate_bank; front_live<=1;
                    commit_pending<=0; swap_waiting<=1;
                end
            end
            if (epoch_state==E_CLEAR) begin
                if (clear_count==3) begin s_ack<=epoch_seen; epoch_state<=E_RETURN; end
                else clear_count<=clear_count+1'b1;
            end
            if (epoch_state==E_RETURN && return_sync==epoch_seen) begin
                epoch_state<=E_RUN;
                if (swap_waiting) begin
                    swap_waiting<=0; loading<=0; end_pending<=0; abort_pending<=0;
                    frame_done<=1; frame_ok<=1;
                end
            end

            case (state)
                IDLE: begin
                    if (abort_pending && !swap_waiting) begin
                        // The active bus command has finished; queued back data
                        // may now be discarded without touching the front bank.
                        source_used<=0; source_wptr<=0; source_rptr<=0;
                        burst_count<=0; loading<=0; end_pending<=0;
                        abort_pending<=0; commit_pending<=0;
                        frame_done<=1; frame_ok<=0;
                    end else if (epoch_readable && s_ready && !ctrl_busy) begin
                        if (end_pending && source_used==0 && !commit_pending && !swap_waiting) begin
                            if (source_count==307200) begin
                                commit_pending<=1; candidate_bank<=active_write_bank;
                            end
                            else begin error_flags[1]<=1; abort_pending<=1; end
                        end
                        if (front_live && fetch_addr<frame_words && video_used<=1920 &&
                            (video_used<1024 || source_used<16 && !end_pending)) begin
                            state<=READ_PREP;
                        end else if (!commit_pending && !swap_waiting &&
                            (source_used>=16 || end_pending && source_used!=0)) begin
                            burst_count<=0; state<=BUILD_FETCH;
                        end else if (front_live && fetch_addr<frame_words && video_used<=1920) begin
                            state<=READ_PREP;
                        end
                    end
                end
                BUILD_FETCH: begin
                    if (abort_pending || frame_abort) state<=IDLE;
                    else if (source_used!=0) state<=BUILD_HAVE;
                    else state<=CMD_WRITE;
                end
                BUILD_HAVE: begin
                    if (abort_pending || frame_abort) state<=IDLE;
                    else if (head_matches) begin
                        if (burst_count==0) burst_addr<=source_head[42:24];
                        burst_mem[burst_count[3:0]]<=source_head[23:0];
                        burst_count<=burst_count+1'b1;
                        if (burst_count==15) state<=CMD_WRITE;
                        else state<=BUILD_FETCH;
                    end else state<=CMD_WRITE;
                end
                CMD_WRITE: if (cmd_ready) begin burst_index<=0; state<=WRITE_FETCH; end
                WRITE_FETCH: state<=WRITE_SEND;
                WRITE_SEND: if (ctrl_wr_ready) begin
                    if ({1'b0,burst_index}+1'b1==burst_count) state<=WRITE_WAIT;
                    else begin burst_index<=burst_index+1'b1; state<=WRITE_FETCH; end
                end
                WRITE_WAIT: if (ctrl_wr_done) state<=IDLE;
                READ_PREP: begin
                    read_row_base<=({10'd0,source_y}<<9)+({10'd0,source_y}<<7);
                    state<=READ_ADDR;
                end
                READ_ADDR: begin
                    read_address<=read_row_base+{9'd0,crop_x}+{9'd0,fetch_col};
                    state<=CMD_READ;
                end
                CMD_READ: if (cmd_ready) begin
                    fetch_addr<=fetch_addr+{11'd0,read_length};
                    if (fetch_col+{2'd0,read_length}==source_width) begin
                        fetch_col<=0; fetch_row<=fetch_row+1'b1;
                    end else fetch_col<=fetch_col+{2'd0,read_length};
                    state<=READ_WAIT;
                end
                READ_WAIT: if (ctrl_rd_valid && ctrl_rd_last) state<=READ_RECOVER;
                READ_RECOVER: if (!ctrl_busy) state<=IDLE;
                default: state<=IDLE;
            endcase
        end
    end
endmodule

// Dual-clock FIFO, inferred true dual-port memory, registered read port.
// w_level is conservative because the read Gray pointer crosses two flops.
// Clear is a coordinated protocol, NOT an asynchronous cross-domain reset:
// hold rclear until the writer has drained its bus transaction, hold wclear
// >=4 wclks, then release reader after synchronized writer acknowledgement.
module media_async_fifo #(
    parameter integer WIDTH=24, parameter integer ADDR_BITS=11
)(
    input wire wclk, input wire wrst_n, input wire wclear,
    input wire w_en, input wire [WIDTH-1:0] w_data,
    output wire w_full, output wire [ADDR_BITS:0] w_level,
    input wire rclk, input wire rrst_n, input wire rclear,
    input wire r_en, output reg [WIDTH-1:0] r_data, output reg r_valid,
    output wire r_empty
);
    reg [WIDTH-1:0] memory [0:(1<<ADDR_BITS)-1];
    reg [ADDR_BITS:0] wbin, wgray, rbin, rgray;
    (* async_reg = "true" *) reg [ADDR_BITS:0] rg_meta, rg_sync;
    (* async_reg = "true" *) reg [ADDR_BITS:0] wg_meta, wg_sync;
    wire [ADDR_BITS:0] wnext=wbin+1'b1;
    wire [ADDR_BITS:0] wnext_gray=(wnext>>1)^wnext;
    wire [ADDR_BITS:0] rnext=rbin+1'b1;
    wire [ADDR_BITS:0] rnext_gray=(rnext>>1)^rnext;
    reg [ADDR_BITS:0] synced_rbin;
    integer bit_index;
    always @* begin
        synced_rbin[ADDR_BITS]=rg_sync[ADDR_BITS];
        for (bit_index=ADDR_BITS-1;bit_index>=0;bit_index=bit_index-1)
            synced_rbin[bit_index]=synced_rbin[bit_index+1]^rg_sync[bit_index];
    end
    assign w_level=wbin-synced_rbin;
    assign w_full=wgray=={~rg_sync[ADDR_BITS:ADDR_BITS-1],rg_sync[ADDR_BITS-2:0]};
    assign r_empty=rgray==wg_sync;
    always @(posedge wclk or negedge wrst_n) begin
        if (!wrst_n) begin wbin<=0; wgray<=0; rg_meta<=0; rg_sync<=0; end
        else if (wclear) begin wbin<=0; wgray<=0; rg_meta<=0; rg_sync<=0; end
        else begin
            rg_meta<=rgray; rg_sync<=rg_meta;
            if (w_en && !w_full) begin
                memory[wbin[ADDR_BITS-1:0]]<=w_data; wbin<=wnext; wgray<=wnext_gray;
            end
        end
    end
    // Keep the RAM read register free of asynchronous reset for block-RAM
    // inference; r_valid, not reset RAM contents, defines output validity.
    always @(posedge rclk) begin
        if (r_en && !r_empty && !rclear) r_data<=memory[rbin[ADDR_BITS-1:0]];
    end
    always @(posedge rclk or negedge rrst_n) begin
        if (!rrst_n) begin rbin<=0; rgray<=0; wg_meta<=0; wg_sync<=0; r_valid<=0; end
        else if (rclear) begin rbin<=0; rgray<=0; wg_meta<=0; wg_sync<=0; r_valid<=0; end
        else begin
            wg_meta<=wgray; wg_sync<=wg_meta;
            r_valid<=r_en && !r_empty;
            if (r_en && !r_empty) begin rbin<=rnext; rgray<=rnext_gray; end
        end
    end
endmodule
