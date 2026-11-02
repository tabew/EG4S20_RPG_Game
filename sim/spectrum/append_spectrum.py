"""One-shot append only. Coefficients are embedded in the production module."""
from pathlib import Path
import math
ROOT=Path(__file__).resolve().parents[2]
table=[]
for k in range(128):
    c=max(-32768,min(32767,round(32768*math.cos(2*math.pi*k/256))))
    s=max(-32768,min(32767,round(-32768*math.sin(2*math.pi*k/256))))
    table.append(f"            7'd{k}: twiddle = 32'h{c&65535:04x}{s&65535:04x};")
text=r'''

// 256 real PCM samples, 48 kHz: 187.5 Hz/bin, rectangular window.
// Eight normalized radix-2 DIT stages, single scheduled signed 18x16 product.
// Capture and work RAMs have synchronous reads and no reset loops. No audio
// backpressure: overflow is sticky diagnostics only. Two capture banks allow
// the previous block to be copied while the next is continuously recorded.
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
__TABLE__
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
    always @(posedge clk) begin
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
'''.replace('__TABLE__','\n'.join(table))
target=ROOT/'rtl/video/hdmi_tx.v'
latest=target.read_bytes()
if b'module audio_spectrum_fft' in latest:
    raise SystemExit('Already appended; refusing duplicate')
with target.open('ab') as f:
    f.write(text.encode('utf-8'))
print('APPENDED audio_spectrum_fft:',len(text),'bytes; existing bytes preserved:',len(latest))
