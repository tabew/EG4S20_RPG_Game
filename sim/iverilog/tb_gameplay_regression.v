`timescale 1ns/1ps
// Real rpg_core and ROM; deterministic RNG is forced only during a flee test.
module tb_gameplay_regression;
    reg clk = 0; always #10 clk = ~clk;
    reg rst_n = 0;
    reg [3:0] key = 0;
    wire [3:0] scene;
    wire [9:0] hp, maxhp, ehp;
    wire [11:0] gold;
    rpg_core dut(.clk(clk), .rst_n(rst_n), .key(key), .emergency(1'b0),
                 .dbg_scene(scene), .dbg_hp(hp), .dbg_maxhp(maxhp),
                 .dbg_gold(gold), .dbg_ehp(ehp));

    task idle;
        integer n, calm;
        begin
            n=0; calm=0;
            while (calm<8 && n<500000) begin
                @(negedge clk); n=n+1;
                if (!dut.rendering && !dut.redraw && !dut.alert_pending &&
                    dut.rstt==0 && dut.bst==0 && !dut.start_battle && !dut.splash_v)
                    calm=calm+1;
                else calm=0;
            end
            if (calm<8) $fatal(1,"idle timeout scene=%0d bst=%0d",scene,dut.bst);
        end
    endtask

    task tap(input [3:0] k);
        begin @(negedge clk); key=k; @(negedge clk); key=0; idle(); end
    endtask

    task reset_game;
        begin
            @(negedge clk); rst_n=0; key=0;
            repeat(4) @(negedge clk);
            rst_n=1; idle();
            if (scene !== 0) $fatal(1,"reset did not reach title");
            tap(1);
            if (scene !== 1) $fatal(1,"title did not reach class selection");
        end
    endtask

    integer hp_before, enemy_before, gold_before, mp_before, tries;
    initial begin
        reset_game(); tap(2);
        if (scene!==2 || dut.cls!==1 || hp!==92 || dut.mp!==90 || dut.atk!==11 || dut.def!==5)
            $fatal(1,"mage initial stats/scene");
        reset_game(); tap(4);
        if (scene!==2 || dut.cls!==2 || hp!==106 || dut.mp!==56 || dut.atk!==11 || dut.def!==7)
            $fatal(1,"ranger initial stats/scene");
        reset_game(); tap(1);
        if (scene!==2 || dut.cls!==0 || hp!==130 || dut.mp!==40 || gold!==40 || dut.herb!==2 || dut.pot!==1)
            $fatal(1,"warrior initial stats/scene");
        $display("PASS title, all three classes, initial map stats");

        tap(1);
        if (scene!==3 || ehp==0) $fatal(1,"map encounter");
        enemy_before=ehp; hp_before=hp; tap(1);
        if (scene!==3 || ehp>=enemy_before || hp>=hp_before)
            $fatal(1,"attack/enemy response hp=%0d ehp=%0d",hp,ehp);
        @(negedge clk); force dut.rnd=16'd0;
        tap(8); release dut.rnd;
        if (scene!==2) $fatal(1,"flee failed");
        hp_before=hp; gold_before=gold; tap(4);
        if (hp<=hp_before || hp>maxhp || gold!==gold_before-10)
            $fatal(1,"rest hp=%0d before=%0d gold=%0d",hp,hp_before,gold);
        $display("PASS encounter, attack, enemy response, flee and rest");

        tap(2);
        if (scene!==4) $fatal(1,"enter shop");
        gold_before=gold; tap(1);
        if (gold!==gold_before-15 || dut.herb!==3) $fatal(1,"buy herb");
        gold_before=gold; tap(2);
        if (gold!==gold_before || dut.pot!==1) $fatal(1,"insufficient gold purchase");
        tap(8); if (scene!==8) $fatal(1,"shop equipment page");
        tap(1); if (gold!==gold_before || dut.atk!==13) $fatal(1,"insufficient upgrade");
        tap(8); if (scene!==2) $fatal(1,"shop exit");
        $display("PASS shop purchase, insufficient funds, equipment page and exit");

        tap(1); if (scene!==3) $fatal(1,"second encounter");
        enemy_before=ehp; mp_before=dut.mp; tap(2);
        if (scene!==3 || ehp>=enemy_before || dut.mp!==mp_before-10)
            $fatal(1,"skill/mana");
        hp_before=hp; tap(4);
        if (dut.pot!==0 || hp<hp_before) $fatal(1,"battle potion");
        gold_before=gold; tries=0;
        while (scene==3 && tries<10) begin tap(1); tries=tries+1; end
        if (scene!==2 || dut.kills!==1 || gold<=gold_before || dut.exp==0)
            $fatal(1,"victory/rewards scene=%0d kills=%0d gold=%0d exp=%0d",scene,dut.kills,gold,dut.exp);
        $display("PASS skill, potion, victory, experience and gold");
        $display("PASS gameplay regression");
        $finish;
    end
    initial begin #200000000; $fatal(1,"watchdog"); end
endmodule
