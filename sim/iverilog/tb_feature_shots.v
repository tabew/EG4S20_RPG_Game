`timescale 1ns/1ps
`include "rpg_defs.vh"
// Drive the production rpg_core with key pulses and dump the character cells
// after each visible state. HP/area/kills deposits only set up the condition
// the hardware then judges; the text itself is drawn by the real interpreter.
module tb_feature_shots;
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
            $fwrite(fd, "SHOT %0d\n", nshot);
            for (i = 0; i < 1200; i = i + 1)
                $fwrite(fd, "%05h\n", cells[i]);
            $display("SHOT %0d scene %0d pri %0d addr %0d hp %0d area %0d kills %0d side %0b",
                     nshot, dut.scene, dut.banner_pri, dut.banner_addr,
                     dut.hp, dut.area, dut.kills, dut.side_v);
            nshot = nshot + 1;
            $fflush(fd);
        end
    endtask

    task wait_pri(input [1:0] pri);
        integer n;
        begin
            n = 0;
            while (!(dut.banner_v && dut.banner_pri == pri) && n < 500000) begin
                @(negedge clk);
                n = n + 1;
            end
            if (n == 500000) $fatal(1, "priority %0d timeout", pri);
            idle();
        end
    endtask

    task wait_addr(input [10:0] addr);
        integer n;
        begin
            n = 0;
            while (!(dut.banner_v && dut.banner_addr == addr) && n < 500000) begin
                @(negedge clk);
                n = n + 1;
            end
            if (n == 500000) $fatal(1, "addr %0d timeout", addr);
            idle();
        end
    endtask

    task wait_l1_done;
        integer n;
        begin
            n = 0;
            while (dut.banner_v && dut.banner_pri == 2'd1 && n < 500000) begin
                @(negedge clk);
                n = n + 1;
            end
            if (n == 500000) $fatal(1, "L1 linger timeout");
            idle();
        end
    endtask

    initial begin
        fd = $fopen("preview/sim_features/cells.txt", "w");
        if (fd == 0) $fatal(1, "cannot open cells.txt");
        nshot = 0;
        rst_n = 0; key = 0; emergency = 0;
        repeat (6) @(negedge clk);
        rst_n = 1;
        idle();
        dump();                 // 0 title

        tap(4'b0001);
        dump();                 // 1 class
        tap(4'b0001);
        dump();                 // 2 map, healthy, base sentence

        @(negedge clk); dut.area = 3'd1;
        idle();
        dump();                 // 3 cave, healthy, L2 danger beside it

        @(negedge clk); dut.hp = 10'd20;
        wait_pri(2'd1);
        dump();                 // 4 L1 near-death preempts the cave line
        wait_l1_done();
        dump();                 // 5 same cave, hurt, monsters remain

        boot_map();
        @(negedge clk); dut.area = 3'd1; dut.hp = 10'd20; dut.kills = 4'd4;
        wait_pri(2'd1);
        wait_l1_done();
        dump();                 // 6 same cave, hurt, monsters cleared

        boot_map();
        @(negedge clk); dut.kills = 4'd4;
        tap(4'b0010);           // shop
        tap(4'b0001);           // buy herb, L3
        if (dut.banner_pri != 2'd3 || dut.banner_addr != `MSG_BUY)
            $fatal(1, "shop L3 missing pri %0d addr %0d", dut.banner_pri, dut.banner_addr);
        dump();                 // 7 shop notice
        wait_addr(`MSG_BOSS);
        dump();                 // 8 boss preempts
        wait_addr(`MSG_BUY);
        dump();                 // 9 shop notice returns

        boot_map();
        tap(4'b0001);           // explore
        if (dut.scene != 4'd3) $fatal(1, "battle entry failed");
        dump();                 // 10 L2 encounter

        boot_map();
        @(negedge clk); dut.kills = 4'd4;
        tap(4'b1000);           // boss
        if (dut.scene != 4'd3 || dut.banner_addr != `MSG_BOSS)
            $fatal(1, "boss battle missing");
        dump();                 // 11 L1 boss on the battle board

        boot_map();
        @(negedge clk); emergency = 1;
        @(negedge clk); emergency = 0;
        wait_addr(`MSG_ALERT);
        dump();                 // 12 emergency preempts the area line
        wait_l1_done();
        dump();                 // 13 area line returns

        $display("PASS feature_shots %0d", nshot);
        $fclose(fd);
        $finish;
    end

    initial begin
        #80_000_000;
        $fatal(1, "feature shot watchdog");
    end
endmodule
