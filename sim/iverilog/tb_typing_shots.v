`timescale 1ns/1ps
`include "rpg_defs.vh"
// Capture the full-screen splash once per typed character so the typewriter
// reveal can be checked frame by frame.
//
// rpg_core types one glyph per pass through R_TYPE_C and then parks in
// R_TYPE_WAIT for T_CHAR before the next one. big_got therefore equals the
// number of glyphs already on screen, which makes each frame land on exactly
// one character count.
module tb_typing_shots;
    reg clk = 0;
    always #10 clk = ~clk;
    reg rst_n = 0;
    reg [3:0] key = 0;
    reg emergency = 0;
    wire we;
    wire [10:0] waddr;
    wire [16:0] wdata;
    wire level1_on;

    rpg_core dut (
        .clk(clk), .rst_n(rst_n), .key(key), .emergency(emergency),
        .level1_on(level1_on),
        .we(we), .waddr(waddr), .wdata(wdata),
        .dbg_scene(), .dbg_hp(), .dbg_maxhp(), .dbg_atk(), .dbg_def(),
        .dbg_gold(), .dbg_lv(), .dbg_state(), .dbg_pc(), .dbg_ehp(),
        .anim_on(), .anim_frame(), .mon_on(), .mon_id(), .mon_fade(),
        .sfx_id(), .sfx_trig()
    );

    reg [16:0] cells [0:1199];
    integer fd, i, nshot;
    always @(posedge clk) if (we && waddr < 1200) cells[waddr] <= wdata;

    task idle;
        integer n, calm;
        begin
            n = 0; calm = 0;
            while (calm < 8 && n < 400000) begin
                @(negedge clk);
                n = n + 1;
                if (!dut.rendering && !dut.redraw && !dut.alert_pending &&
                    dut.rstt == 0 && !dut.splash_v)
                    calm = calm + 1;
                else
                    calm = 0;
            end
            if (n == 400000) $fatal(1, "idle timeout shot %0d", nshot);
        end
    endtask

    task tap(input [3:0] k);
        begin
            @(negedge clk); key = k;
            @(negedge clk); key = 0;
            idle();
        end
    endtask

    task boot_map;
        begin
            @(negedge clk);
            rst_n = 0; key = 0; emergency = 0;
            repeat (6) @(negedge clk);
            rst_n = 1;
            idle();
            tap(4'b0001);
            tap(4'b0001);
            if (dut.scene != 4'd2) $fatal(1, "map entry failed scene %0d", dut.scene);
        end
    endtask

    task dump;
        begin
            $fwrite(fd, "TYPER %0d %0d %0d\n", nshot, dut.big_got, dut.big_len);
            for (i = 0; i < 1200; i = i + 1)
                $fwrite(fd, "%05h\n", cells[i]);
            $display("TYPER %0d typed %0d/%0d pri %0d rstt %0d",
                     nshot, dut.big_got, dut.big_len, dut.splash_pri, dut.rstt);
            nshot = nshot + 1;
            $fflush(fd);
        end
    endtask

    // Park in R_TYPE_WAIT with exactly `n` glyphs already written.
    task grab_at(input [5:0] n);
        integer t;
        begin
            t = 0;
            while (!(dut.splash_v && dut.rstt == 5'd25 && dut.big_got == n) && t < 800000) begin
                @(negedge clk);
                t = t + 1;
            end
            if (t == 800000) $fatal(1, "typing wait %0d timeout shot %0d", n, nshot);
            repeat (10) @(negedge clk);
            if (dut.big_got != n)
                $fatal(1, "glyph count moved %0d -> %0d", n, dut.big_got);
            dump();
        end
    endtask

    task grab_hold;
        integer t;
        begin
            t = 0;
            while (!(dut.splash_v && dut.rstt == 5'd26) && t < 800000) begin
                @(negedge clk);
                t = t + 1;
            end
            if (t == 800000) $fatal(1, "typing hold timeout shot %0d", nshot);
            repeat (10) @(negedge clk);
            dump();
        end
    endtask

    initial begin
        fd = $fopen("preview/sim_features/typing_cells.txt", "w");
        if (fd == 0) $fatal(1, "cannot open typing_cells.txt");
        nshot = 0;
        rst_n = 0; key = 0; emergency = 0;
        repeat (6) @(negedge clk);
        rst_n = 1;
        idle();

        // Low HP pops the level-1 blocking splash; walk its reveal.
        boot_map();
        @(negedge clk); dut.hp = 10'd20;

        grab_at(6'd1);
        grab_at(6'd2);
        grab_at(6'd3);
        grab_hold();

        if (dut.big_len != 6'd4)
            $display("NOTE sentence length is %0d glyphs", dut.big_len);
        $display("PASS typing_shots %0d", nshot);
        $fclose(fd);
        $finish;
    end

    initial begin
        #120_000_000;
        $fatal(1, "typing shot watchdog");
    end
endmodule
