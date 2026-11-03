`timescale 1ns/1ps
`include "rpg_defs.vh"
// Capture the full-screen splash while it is still a solid colour block.
// tb_feature_shots waits for the splash to collapse into one line, so its
// dumps never show the blocking screen itself. This bench stops at
// R_TYPE_HOLD: every character of the sentence is drawn and the block still
// covers all 1200 cells.
module tb_splash_shots;
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

    // Same pulse without waiting for the render to settle. Needed when the
    // keypress itself starts the splash we want to photograph.
    task tap_raw(input [3:0] k);
        begin
            @(negedge clk); key = k;
            @(negedge clk); key = 0;
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

    // Wait until the splash has typed every character and is holding the
    // finished block on screen. That is the moment worth a screenshot.
    task wait_splash_full;
        integer n;
        begin
            n = 0;
            // rendering stays high until R_TYPE_HOLD counts out, so only
            // splash_v and the state number tell us the block is complete.
            while (!(dut.splash_v && dut.rstt == 5'd26) && n < 800000) begin
                @(negedge clk);
                n = n + 1;
            end
            if (n == 800000) $fatal(1, "splash hold timeout shot %0d", nshot);
            repeat (2) @(negedge clk);
        end
    endtask

    // Catch the block mid-typing so the progressive reveal is visible.
    // R_TYPE_WAIT (25) is the gap between two characters, so waiting for
    // big_got >= 2 guarantees at least two glyphs are already on screen.
    task wait_splash_partial;
        integer n;
        begin
            n = 0;
            while (!(dut.splash_v && dut.rstt == 5'd25 && dut.big_got >= 6'd2) && n < 800000) begin
                @(negedge clk);
                n = n + 1;
            end
            if (n == 800000) $fatal(1, "splash partial timeout shot %0d", nshot);
        end
    endtask

    task dump;
        begin
            $fwrite(fd, "SPLASH %0d\n", nshot);
            for (i = 0; i < 1200; i = i + 1)
                $fwrite(fd, "%05h\n", cells[i]);
            $display("SPLASH %0d scene %0d pri %0d addr %0d rstt %0d typed %0d/%0d",
                     nshot, dut.scene, dut.splash_pri, dut.splash_addr,
                     dut.rstt, dut.big_got, dut.big_len);
            nshot = nshot + 1;
            $fflush(fd);
        end
    endtask

    initial begin
        fd = $fopen("preview/sim_features/splash_cells.txt", "w");
        if (fd == 0) $fatal(1, "cannot open splash_cells.txt");
        nshot = 0;
        rst_n = 0; key = 0; emergency = 0;
        repeat (6) @(negedge clk);
        rst_n = 1;
        idle();

        // 0: 1 级红底白字，低血量警告盖住地图
        boot_map();
        @(negedge clk); dut.hp = 10'd20;
        wait_splash_full();
        dump();                 // 0 L1 dying, solid red block

        // 1: 同一个整屏，逐字打到一半
        boot_map();
        @(negedge clk); dut.hp = 10'd20;
        wait_splash_partial();
        dump();                 // 1 L1 typing in progress

        // 2: 3 级黄底黑字，商店公告
        boot_map();
        @(negedge clk); dut.kills = 4'd4;
        tap(4'b0010);           // shop, settle first
        tap_raw(4'b0001);       // buy herb -> 3 级 notice starts the splash
        wait_splash_full();
        dump();                 // 2 L3 shop notice on yellow

        // 3: 2 级橙底黑字，遭遇魔物
        boot_map();
        tap_raw(4'b0001);       // explore -> battle, splash starts here
        repeat (4) @(negedge clk);
        if (dut.scene != 4'd3) $fatal(1, "battle entry failed");
        wait_splash_full();
        dump();                 // 3 L2 encounter on orange

        // 4: 长按 K1 紧急通告
        boot_map();
        @(negedge clk); emergency = 1;
        @(negedge clk); emergency = 0;
        wait_splash_full();
        dump();                 // 4 L1 emergency

        $display("PASS splash_shots %0d", nshot);
        $fclose(fd);
        $finish;
    end

    initial begin
        #120_000_000;
        $fatal(1, "splash shot watchdog");
    end
endmodule