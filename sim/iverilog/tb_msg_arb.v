`timescale 1ns/1ps
`include "rpg_defs.vh"

// 检查上下文选句，以及商店 3 级公告被 1 级强敌提示抢走后再弹回。
module tb_msg_arb;
    reg clk = 0;
    always #10 clk = ~clk;

    reg rst_n = 0;
    reg [3:0] key = 0;
    reg emergency = 0;

    wire        we;
    wire [10:0] waddr;
    wire [16:0] wdata;

    rpg_core dut (
        .clk(clk), .rst_n(rst_n), .key(key), .emergency(emergency),
        .we(we), .waddr(waddr), .wdata(wdata),
        .dbg_scene(), .dbg_hp(), .dbg_maxhp(), .dbg_atk(), .dbg_def(),
        .dbg_gold(), .dbg_lv(), .dbg_state(), .dbg_pc(), .dbg_ehp(),
        .anim_on(), .anim_frame(), .mon_on(), .mon_id(), .mon_fade(),
        .sfx_id(), .sfx_trig()
    );

    reg [8:0] cell_g [0:1199];
    reg [3:0] cell_fg [0:1199];
    integer ci;
    initial begin
        for (ci = 0; ci < 1200; ci = ci + 1) begin
            cell_g[ci] = 0;
            cell_fg[ci] = 0;
        end
    end
    always @(posedge clk) if (we) begin
        cell_g[waddr]  <= wdata[8:0];
        cell_fg[waddr] <= wdata[12:9];
    end

    integer errors;
    integer shop_keep;

    task wait_idle;
        integer n, calm;
        begin
            n = 0;
            calm = 0;
            while (calm < 8 && n < 400000) begin
                @(posedge clk);
                n = n + 1;
                if (dut.rstt == 0 && dut.rendering == 0 && dut.redraw == 0 &&
                    dut.alert_pending == 0 && dut.splash_v == 0)
                    calm = calm + 1;
                else
                    calm = 0;
            end
            if (n >= 400000) begin
                $display("FAIL idle timeout scene=%0d state=%0d", dut.scene, dut.rstt);
                errors = errors + 1;
            end
        end
    endtask

    // 整屏还在、四个角都是等级色块时返回。随后 wait_idle 等它收成一行。
    task wait_big;
        input [3:0] exp_c;
        integer n;
        begin
            n = 0;
            while (!(dut.splash_v && !dut.rendering && dut.rstt == 0 &&
                     cell_g[0] === 9'd1 && cell_fg[0] === exp_c &&
                     cell_g[1199] === 9'd1 && cell_fg[1199] === exp_c) &&
                   n < 200000) begin
                @(posedge clk);
                n = n + 1;
            end
            if (n >= 200000) begin
                $display("FAIL full screen color %0d corner fg=%0d glyph=%0d",
                         exp_c, cell_fg[0], cell_g[0]);
                errors = errors + 1;
            end
        end
    endtask

    task tap;
        input [3:0] k;
        begin
            @(negedge clk);
            key = k;
            @(negedge clk);
            key = 0;
            wait_idle();
        end
    endtask

    integer chk_i, chk_cell;
    reg [15:0] chk_word;
    task check_line;
        input integer x;
        input integer y;
        input [10:0] addr;
        input [3:0] exp_fg;
        begin
            chk_word = dut.u_str.mem[addr];
            chk_cell = y * 40 + x;
            if (cell_fg[chk_cell] !== exp_fg) begin
                $display("FAIL line y=%0d addr=%0d fg got %0d expect %0d",
                         y, addr, cell_fg[chk_cell], exp_fg);
                errors = errors + 1;
            end
            chk_i = 0;
            while (chk_word != 16'hFFFF && chk_i < 36) begin
                if (cell_g[y * 40 + x + chk_i] !== chk_word[8:0]) begin
                    $display("FAIL line y=%0d addr=%0d glyph[%0d] got %0d expect %0d",
                             y, addr, chk_i, cell_g[y * 40 + x + chk_i], chk_word[8:0]);
                    errors = errors + 1;
                    chk_i = 36;
                end else begin
                    chk_i = chk_i + 1;
                    chk_word = dut.u_str.mem[addr + chk_i];
                end
            end
            if (chk_i < 36 && cell_g[y * 40 + x + chk_i] !== 9'd0) begin
                $display("FAIL line y=%0d addr=%0d tail glyph %0d",
                         y, addr, cell_g[y * 40 + x + chk_i]);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        errors = 0;
        repeat (8) @(posedge clk);
        rst_n = 1;
        wait_idle();

        tap(4'b0001);                 // 标题 -> 选职业
        tap(4'b0001);                 // 战士 -> 地图
        if (dut.scene != 4'd2) begin
            $display("FAIL not on map, scene=%0d", dut.scene);
            errors = errors + 1;
        end
        if (dut.ctx_var != 2'd0) begin
            $display("FAIL fresh map ctx_var=%0d", dut.ctx_var);
            errors = errors + 1;
        end
        check_line(2, 4, dut.ctx_addr, 4'd3);
        check_line(2, 5, `MSG_FAR, 4'd3);

        @(negedge clk);
        emergency = 1'b1;
        @(negedge clk);
        emergency = 1'b0;
        wait_big(4'd5);
        wait_idle();
        check_line(2, 4, `MSG_ALERT, 4'd4);
        if (dut.queue_v) begin
            $display("FAIL map emergency queued a sticky line");
            errors = errors + 1;
        end
        while (dut.banner_v && errors == 0) @(posedge clk);
        wait_idle();
        check_line(2, 4, dut.ctx_addr, 4'd3);
        check_line(2, 5, `MSG_FAR, 4'd3);

        tap(4'b0001);                 // 探索，普通遭遇
        check_line(2, 13, `MSG_MEET, 4'd0);
        if (cell_g[24 * 40 + 2] == 0 || cell_g[24 * 40 + 4] == 0) begin
            $display("FAIL battle board missing under encounter line");
            errors = errors + 1;
        end
        @(negedge clk);
        force dut.rnd = 16'd0;
        tap(4'b1000);                 // 逃跑，回到地图
        release dut.rnd;
        if (dut.scene != 4'd2) begin
            $display("FAIL flee did not return, scene=%0d", dut.scene);
            errors = errors + 1;
        end

        @(negedge clk);
        force dut.area = 3'd1;
        wait_big(4'd7);
        wait_idle();
        if (dut.ctx_var != 2'd0) begin
            $display("FAIL cave full-hp var=%0d", dut.ctx_var);
            errors = errors + 1;
        end
        check_line(2, 4, dut.ctx_addr, 4'd3);
        check_line(2, 5, dut.danger_addr, 4'd0);

        @(negedge clk);
        force dut.hp = 10'd20;
        force dut.kills = 4'd4;
        wait_big(4'd5);
        wait_idle();
        check_line(2, 4, `MSG_DYING, 4'd4);
        if (cell_g[26 * 40 + 4] == 0) begin
            $display("FAIL map board cleared by level-1 warning");
            errors = errors + 1;
        end
        shop_keep = cell_g[26 * 40 + 4];

        while (dut.banner_v && errors == 0) begin
            @(posedge clk);
        end
        wait_idle();
        if (dut.ctx_var != 2'd1) begin
            $display("FAIL cleared-and-hurt var=%0d hp=%0d kills=%0d",
                     dut.ctx_var, dut.hp, dut.kills);
            errors = errors + 1;
        end
        check_line(2, 4, dut.ctx_addr, 4'd3);
        check_line(2, 5, dut.danger_addr, 4'd0);
        if (cell_g[26 * 40 + 4] != shop_keep) begin
            $display("FAIL map board changed after warning");
            errors = errors + 1;
        end

        @(negedge clk);
        force dut.hp = 10'd120;
        wait_idle();
        if (dut.ctx_var != 2'd0) begin
            $display("FAIL recovered var=%0d", dut.ctx_var);
            errors = errors + 1;
        end
        check_line(2, 4, dut.ctx_addr, 4'd3);

        @(negedge clk);
        force dut.hp = 10'd20;
        force dut.kills = 4'd1;
        wait_idle();
        while (dut.banner_v) @(posedge clk);
        wait_idle();
        if (dut.ctx_var != 2'd2) begin
            $display("FAIL hurt-remain var=%0d", dut.ctx_var);
            errors = errors + 1;
        end
        check_line(2, 4, dut.ctx_addr, 4'd3);

        @(negedge clk);
        force dut.kills = 4'd4;
        force dut.hp = 10'd120;       // 商店演示用健康角色，避免再被伤势提示打断
        release dut.area;
        force dut.area = 3'd1;
        wait_idle();

        tap(4'b0010);                 // 商店
        if (dut.scene != 4'd4) begin
            $display("FAIL not in shop, scene=%0d", dut.scene);
            errors = errors + 1;
        end
        @(negedge clk);
        emergency = 1'b1;
        @(negedge clk);
        emergency = 1'b0;
        wait_idle();
        check_line(2, 27, `MSG_ALERT, 4'd4);
        if (dut.queue_v != 1'b1 || dut.queue_addr != `MSG_AD) begin
            $display("FAIL empty shop did not queue the ad v=%b addr=%0d",
                     dut.queue_v, dut.queue_addr);
            errors = errors + 1;
        end
        while (!(dut.banner_v && dut.banner_pri == 2'd3 && dut.banner_addr == `MSG_AD) && errors == 0)
            @(posedge clk);
        wait_idle();
        check_line(2, 27, `MSG_AD, 4'd0);

        @(negedge clk);
        key = 4'b0001;                // 买药草，先整屏黄，再收成一行
        @(negedge clk);
        key = 4'b0000;
        wait_big(4'd8);
        wait_idle();
        check_line(2, 27, `MSG_BUY, 4'd0);
        shop_keep = cell_g[7 * 40 + 4];
        @(negedge clk);
        emergency = 1'b1;
        @(negedge clk);
        emergency = 1'b0;
        wait_idle();
        check_line(2, 27, `MSG_ALERT, 4'd4);
        if (dut.queue_v != 1'b1 || dut.queue_addr != `MSG_BUY) begin
            $display("FAIL emergency did not keep the purchase v=%b addr=%0d",
                     dut.queue_v, dut.queue_addr);
            errors = errors + 1;
        end
        @(negedge clk);
        force dut.boss_arm = 1'b0;
        emergency = 1'b1;
        @(negedge clk);
        emergency = 1'b0;
        @(posedge clk);
        if (dut.queue_v != 1'b1 || dut.queue_addr != `MSG_BUY) begin
            $display("FAIL second emergency replaced the purchase v=%b addr=%0d",
                     dut.queue_v, dut.queue_addr);
            errors = errors + 1;
        end
        if (dut.banner_pri != 2'd1 || dut.banner_addr != `MSG_ALERT) begin
            $display("FAIL second emergency left pri=%0d addr=%0d",
                     dut.banner_pri, dut.banner_addr);
            errors = errors + 1;
        end
        if (cell_g[7 * 40 + 4] != shop_keep) begin
            $display("FAIL shop board changed during emergency");
            errors = errors + 1;
        end
        while (!(dut.banner_v && dut.banner_pri == 2'd3 && dut.banner_addr == `MSG_BUY) && errors == 0)
            @(posedge clk);
        wait_idle();
        check_line(2, 27, `MSG_BUY, 4'd0);
        if (shop_keep == 0) begin
            $display("FAIL shop board empty before preempt");
            errors = errors + 1;
        end

        @(negedge clk);
        release dut.boss_arm;
        force dut.boss_arm = 1'b1;
        force dut.boss_latched = 1'b0;
        force dut.boss_tmr = 27'd30;
        @(negedge clk);
        release dut.boss_arm;
        release dut.boss_latched;
        release dut.boss_tmr;

        while (!(dut.banner_v && dut.banner_pri == 2'd1 && dut.banner_addr == `MSG_BOSS))
            @(posedge clk);
        wait_idle();
        check_line(2, 27, `MSG_BOSS, 4'd4);
        if (cell_g[7 * 40 + 4] != shop_keep) begin
            $display("FAIL shop board changed during boss warning");
            errors = errors + 1;
        end
        if (dut.queue_v != 1'b1 || dut.queue_addr != `MSG_BUY) begin
            $display("FAIL shop line not queued v=%b addr=%0d", dut.queue_v, dut.queue_addr);
            errors = errors + 1;
        end

        while (!(dut.banner_v && dut.banner_pri == 2'd3 && dut.banner_addr == `MSG_BUY))
            @(posedge clk);
        wait_idle();
        check_line(2, 27, `MSG_BUY, 4'd0);
        if (cell_g[7 * 40 + 4] != shop_keep) begin
            $display("FAIL shop board changed after restore");
            errors = errors + 1;
        end

        if (errors == 0) $display("PASS msg arbiter and context lines");
        else $display("FAIL %0d checks", errors);
        $finish;
    end

    initial begin
        #200_000_000;
        $display("FAIL watchdog");
        $finish;
    end
endmodule
