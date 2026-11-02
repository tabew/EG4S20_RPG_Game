`timescale 1ns/1ps
// STAGED ONLY. NOT IN THE NATIVE PROJECT. Compile without hdmi_tx.v.
module audio_spectrum_fft (
    input wire clk,
    input wire rst_n,
    input wire sample_tick,
    input wire signed [15:0] pcm_sample,
    output reg [63:0] levels,
    output reg frame_valid,
    output reg overflow
);
    localparam IDLE=0, COPY_READ=1, COPY_WRITE=2,
        READ_A=3, LATCH_A=4, READ_B=5, LATCH_B=6,
        MUL0=7, MUL1=8, MUL2=9, MUL3=10, MUL4=11,
        WRITE_A=12, WRITE_B=13, SCAN_READ=14, SCAN_BIN=15,
        LEVEL_BAND=16, PUBLISH=17;
    reg [4:0] state;
    reg [15:0] capture_mem [0:511];
    reg [35:0] work_mem [0:255];
    reg [15:0] capture_q;
    reg [35:0] work_q;
    reg capture_bank, ready_bank, copy_bank, block_ready;
    reg [7:0] capture_index, copy_index;
    reg [2:0] stage;
    reg [7:0] half_span, group_base, butterfly_j;
    wire [8:0] next_group = {1'b0,group_base}+{half_span,1'b0};
    wire [7:0] address_a = group_base + butterfly_j;
    wire [7:0] address_b = address_a + half_span;
    reg [7:0] scan_index;
    reg [2:0] publish_band;
    reg [63:0] pending_levels;
    reg [18:0] band_peak [0:7];
    reg signed [17:0] ar, ai, br, bi;
    reg signed [15:0] wr, wi;
    reg signed [17:0] mul_a;
    reg signed [15:0] mul_b;
    reg signed [33:0] product;
    reg signed [34:0] product_acc;
    reg signed [18:0] tr, ti;
    wire signed [34:0] product_ext = {product[33],product};
    wire signed [19:0] ar_ext = {{2{ar[17]}},ar};
    wire signed [19:0] ai_ext = {{2{ai[17]}},ai};
    wire signed [19:0] tr_ext = {tr[18],tr};
    wire signed [19:0] ti_ext = {ti[18],ti};
    wire signed [19:0] sum_re = (ar_ext+tr_ext) >>> 1;
    wire signed [19:0] sum_im = (ai_ext+ti_ext) >>> 1;
    wire signed [19:0] dif_re = (ar_ext-tr_ext) >>> 1;
    wire signed [19:0] dif_im = (ai_ext-ti_ext) >>> 1;
    wire [17:0] abs_re = work_q[35] ? (~work_q[35:18]+18'd1) : work_q[35:18];
    wire [17:0] abs_im = work_q[17] ? (~work_q[17:0]+18'd1) : work_q[17:0];
    wire [18:0] magnitude = {1'b0,abs_re}+{1'b0,abs_im};
    wire [2:0] scan_band = (scan_index==1) ? 0 :
        (scan_index==2) ? 1 : (scan_index<=4) ? 2 :
        (scan_index<=8) ? 3 : (scan_index<=16) ? 4 :
        (scan_index<=32) ? 5 : (scan_index<=64) ? 6 : 7;
    wire [7:0] target_level = compress(band_peak[publish_band]);
    wire [7:0] old_level = levels >> {publish_band,3'b000};
    wire [7:0] falling_level = (old_level>8'd2) ? old_level-8'd2 : 8'd0;
    wire [7:0] next_level = (target_level>=falling_level) ? target_level : falling_level;
    integer reset_band;

    function [7:0] bit_reverse;
        input [7:0] value;
        begin bit_reverse={value[0],value[1],value[2],value[3],value[4],value[5],value[6],value[7]}; end
    endfunction
    function [31:0] twiddle;
        input [6:0] index;
        begin case(index)
            7'd0: twiddle = 32'h7fff0000;
            7'd1: twiddle = 32'h7ff6fcdc;
            7'd2: twiddle = 32'h7fd9f9b8;
            7'd3: twiddle = 32'h7fa7f695;
            7'd4: twiddle = 32'h7f62f374;
            7'd5: twiddle = 32'h7f0af055;
            7'd6: twiddle = 32'h7e9ded38;
            7'd7: twiddle = 32'h7e1eea1e;
            7'd8: twiddle = 32'h7d8ae707;
            7'd9: twiddle = 32'h7ce4e3f4;
            7'd10: twiddle = 32'h7c2ae0e6;
            7'd11: twiddle = 32'h7b5ddddc;
            7'd12: twiddle = 32'h7a7ddad8;
            7'd13: twiddle = 32'h798ad7d9;
            7'd14: twiddle = 32'h7885d4e1;
            7'd15: twiddle = 32'h776cd1ef;
            7'd16: twiddle = 32'h7642cf04;
            7'd17: twiddle = 32'h7505cc21;
            7'd18: twiddle = 32'h73b6c946;
            7'd19: twiddle = 32'h7255c673;
            7'd20: twiddle = 32'h70e3c3a9;
            7'd21: twiddle = 32'h6f5fc0e9;
            7'd22: twiddle = 32'h6dcabe32;
            7'd23: twiddle = 32'h6c24bb85;
            7'd24: twiddle = 32'h6a6eb8e3;
            7'd25: twiddle = 32'h68a7b64c;
            7'd26: twiddle = 32'h66d0b3c0;
            7'd27: twiddle = 32'h64e9b140;
            7'd28: twiddle = 32'h62f2aecc;
            7'd29: twiddle = 32'h60ecac65;
            7'd30: twiddle = 32'h5ed7aa0a;
            7'd31: twiddle = 32'h5cb4a7bd;
            7'd32: twiddle = 32'h5a82a57e;
            7'd33: twiddle = 32'h5843a34c;
            7'd34: twiddle = 32'h55f6a129;
            7'd35: twiddle = 32'h539b9f14;
            7'd36: twiddle = 32'h51349d0e;
            7'd37: twiddle = 32'h4ec09b17;
            7'd38: twiddle = 32'h4c409930;
            7'd39: twiddle = 32'h49b49759;
            7'd40: twiddle = 32'h471d9592;
            7'd41: twiddle = 32'h447b93dc;
            7'd42: twiddle = 32'h41ce9236;
            7'd43: twiddle = 32'h3f1790a1;
            7'd44: twiddle = 32'h3c578f1d;
            7'd45: twiddle = 32'h398d8dab;
            7'd46: twiddle = 32'h36ba8c4a;
            7'd47: twiddle = 32'h33df8afb;
            7'd48: twiddle = 32'h30fc89be;
            7'd49: twiddle = 32'h2e118894;
            7'd50: twiddle = 32'h2b1f877b;
            7'd51: twiddle = 32'h28278676;
            7'd52: twiddle = 32'h25288583;
            7'd53: twiddle = 32'h222484a3;
            7'd54: twiddle = 32'h1f1a83d6;
            7'd55: twiddle = 32'h1c0c831c;
            7'd56: twiddle = 32'h18f98276;
            7'd57: twiddle = 32'h15e281e2;
            7'd58: twiddle = 32'h12c88163;
            7'd59: twiddle = 32'h0fab80f6;
            7'd60: twiddle = 32'h0c8c809e;
            7'd61: twiddle = 32'h096b8059;
            7'd62: twiddle = 32'h06488027;
            7'd63: twiddle = 32'h0324800a;
            7'd64: twiddle = 32'h00008000;
            7'd65: twiddle = 32'hfcdc800a;
            7'd66: twiddle = 32'hf9b88027;
            7'd67: twiddle = 32'hf6958059;
            7'd68: twiddle = 32'hf374809e;
            7'd69: twiddle = 32'hf05580f6;
            7'd70: twiddle = 32'hed388163;
            7'd71: twiddle = 32'hea1e81e2;
            7'd72: twiddle = 32'he7078276;
            7'd73: twiddle = 32'he3f4831c;
            7'd74: twiddle = 32'he0e683d6;
            7'd75: twiddle = 32'hdddc84a3;
            7'd76: twiddle = 32'hdad88583;
            7'd77: twiddle = 32'hd7d98676;
            7'd78: twiddle = 32'hd4e1877b;
            7'd79: twiddle = 32'hd1ef8894;
            7'd80: twiddle = 32'hcf0489be;
            7'd81: twiddle = 32'hcc218afb;
            7'd82: twiddle = 32'hc9468c4a;
            7'd83: twiddle = 32'hc6738dab;
            7'd84: twiddle = 32'hc3a98f1d;
            7'd85: twiddle = 32'hc0e990a1;
            7'd86: twiddle = 32'hbe329236;
            7'd87: twiddle = 32'hbb8593dc;
            7'd88: twiddle = 32'hb8e39592;
            7'd89: twiddle = 32'hb64c9759;
            7'd90: twiddle = 32'hb3c09930;
            7'd91: twiddle = 32'hb1409b17;
            7'd92: twiddle = 32'haecc9d0e;
            7'd93: twiddle = 32'hac659f14;
            7'd94: twiddle = 32'haa0aa129;
            7'd95: twiddle = 32'ha7bda34c;
            7'd96: twiddle = 32'ha57ea57e;
            7'd97: twiddle = 32'ha34ca7bd;
            7'd98: twiddle = 32'ha129aa0a;
            7'd99: twiddle = 32'h9f14ac65;
            7'd100: twiddle = 32'h9d0eaecc;
            7'd101: twiddle = 32'h9b17b140;
            7'd102: twiddle = 32'h9930b3c0;
            7'd103: twiddle = 32'h9759b64c;
            7'd104: twiddle = 32'h9592b8e3;
            7'd105: twiddle = 32'h93dcbb85;
            7'd106: twiddle = 32'h9236be32;
            7'd107: twiddle = 32'h90a1c0e9;
            7'd108: twiddle = 32'h8f1dc3a9;
            7'd109: twiddle = 32'h8dabc673;
            7'd110: twiddle = 32'h8c4ac946;
            7'd111: twiddle = 32'h8afbcc21;
            7'd112: twiddle = 32'h89becf04;
            7'd113: twiddle = 32'h8894d1ef;
            7'd114: twiddle = 32'h877bd4e1;
            7'd115: twiddle = 32'h8676d7d9;
            7'd116: twiddle = 32'h8583dad8;
            7'd117: twiddle = 32'h84a3dddc;
            7'd118: twiddle = 32'h83d6e0e6;
            7'd119: twiddle = 32'h831ce3f4;
            7'd120: twiddle = 32'h8276e707;
            7'd121: twiddle = 32'h81e2ea1e;
            7'd122: twiddle = 32'h8163ed38;
            7'd123: twiddle = 32'h80f6f055;
            7'd124: twiddle = 32'h809ef374;
            7'd125: twiddle = 32'h8059f695;
            7'd126: twiddle = 32'h8027f9b8;
            7'd127: twiddle = 32'h800afcdc;
            default: twiddle=32'h7fff0000;
        endcase end
    endfunction
    // Piecewise log2 compression: eight steps per octave. A small magnitude
    // floor removes fixed-point roundoff; monotonically increasing, 0..120.
    function [7:0] compress;
        input [18:0] mag;
        integer e, k;
        reg [18:0] shifted;
        reg [7:0] value;
        begin
            e=0;
            for(k=0;k<19;k=k+1) if(mag[k]) e=k;
            if(mag<19'd8) compress=0;
            else begin
                shifted=mag>>(e-3);
                value=((e-2)<<3)+{5'd0,shifted[2:0]};
                compress=(value>120) ? 8'd120 : value;
            end
        end
    endfunction

    // Exactly one multiplier expression, shared by all four real products.
    always @* begin
        mul_a=br; mul_b=wr;
        case(state)
            MUL1: begin mul_a=bi; mul_b=wi; end
            MUL2: begin mul_a=br; mul_b=wi; end
            MUL3: begin mul_a=bi; mul_b=wr; end
            default: begin mul_a=br; mul_b=wr; end
        endcase
    end
    // Optional inference candidate: addresses are selected before the RAM
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
    end

    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state<=IDLE; capture_bank<=0; capture_index<=0;
            ready_bank<=0; copy_bank<=0; block_ready<=0; copy_index<=0;
            stage<=0; half_span<=1; group_base<=0; butterfly_j<=0;
            scan_index<=1; publish_band<=0; pending_levels<=0;
            levels<=0; frame_valid<=0; overflow<=0;
            ar<=0; ai<=0; br<=0; bi<=0; wr<=0; wi<=0;
            product_acc<=0; tr<=0; ti<=0;
            for(reset_band=0;reset_band<8;reset_band=reset_band+1) band_peak[reset_band]<=0;
        end else begin
            frame_valid<=0;
            // More than one block arriving during computation is invalid.
            // Copy-bank collision is checked separately for pathological ticks.
            if(sample_tick) begin
                capture_index<=capture_index+1'b1;
                if((state==COPY_READ || state==COPY_WRITE) && capture_bank==copy_bank)
                    overflow<=1;
                if(capture_index==8'd255) begin
                    if(block_ready || state!=IDLE) overflow<=1;
                    ready_bank<=capture_bank;
                    block_ready<=1;
                    capture_bank<=~capture_bank;
                end
            end
            case(state)
                IDLE: if(block_ready) begin
                    block_ready<=0; copy_bank<=ready_bank; copy_index<=0;
                    state<=COPY_READ;
                    for(reset_band=0;reset_band<8;reset_band=reset_band+1) band_peak[reset_band]<=0;
                end
                COPY_READ: state<=COPY_WRITE;
                COPY_WRITE: begin
                    if(copy_index==255) begin
                        stage<=0; half_span<=1; group_base<=0; butterfly_j<=0;
                        state<=READ_A;
                    end else begin copy_index<=copy_index+1'b1; state<=COPY_READ; end
                end
                READ_A: begin
                    {wr,wi}<=twiddle(butterfly_j << (3'd7-stage));
                    state<=LATCH_A;
                end
                LATCH_A: begin ar<=work_q[35:18]; ai<=work_q[17:0]; state<=READ_B; end
                READ_B: state<=LATCH_B;
                LATCH_B: begin br<=work_q[35:18]; bi<=work_q[17:0]; state<=MUL0; end
                MUL0: state<=MUL1;
                MUL1: begin product_acc<=product_ext; state<=MUL2; end
                MUL2: begin tr<=(product_acc-product_ext) >>> 15; state<=MUL3; end
                MUL3: begin product_acc<=product_ext; state<=MUL4; end
                MUL4: begin ti<=(product_acc+product_ext) >>> 15; state<=WRITE_A; end
                WRITE_A: state<=WRITE_B;
                WRITE_B: begin
                    if(butterfly_j==half_span-1'b1) begin
                        butterfly_j<=0;
                        if(next_group>=9'd256) begin
                            group_base<=0;
                            if(stage==7) begin scan_index<=1; state<=SCAN_READ; end
                            else begin stage<=stage+1'b1; half_span<=half_span<<1; state<=READ_A; end
                        end else begin group_base<=next_group[7:0]; state<=READ_A; end
                    end else begin butterfly_j<=butterfly_j+1'b1; state<=READ_A; end
                end
                SCAN_READ: state<=SCAN_BIN;
                SCAN_BIN: begin
                    if(magnitude>band_peak[scan_band]) band_peak[scan_band]<=magnitude;
                    if(scan_index==127) begin publish_band<=0; state<=LEVEL_BAND; end
                    else begin scan_index<=scan_index+1'b1; state<=SCAN_READ; end
                end
                LEVEL_BAND: begin
                    pending_levels[{publish_band,3'b000} +: 8]<=next_level;
                    if(publish_band==7) state<=PUBLISH;
                    else publish_band<=publish_band+1'b1;
                end
                PUBLISH: begin levels<=pending_levels; frame_valid<=1; state<=IDLE; end
                default: state<=IDLE;
            endcase
        end
    end
endmodule
