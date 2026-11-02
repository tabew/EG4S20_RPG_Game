//=============================================================================
// tb_img_chime.v —— 验证换图音效: img_chime 驱动 sound 的 chime 通道
//
//   检查:
//     1) 每次真正换到新图号, 恰好触发一次 (trig 脉冲), step 与该图号对应
//     2) 基音 55ms 后切上五度 (step x 1.5)
//     3) 实际振荡频率 = step * 32000 / 2^24
//
//   测频直接看 sound 内部 chime 振荡器的最高位 (u_snd.cph[23]),
//   绕开 BGM 三路声部, 否则测到的是 BGM 的音高。
//=============================================================================
`timescale 1ns/1ps

module tb_img_chime;
    localparam integer CLK_HZ = 25175000;

    reg clk = 0;
    reg rst_n = 0;
    reg [5:0] index = 6'd0;
    reg [5:0] count = 6'd25;
    reg       ready = 0;

    wire        trig;
    wire [23:0] step;
    wire [15:0] len;
    wire [7:0]  dac;

    img_chime #(.CLK_HZ(CLK_HZ)) u_chime (
        .clk(clk), .rst_n(rst_n),
        .index(index), .count(count), .ready(ready),
        .trig(trig), .step(step), .len(len)
    );

    sound #(.CLK_HZ(CLK_HZ), .SAMPLE_HZ(32000), .BPM(120), .LOOP_END(63)) u_snd (
        .clk(clk), .rst_n(rst_n),
        .sfx_id(4'd0), .sfx_trig(1'b0),
        .chime_step(step), .chime_len(len), .chime_trig(trig),
        .mus_on(1'b0), .mus_sel(2'd0),
        .dac(dac),
        .note0(), .note1(), .note2(), .lev0(), .lev1(), .lev2()
    );

    always #20 clk = ~clk;                  // 25MHz

    // ---- 触发记录 ----
    integer ntrig = 0;
    always @(posedge clk) begin
        if (trig) begin
            ntrig = ntrig + 1;
            $display("  [trig %0d] t=%0t step=%0d len=%0d", ntrig, $time, step, len);
        end
    end

    // ---- 直接测 chime 振荡器 ----
    wire chime_bit = u_snd.cph[23];
    reg  prev_bit = 0;
    integer nedges = 0;
    real t1 = 0.0, t2 = 0.0;
    reg  cap = 0;
    real freq;

    always @(posedge clk) begin
        if (cap && chime_bit && !prev_bit) begin
            nedges = nedges + 1;
            if (nedges == 1) t1 = $realtime;
            if (nedges == 2) t2 = $realtime;
        end
        prev_bit = chime_bit;
    end

    task measure(output real f, output real hz_from_step);
        begin
            cap = 0; nedges = 0; cap = 1;
            while (nedges < 2) #1000;
            cap = 0;
            f = 1.0e9 / (t2 - t1);
            hz_from_step = step * 32000.0 / 16777216.0;
        end
    endtask

    real f, fexp;

    initial begin
        #2_000_000;                         // 复位
        rst_n = 1;
        #1_000_000;
        ready = 1;
        #2_000_000;

        // ---- 换到第 3 张 (index=2, 表值 311.1Hz) ----
        $display("== 换到 index=2 (期望基音 311.1Hz) ==");
        index = 6'd2;
        #15_000_000;                        // 稳定 8ms + 起音
        measure(f, fexp);
        $display("  基音  : %7.1f Hz   (step->%.1f Hz)", f, fexp);

        #48_000_000;                        // 基音 55ms 结束后进入上五度
        measure(f, fexp);
        $display("  上五度: %7.1f Hz   (step->%.1f Hz)", f, fexp);

        // ---- 换到第 25 张 (index=24, 表值 987.8Hz) ----
        $display("== 换到 index=24 (期望基音 987.8Hz) ==");
        #100_000_000;                       // 等上一张两个音都走完 (到 ~158ms)
        index = 6'd24;
        #15_000_000;
        measure(f, fexp);
        $display("  基音  : %7.1f Hz   (step->%.1f Hz)", f, fexp);

        #60_000_000;                        // 上五度段
        measure(f, fexp);
        $display("  上五度: %7.1f Hz   (step->%.1f Hz)", f, fexp);

        // ---- 同号重复不应再响 ----
        #20_000_000;
        index = 6'd24;
        #20_000_000;
        $display("== 重复写同一图号, 累计触发 %0d 次 (期望 4: 两张图 x 2 音) ==", ntrig);

        $display("DONE");
        $finish;
    end
endmodule
