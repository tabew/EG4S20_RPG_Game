//=============================================================================
// tb_play.v —— Icarus Verilog 测试台（跑真实 RTL，直接把画面存成文件）
//
// 思路: iverilog 支持 $fwrite, 所以不导 VCD，而是把帧缓冲直接写成原始像素:
//       sim/iverilog/frames.rgb   每帧 640*480*3 字节, 连续排列
//   再用 tools/rgb2png.py 切成一张张 PNG 看。
//
// 按键读脚本 sim/iverilog/keys.txt（一行一个 1~4）。
// TB 会在"渲染器空闲"时自动按下下一个键, 所以脚本只管顺序, 不用管时序；
// 每按一次键就存一帧，最后一张就是当前画面。
//
// 在工程根目录执行:
//     iverilog -g2012 -o sim.out -I rtl/gen \
//         rtl/gen/rpg_defs.vh rtl/clk_gen.v rtl/common/reset_sync.v \
//         rtl/common/key_debounce.v rtl/video/*.v rtl/gen/ui_rom.v \
//         rtl/gen/rpg_msgs.v rtl/ctrl/rpg_core.v sim/iverilog/tb_play.v
//     vvp sim.out
//     python tools/rgb2png.py
//=============================================================================
`timescale 1ns/1ps

module tb_play;

    localparam integer W = 640, H = 480;
    localparam integer MAX_KEYS = 128;

    reg clk = 0;
    always #10 clk = ~clk;                    // 50MHz

    reg        rst_core_n = 0;
    reg        rst_vid_n  = 0;
    reg  [3:0] key = 4'b0000;

    wire        we;
    wire        anim_on;
    wire [2:0]  anim_frame;
    wire [10:0] waddr;
    wire [15:0] wdata;
    wire        hs, vs, de;
    wire [15:0] rgb;

    wire [3:0]  o_state;
    wire [2:0]  o_scene;
    wire [9:0]  o_hp, o_maxhp;
    wire [11:0] o_gold;
    wire [3:0]  o_lv;
    wire [9:0]  o_ehp;

    rpg_core u_core (
        .clk        (clk),
        .rst_n      (rst_core_n),
        .key        (key),
        .we         (we),
        .waddr      (waddr),
        .wdata      (wdata),
        .dbg_scene  (o_scene),
        .dbg_hp     (o_hp),
        .dbg_maxhp  (o_maxhp),
        .dbg_atk    (),
        .dbg_def    (),
        .dbg_gold   (o_gold),
        .dbg_lv     (o_lv),
        .dbg_state  (o_state),
        .dbg_pc     (),
        .anim_on    (anim_on),
        .anim_frame (anim_frame),
        .dbg_ehp    (o_ehp)
    );

    rpg_video u_vid (
        .clk   (clk),
        .rst_n (rst_vid_n),
        .anim_on    (anim_on),
        .anim_frame (anim_frame),
        .we    (we),
        .waddr (waddr),
        .wdata (wdata),
        .hs    (hs),
        .vs    (vs),
        .de    (de),
        .rgb   (rgb)
    );

    //---------------------------------------------------------
    // 帧缓冲
    //---------------------------------------------------------
    reg [15:0] fbuf [0:W*H-1];
    integer px = 0, py = 0, i;

    wire vs_rise;
    reg  vs_d = 0;
    always @(posedge clk) vs_d <= vs;
    assign vs_rise = vs & ~vs_d;

    always @(posedge clk) begin
        if (de) begin
            fbuf[py*W + px] <= rgb;
            if (px == W-1) begin
                px <= 0;
                py <= py + 1;
            end else begin
                px <= px + 1;
            end
        end
        if (vs_rise) py <= 0;
    end

    //---------------------------------------------------------
    // 按键脚本
    //---------------------------------------------------------
    integer kf, kn, ki, ktmp;
    reg [3:0] kseq [0:MAX_KEYS-1];

    initial begin
        for (ki = 0; ki < MAX_KEYS; ki = ki + 1) kseq[ki] = 4'd0;
        kn = 0;
        kf = $fopen("sim/iverilog/keys.txt", "r");
        if (kf == 0) begin
            $display("[TB] 打不开 keys.txt, 只跑默认(不按键)一屏");
        end else begin
            kn = 0;
            for (ki = 0; ki < MAX_KEYS; ki = ki + 1) begin
                if (!$feof(kf)) begin
                    ktmp = 0;
                    if ($fscanf(kf, "%d", ktmp) == 1) begin
                        kseq[kn] = ktmp[3:0];
                        kn = kn + 1;
                    end
                end
            end
            $fclose(kf);
        end
        $display("[TB] keys.txt 读到 %0d 个按键", kn);
    end

    //---------------------------------------------------------
    // 存帧
    //---------------------------------------------------------
    integer fd;
    integer shot = 0;

    integer cf;
    initial cf = 0;
    always @(posedge clk) if (cyc == 4001) cf = $fopen("sim/iverilog/cells_all.bin", "wb");

    task dump_frame;
        begin
            if (cf != 0)
                for (i = 0; i < 1200; i = i + 1)
                    $fwrite(cf, "%c%c", u_vid.cell_mem[i][15:8], u_vid.cell_mem[i][7:0]);
            for (i = 0; i < W*H; i = i + 1) begin
                $fwrite(fd, "%c%c%c",
                        {fbuf[i][15:11], 3'b000},      // R
                        {fbuf[i][10:5],  2'b00},       // G
                        {fbuf[i][4:0],   3'b000});     // B
            end
            shot = shot + 1;
            $display("[TB] 存下第 %0d 帧  -> 场景=%0d HP=%0d/%0d 敌HP=%0d 金=%0d Lv%0d",
                     shot, o_scene, o_hp, o_maxhp, o_ehp, o_gold, o_lv);
        end
    endtask

    //---------------------------------------------------------
    // 主流程: 按键 -> 等两帧 -> 存图 -> 下一个键
    //---------------------------------------------------------
    localparam [1:0] S_PRESS = 2'd0, S_WAIT = 2'd1, S_SHOT = 2'd2, S_END = 2'd3;

    reg [1:0] st = S_PRESS;
    integer   idx = 0, cyc = 0, hold = 0;

    initial fd = 0;

    always @(posedge clk) begin
        cyc <= cyc + 1;

        if (cyc == 3)    rst_core_n <= 1'b1;
        if (cyc == 4000) begin
            rst_vid_n <= 1'b1;
            fd = $fopen("sim/iverilog/frames.rgb", "wb");
            $display("[TB] 开始扫描输出 -> sim/iverilog/frames.rgb");
        end

        if (hold > 0) begin
            hold <= hold - 1;
            if (hold == 1) key <= 4'b0000;      // 松开
        end

        // 按键那一帧可能画到一半, 所以要等到下下个场同步再存
        if (vs_rise && st == S_WAIT) st <= S_SHOT;

        case (st)
        S_PRESS: begin
            if (cyc > 6000 && o_state == 4'd0 && hold == 0) begin
                if (idx < kn) begin
                    key  <= (kseq[idx] == 4'd0) ? 4'b0000
                            : (4'b0001 << (kseq[idx] - 4'd1));
                    idx  <= idx + 1;
                    hold <= 2;
                    st   <= S_WAIT;
                    $display("[TB] 按键 #%0d = %0d -> key=%b (周期 %0d)", idx, kseq[idx], (4'b0001 << (kseq[idx]-1)), cyc);
                end else begin
                    st <= S_SHOT;               // 脚本跑完, 补存最后一屏
                end
            end
        end
        S_WAIT: begin
            // 等场同步翻转, 真正的状态切换在上面那个 if 里
        end
        S_SHOT: begin
            if (vs_rise) begin                // 等帧结束再存, 保证画面完整
                dump_frame;
                if (idx < kn) st <= S_PRESS;
                else          st <= S_END;
            end
        end
        S_END: begin
            $fclose(fd);
            if (cf != 0) $fclose(cf);
            $display("[TB] 全部完成, 共 %0d 帧", shot);
            $finish;
        end
        default: st <= S_END;
        endcase

        if (cyc > 30000000) begin
            $display("[TB] 超时退出");
            $fclose(fd);
            $finish;
        end
    end

endmodule
