//=============================================================================
// key_debounce.v —— 机械按键消抖 + 短按脉冲 + 长按检测
//   click      : 短按(松开时)输出 1 个 clk 周期脉冲
//   press      : 按下期间保持 1
//   long_press : 按住超过 HOLD_MS 后输出 1 个脉冲(用于进入设参模式)
// 说明: 采样节拍 1ms, 连续 DEB_MS 稳定才认账
//=============================================================================
`timescale 1ns/1ps
module key_debounce #(
    parameter integer CLK_KHZ = 100000,   // 输入时钟, 单位 kHz
    parameter integer DEB_MS  = 20,       // 消抖时间 ms
    parameter integer HOLD_MS = 1200       // 长按判定 ms
)(
    input  wire clk,
    input  wire rst_n,
    input  wire key_n,        // 按键输入, 低有效
    output reg  click,
    output reg  press,
    output reg  long_press
);

    reg        long_f;        // 本次按下已判为长按
    reg [15:0] ms_cnt;
    reg        key_meta, key_sync;
    reg [15:0] deb_cnt;
    reg        key_stable;    // 1=松开 0=按下
    reg [15:0] hold_ms;

    localparam integer CNT_1MS = (CLK_KHZ < 1) ? 1 : CLK_KHZ;
    wire tick_1ms = (ms_cnt == CNT_1MS - 1);

    // ---- 1ms 节拍 ----
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)        ms_cnt <= 16'd0;
        else if (tick_1ms) ms_cnt <= 16'd0;
        else               ms_cnt <= ms_cnt + 16'd1;
    end

    // ---- 输入同步 ----
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            key_meta <= 1'b1;
            key_sync <= 1'b1;
        end else begin
            key_meta <= key_n;
            key_sync <= key_meta;
        end
    end

    // ---- 消抖 ----
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            deb_cnt    <= 16'd0;
            key_stable <= 1'b1;
        end else if (key_sync != key_stable) begin
            if (tick_1ms) begin
                if (deb_cnt >= DEB_MS) begin
                    key_stable <= key_sync;
                    deb_cnt    <= 16'd0;
                end else begin
                    deb_cnt <= deb_cnt + 16'd1;
                end
            end
        end else begin
            deb_cnt <= 16'd0;
        end
    end

    // ---- 长按 ----
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            hold_ms    <= 16'd0;
            long_press <= 1'b0;
            long_f     <= 1'b0;
        end else begin
            long_press <= 1'b0;
            if (!key_stable) begin
                if (tick_1ms) begin
                    if (hold_ms < HOLD_MS + 1) hold_ms <= hold_ms + 16'd1;
                    if (hold_ms == HOLD_MS) begin
                        long_press <= 1'b1;
                        long_f     <= 1'b1;
                    end
                end
            end else begin
                hold_ms <= 16'd0;
                long_f  <= 1'b0;
            end
        end
    end

    // ---- 短按 / 状态输出 ----
    reg press_d;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            press_d <= 1'b0;
            press   <= 1'b0;
            click   <= 1'b0;
        end else begin
            press_d <= !key_stable;
            press   <= !key_stable;
            click   <= press_d & key_stable & ~long_f;
        end
    end

endmodule

//=============================================================================
// gal_ctrl —— 相册(图片轮播)控制器
//
//   待机 10 秒无按键 -> 进入轮播: 每张停留 4 秒, 淡出 0.36s -> 换图 -> 淡入
//   任意键按下 -> 退出轮播回游戏, 之后 0.5 秒内屏蔽按键(防止误触游戏)
//   轮播期间持续输出 gal_block=1, 游戏核心收不到按键, 音乐不受影响
//
//   ★ 放在本文件而不是新文件: TD 会把工程目录里新增的 .v 标成
//     AutoExcluded, 忘记勾选就综合不到, 追加到已包含的文件最稳妥。
//=============================================================================
`timescale 1ns/1ps
module gal_ctrl #(
    parameter integer CLK_HZ     = 40000000,
    parameter integer IDLE_SEC   = 10,     // 无操作多少秒后进入轮播
    parameter integer HOLD_SEC   = 4,      // 每张图停留秒数
    parameter integer FADE_MS    = 40      // 淡入/淡出每档毫秒数 (共 9 档)
)(
    input  wire       clk,
    input  wire       rst_n,
    input  wire       click,        // 任意键按下(脉冲)
    output reg        gal_on,       // 1 = 轮播模式(画面被相册层接管)
    output reg  [1:0] gal_img,      // 当前图片号 0..3
    output reg  [3:0] gal_fade,     // 淡入淡出等级 0(黑)..8(全亮)
    output wire       gal_block     // 1 = 屏蔽送往游戏核心的按键
);
    localparam integer IDLE_TICKS = CLK_HZ * IDLE_SEC;
    localparam integer HOLD_TICKS = CLK_HZ * HOLD_SEC;
    localparam integer FADE_TICKS = CLK_HZ * FADE_MS / 1000;
    localparam integer LOCK_TICKS = CLK_HZ / 2;
    // ★ TD 不允许对 parameter 直接位选 (有前科), 所以给出定宽副本
    localparam [28:0] IDLE_LIM = IDLE_TICKS - 1;
    localparam [27:0] HOLD_LIM = HOLD_TICKS - 1;
    localparam [21:0] FADE_LIM = FADE_TICKS - 1;
    localparam [24:0] LOCK_LIM = LOCK_TICKS - 1;   // 20M 个时钟, 20 位装不下!

    localparam [1:0] S_HOLD = 2'd0, S_FOUT = 2'd1, S_FIN = 2'd2;

    reg  [1:0]  state;
    reg  [28:0] idle_cnt;
    reg  [27:0] hold_cnt;
    reg  [21:0] fade_cnt;
    reg  [24:0] lock_cnt;
    reg         lock;

    assign gal_block = gal_on | lock;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state    <= S_HOLD;
            idle_cnt <= 29'd0;
            hold_cnt <= 28'd0;
            fade_cnt <= 22'd0;
            lock_cnt <= 25'd0;
            gal_on   <= 1'b0;
            gal_img  <= 2'd0;
            gal_fade <= 4'd0;
            lock     <= 1'b0;
        end else begin
            // ---- 退出后的按键屏蔽计时 ----
            if (lock) begin
                if (lock_cnt >= LOCK_LIM) lock <= 1'b0;
                else                              lock_cnt <= lock_cnt + 25'd1;
            end

            if (!gal_on) begin
                // ---- 待机计时: 无按键 10 秒 -> 进入轮播 ----
                if (click)            idle_cnt <= 29'd0;
                else if (idle_cnt < IDLE_LIM) idle_cnt <= idle_cnt + 29'd1;

                if (idle_cnt >= IDLE_LIM) begin
                    gal_on   <= 1'b1;
                    gal_img  <= 2'd0;
                    gal_fade <= 4'd0;        // 从黑场淡入
                    state    <= S_FIN;
                    fade_cnt <= 22'd0;
                end
            end else begin
                // ---- 轮播运行 ----
                if (click) begin
                    gal_on   <= 1'b0;        // 任意键退出
                    lock     <= 1'b1;
                    lock_cnt <= 25'd0;
                    idle_cnt <= 29'd0;
                end else begin
                    case (state)
                        S_HOLD: begin
                            if (hold_cnt >= HOLD_LIM) begin
                                hold_cnt <= 28'd0;
                                state    <= S_FOUT;
                            end else
                                hold_cnt <= hold_cnt + 28'd1;
                        end
                        S_FOUT: begin       // 渐暗
                            if (fade_cnt >= FADE_LIM) begin
                                fade_cnt <= 22'd0;
                                if (gal_fade == 4'd0) begin
                                    gal_img  <= gal_img + 2'd1;  // 黑场中换图
                                    state    <= S_FIN;
                                end else
                                    gal_fade <= gal_fade - 4'd1;
                            end else
                                fade_cnt <= fade_cnt + 22'd1;
                        end
                        S_FIN: begin        // 渐亮
                            if (fade_cnt >= FADE_LIM) begin
                                fade_cnt <= 22'd0;
                                if (gal_fade == 4'd8) begin
                                    state    <= S_HOLD;
                                    hold_cnt <= 28'd0;
                                end else
                                    gal_fade <= gal_fade + 4'd1;
                            end else
                                fade_cnt <= fade_cnt + 22'd1;
                        end
                        default: state <= S_HOLD;
                    endcase
                end
            end
        end
    end

endmodule
//=============================================================================
// sound —— PSG 三声部音乐盒 (BGM + 音效)
//   32kHz 采样, music.hex 存 3 首 x 64 步; mus_sel 选曲, 变化即跳轨。
//   note0/1/2 与 lev0/1/2 曝露给 note_bars 做音高可视化。
//=============================================================================
`timescale 1ns/1ps
module sound #(
    parameter integer CLK_HZ    = 40000000,
    parameter integer SAMPLE_HZ = 32000,
    parameter integer BPM       = 120,
    parameter integer LOOP_END  = 63
)(
    input  wire       clk,
    input  wire       rst_n,
    input  wire [3:0] sfx_id,      // 1..15, 0 = 静音
    input  wire       sfx_trig,    // 单拍触发
    // 换图专属音效: 每张图一个音, 由 img_chime 给出
    input  wire [23:0] chime_step, // 相位步进, 0 = 不发声
    input  wire [15:0] chime_len,  // 时长(32kHz 采样数)
    input  wire       chime_trig,  // 单拍触发
    input  wire       mus_on,      // BGM 开关(1=播放)
    input  wire [1:0] mus_sel,     // BGM 曲目: 0=探索 1=战斗 2=胜利/结局
    output reg  [7:0] dac,         // 无符号 8 位 -> R-2R / PWM
    // 曝露内部状态给频谱彩条: 三个声部当前音号(0x7F=休止) 与 包络(0..255)
    output wire [6:0] note0,
    output wire [6:0] note1,
    output wire [6:0] note2,
    output wire [7:0] lev0,
    output wire [7:0] lev1,
    output wire [7:0] lev2
);
// 三路 assign 放在 nn0/env0 声明之后, 避免"先用后声明"的告警

    localparam integer DIV_S = CLK_HZ / SAMPLE_HZ;          // 40MHz/32kHz = 1250
    // 1/4 拍 = 60/(BPM*4) 秒, 即 CLK_HZ*15/BPM 个时钟。
    // 注意: 绝不能写成 (CLK_HZ*60)/(BPM*4)。40e6*60 = 2.4e9 会溢出 32 位
    //       integer(上限 2.147e9), 结果变成负数, 于是 btk 永远不触发、
    //       音符指针不动、三个声部全停在休止符 -> 整首 BGM 静音。
    localparam integer DIV_B = (CLK_HZ * 15) / BPM;         // 40e6*15/120 = 5,000,000
    localparam [7:0]   LOOP_LAST = LOOP_END;                // 参数不能直接位选

    //---------------------------------------------------------
    // 32kHz 采样节拍
    //---------------------------------------------------------
    reg [10:0] sdiv;
    wire stk = (sdiv == DIV_S - 1);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)           sdiv <= 11'd0;
        else if (stk)         sdiv <= 11'd0;
        else                  sdiv <= sdiv + 11'd1;
    end

    //---------------------------------------------------------
    // 音符节拍(1/4 拍)
    //---------------------------------------------------------
    reg [22:0] bdiv;
    wire btk = (bdiv == DIV_B - 1);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)           bdiv <= 23'd0;
        else if (btk)         bdiv <= 23'd0;
        else                  bdiv <= bdiv + 23'd1;
    end


    //---------------------------------------------------------
    // 上电自检音：已关闭（音箱通路 2026-10-29 实测打通）
    //   原来这里会响 6 秒"哆—咪—唆"，挡住 BGM 且干扰演示，
    //   现在阈值改 0 直接置 tdone=1，BGM 上电即播。
    //   要恢复自检把 28'd0 改回 28'd239_999_999 即可。
    //---------------------------------------------------------
    reg [27:0] tcnt;
    reg        tdone;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tcnt  <= 28'd0;
            tdone <= 1'b0;
        end else if (!tdone) begin
            if (tcnt >= 28'd0) tdone <= 1'b1;
            else               tcnt  <= tcnt + 28'd1;
        end
    end

    wire [2:0]  tseg  = (tcnt >= 28'd200_000_000) ? 3'd5 :
                        (tcnt >= 28'd160_000_000) ? 3'd4 :
                        (tcnt >= 28'd120_000_000) ? 3'd3 :
                        (tcnt >= 28'd80_000_000)  ? 3'd2 :
                        (tcnt >= 28'd40_000_000)  ? 3'd1 : 3'd0;
    wire [23:0] tstep = (tseg == 3'd0 || tseg == 3'd3) ? 24'd274203 :  // 523Hz C5
                        (tseg == 3'd1 || tseg == 3'd4) ? 24'd345506 :  // 659Hz E5
                                                        24'd411041;    // 784Hz G5

    reg [23:0] tph;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)             tph <= 24'd0;
        else if (stk && !tdone) tph <= tph + tstep;
    end

    wire [7:0] dtest = tph[23] ? 8'd240 : 8'd16;            // 满摆幅方波, 最响

    //---------------------------------------------------------
    // 音高表 / BGM 表
    //---------------------------------------------------------
    reg [23:0] pitch [0:127];
    initial $readmemh("D:/EG4S20_RPG_Game-main/rtl/gen/pitch.hex", pitch);

    // 三首 BGM 共 192 步: 轨 0=探索(0..63) 轨 1=战斗(64..127) 轨 2=胜利(128..191)
    reg [31:0] mus [0:191];
    initial $readmemh("D:/EG4S20_RPG_Game-main/rtl/gen/music.hex", mus);

    reg [31:0] mdat;
    reg [7:0]  mptr;
    reg [1:0]  mst;
    reg [1:0]  lcnt;
    reg [7:0]  mdur;
    reg [6:0]  nn0, nn1, nn2;
    reg [1:0]  sel_d;

    wire [7:0] mbase = {mus_sel, 6'd0};        // 曲目起始偏移 = mus_sel * 64

    localparam [1:0] M_LOAD = 2'd0, M_PLAY = 2'd1;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mdat <= 32'd0;
            mptr <= 8'd0;
            mst  <= M_LOAD;
            lcnt <= 2'd0;
            mdur <= 8'd1;
            nn0  <= 7'h7F;
            nn1  <= 7'h7F;
            nn2  <= 7'h7F;
            sel_d <= 2'd0;
        end else begin
            mdat  <= mus[mptr];                      // 同步读, 下一拍有效
            sel_d <= mus_sel;

            if (mus_sel != sel_d) begin              // 换曲: 立即跳到新曲开头
                mptr <= mbase;
                mst  <= M_LOAD;
                lcnt <= 2'd0;
            end else begin
                case (mst)
                M_LOAD: begin
                    if (lcnt >= 2'd2) begin          // 等 ROM 数据稳定
                        nn0  <= mdat[6:0];
                        nn1  <= mdat[13:7];
                        nn2  <= mdat[20:14];
                        mdur <= (mdat[27:21] == 7'd0) ? 8'd1 : {1'b0, mdat[27:21]};
                        lcnt <= 2'd0;
                        mst  <= M_PLAY;
                    end else begin
                        lcnt <= lcnt + 2'd1;
                    end
                end

                M_PLAY: begin
                    if (btk && mus_on && tdone) begin        // 上电即可起播
                        if (mdur <= 8'd1) begin
                            // 只在本轨 64 步内循环
                            mptr <= (mptr[5:0] >= 6'd63) ? mbase : (mptr + 8'd1);
                            lcnt <= 2'd0;
                            mst  <= M_LOAD;
                        end else begin
                            mdur <= mdur - 8'd1;
                        end
                    end
                end

                default: mst <= M_LOAD;
                endcase
            end
        end
    end

    //---------------------------------------------------------
    // 三路 PSG（相位累加器 24 位, 每采样推进一次）
    //---------------------------------------------------------
    wire [23:0] st0 = (nn0 == 7'h7F) ? 24'd0 : pitch[nn0];
    wire [23:0] st1 = (nn1 == 7'h7F) ? 24'd0 : pitch[nn1];
    wire [23:0] st2 = (nn2 == 7'h7F) ? 24'd0 : pitch[nn2];

    reg [23:0] ph0, ph1, ph2;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ph0 <= 24'd0; ph1 <= 24'd0; ph2 <= 24'd0;
        end else if (stk) begin
            ph0 <= ph0 + st0;
            ph1 <= ph1 + st1;
            ph2 <= ph2 + st2;
        end
    end

    // ch0: 方波 50%（主旋律）
    //   幅度从 40 提到 52: 音符包络平均增益约 0.75, 乘下来正好回到原来的响度
    wire signed [7:0] s0 = ph0[23] ? -8'sd52 : 8'sd52;
    // ch1: 方波 25%（和声, 音色更薄）
    wire signed [7:0] s1 = (ph1[23:22] == 2'b00) ? 8'sd28 : -8'sd28;
    // ch2: 三角波（低音）  tri 是 Verilog 关键字, 变量名改用 tri_v
    wire [5:0] tri_v = ph2[23] ? ~ph2[22:17] : ph2[22:17];
    wire signed [7:0] s2 = {2'b00, tri_v} - 8'sd32;         // -32 .. +31

    //---------------------------------------------------------
    // 音符包络 (起音 + 指数衰减)
    //
    //   ★ 为什么必须加: 方波一旦起振, 幅度就是恒定的。频谱彩条若直接从
    //     PCM 取包络, 得到的是一个"纹丝不动"的高度 —— 2026-10-29 离线
    //     仿真证实: 不加包络时, 8 根柱子在整首曲子里高度一个像素都不变
    //     (因为三个声部全程无休止, 能量恒定)。加上包络后每个音符都是
    //     "起音 → 衰减", 柱子才会跟着节奏跳, 音乐本身也更有颗粒感。
    //
    //   衰减: env -= (env >>> 14) + 1, 时间常数 16384 采样 ≈ 512ms
    //     "+1" 是线性尾: env 小于 16384 后移位结果为 0, 只靠这一项落地。
    //     少了它柱高会永久卡在非零值 (柱状图那边的包络踩过同样的坑)。
    //---------------------------------------------------------
    reg [17:0] env0, env1, env2;
    reg [7:0]  mptr_d;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) mptr_d <= 8'd0;
        else        mptr_d <= mptr;
    end

    wire note_new = (mptr != mptr_d);

    // 曝露给频谱彩条: 音号决定柱子位置, 包络决定柱高
    assign note0 = nn0;
    assign note1 = nn1;
    assign note2 = nn2;
    assign lev0  = env0[17:10];        // 与合成使用的 gain 同一路, 0..255
    assign lev1  = env1[17:10];
    assign lev2  = env2[17:10];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            env0 <= 18'd0;
            env1 <= 18'd0;
            env2 <= 18'd0;
        end else if (note_new) begin
            env0 <= 18'h3FFFF;
            env1 <= 18'h3FFFF;
            env2 <= 18'h3FFFF;
        end else if (stk) begin
            env0 <= env0 - ((env0 >> 14) + 18'd1);
            env1 <= env1 - ((env1 >> 14) + 18'd1);
            env2 <= env2 - ((env2 >> 14) + 18'd1);
        end
    end

    // 包络作用到三个声部: gain = env[17:10] (0..255), 8x8 乘后右移 8
    wire signed [15:0] p0 = s0 * $signed({1'b0, env0[17:10]});
    wire signed [15:0] p1 = s1 * $signed({1'b0, env1[17:10]});
    wire signed [15:0] p2 = s2 * $signed({1'b0, env2[17:10]});
    wire signed [7:0]  s0e = p0 >>> 8;
    wire signed [7:0]  s1e = p1 >>> 8;
    wire signed [7:0]  s2e = p2 >>> 8;

    //---------------------------------------------------------
    // 音效通道（15 种）
    //   step = 频率 * 2^24 / SAMPLE_HZ = 频率 * 524288
    //   etot = 时长(ms) * 32
    //---------------------------------------------------------
    reg [23:0] estep;
    reg [15:0] etot;

    always @(*) begin
        case (sfx_id)
            4'd1:  begin estep = 24'd629146;  etot = 16'd1120;  end // 1200Hz  35ms 按键
            4'd2:  begin estep = 24'd157286;  etot = 16'd3840;  end //  300Hz 120ms 受击
            4'd3:  begin estep = 24'd1048576; etot = 16'd1280;  end // 2000Hz  40ms 击杀
            4'd4:  begin estep = 24'd786432;  etot = 16'd6400;  end // 1500Hz 200ms 升级
            4'd5:  begin estep = 24'd104858;  etot = 16'd16000; end //  200Hz 500ms 阵亡
            4'd6:  begin estep = 24'd1258291; etot = 16'd8000;  end // 2400Hz 250ms 通关
            4'd7:  begin estep = 24'd524288;  etot = 16'd3840;  end // 1000Hz 120ms 自检
            4'd8:  begin estep = 24'd838861;  etot = 16'd3840;  end // 1600Hz 120ms 回血
            4'd9:  begin estep = 24'd1153434; etot = 16'd2560;  end // 2200Hz  80ms 购买
            4'd10: begin estep = 24'd209715;  etot = 16'd5760;  end //  400Hz 180ms 没钱
            4'd11: begin estep = 24'd943718;  etot = 16'd960;   end // 1800Hz  30ms 翻页
            4'd12: begin estep = 24'd83886;   etot = 16'd19200; end //  160Hz 600ms BOSS
            4'd13: begin estep = 24'd1363149; etot = 16'd2880;  end // 2600Hz  90ms 技能
            4'd14: begin estep = 24'd262144;  etot = 16'd7040;  end //  500Hz 220ms 失败
            4'd15: begin estep = 24'd1048576; etot = 16'd1920;  end // 2000Hz  60ms 逃跑成功
            default: begin estep = 24'd0;     etot = 16'd0;     end
        endcase
    end

    reg [23:0] ecnt_step;
    reg [15:0] eleft;
    reg [23:0] eph;
    reg        erun;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ecnt_step <= 24'd0;
            eleft     <= 16'd0;
            eph       <= 24'd0;
            erun      <= 1'b0;
        end else if (sfx_trig && estep != 24'd0) begin
            ecnt_step <= estep;
            eleft     <= (etot == 16'd0) ? 16'd1 : etot;
            eph       <= 24'd0;
            erun      <= 1'b1;
        end else if (erun && stk) begin
            eph <= eph + ecnt_step;
            if (eleft <= 16'd1) begin
                erun  <= 1'b0;
                eleft <= 16'd0;
            end else begin
                eleft <= eleft - 16'd1;
            end
        end
    end

    wire signed [7:0] sfx_wave = eph[23] ? -8'sd56 : 8'sd56;
    // 末 64 个采样淡出, 避免"咔"的爆音
    wire signed [7:0] s3 = (erun && (eleft > 16'd64)) ? sfx_wave :
                           ((erun && eleft[5]) ? (sfx_wave >>> 1) : 8'sd0);

    //---------------------------------------------------------
    // 换图音效通道（第 4 路，与 sfx 并存）
    //   每张图由 img_chime 给出 step/len，音高随图号变化
    //   不复用 sfx_id: 4bit 只有 15 个编号装不下 25 张图，
    //   而且换图音不应该顶掉受击/击杀这些游戏音效
    //---------------------------------------------------------
    reg [23:0] cstep;
    reg [15:0] cleft;
    reg [23:0] cph;
    reg        crun;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cstep <= 24'd0;
            cleft <= 16'd0;
            cph   <= 24'd0;
            crun  <= 1'b0;
        end else if (chime_trig && chime_step != 24'd0) begin
            cstep <= chime_step;
            cleft <= (chime_len == 16'd0) ? 16'd1 : chime_len;
            cph   <= 24'd0;
            crun  <= 1'b1;
        end else if (crun && stk) begin
            cph <= cph + cstep;
            if (cleft <= 16'd1) begin
                crun  <= 1'b0;
                cleft <= 16'd0;
            end else begin
                cleft <= cleft - 16'd1;
            end
        end
    end

    wire signed [7:0] chime_wave = cph[23] ? -8'sd44 : 8'sd44;
    wire signed [7:0] s4 = (crun && (cleft > 16'd96)) ? chime_wave :
                           ((crun && cleft[6]) ? (chime_wave >>> 1) : 8'sd0);

    //---------------------------------------------------------
    // 混音 + 居中 + 限幅（±120，约 94% 量程，AUX 输入足够响）
    //---------------------------------------------------------
    wire signed [9:0] mix  = {{2{s0e[7]}}, s0e} + {{2{s1e[7]}}, s1e}
                           + {{2{s2e[7]}}, s2e} + {{2{s3[7]}}, s3}
                           + {{2{s4[7]}}, s4};
    wire signed [9:0] mlim = (mix > 10'sd120)  ? 10'sd120 :
                             (mix < -10'sd120) ? -10'sd120 : mix;
    wire signed [9:0] mixc = mlim + 10'sd128;               // 8..248
    wire [7:0]        dmix = mixc[7:0];

    wire [7:0] dout = tdone ? dmix : dtest;                 // 自检结束后切 BGM

    reg [7:0] dprev;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dac   <= 8'd128;
            dprev <= 8'd128;
        end else if (stk) begin
            dprev <= dout;
            dac   <= ({1'b0, dout} + {1'b0, dprev}) >> 1;   // 2 点平均, 弱低通
        end
    end

endmodule



//=============================================================================
// note_bars —— 音高可视化彩条 (屏幕底部)
//
//   ★ 为什么不是频谱分析 (2026-10-29 实测结论, 不是猜的):
//     做过两版 8 段带通滤波器组, 拿真实 music.hex 跑离线仿真验证:
//       - 一阶 HP+LP (6dB/oct) 做 8 段: 同一频率下各段只差 1.2 倍,
//         800Hz 输入的峰值落在 346~457Hz 段, 峰位不随音高移动;
//       - 换 12 位定点系数把选择性做上去: 8 段 x 2 个乘法器吃满
//         EG4S20 全部 29 个 DSP, 布局拥塞, HDMI 的 200MHz 串行路径
//         违例 (WNS -1.456ns / TNS -15.174ns), 上板画面卡死。
//     根因是音源为方波: 边沿是宽带脉冲, 每个频段都能捞到能量。
//
//   ★ 做法:
//     三个声部各有音号 (MIDI) 和包络 (0..255):
//       音号 -> 8 根柱子之一 (每 6 个半音换一根)
//       包络 -> 柱高 (0..120)
//     命中的柱子满高, 左右隔壁给 1/4 高, 看起来像一根有宽度的峰。
//     三个声部取最大值, 所以和弦会点亮两三根柱子。
//     每根柱子再做 0.75/0.25 一阶平滑, 换音时不硬闪。
//
//   ★ 音域: 本工程音号 40(E2,82Hz) ~ 91(G6,1568Hz)
//       40~45 -> 柱0   46~51 -> 柱1   52~57 -> 柱2   58~63 -> 柱3
//       64~69 -> 柱4   70~75 -> 柱5   76~81 -> 柱6   82以上 -> 柱7
//=============================================================================
module note_bars (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [6:0]  n0,
    input  wire [6:0]  n1,
    input  wire [6:0]  n2,
    input  wire [7:0]  g0,
    input  wire [7:0]  g1,
    input  wire [7:0]  g2,
    output wire [63:0] bars
);

    //---------------------------------------------------------
    // 音号 -> 柱子序号 (每 6 个半音一根, 覆盖 E2..G6)
    //---------------------------------------------------------
    function [2:0] nidx;
        input [6:0] n;
        begin
            if      (n < 7'd46) nidx = 3'd0;
            else if (n < 7'd52) nidx = 3'd1;
            else if (n < 7'd58) nidx = 3'd2;
            else if (n < 7'd64) nidx = 3'd3;
            else if (n < 7'd70) nidx = 3'd4;
            else if (n < 7'd76) nidx = 3'd5;
            else if (n < 7'd82) nidx = 3'd6;
            else                nidx = 3'd7;
        end
    endfunction

    // 包络 -> 柱高: 255 折到 120, 给屏幕留空间
    function [7:0] lvl;
        input [7:0] g;
        begin
            lvl = (g >= 8'd240) ? 8'd120 : (g >> 1);
        end
    endfunction

    // 单个声部对第 j 根柱子的贡献: 正上方满高, 左右各一格 1/4 高
    //   idx 与 j 都用 4 位, 避免 idx+1 在 idx=7 时回绕到 0 误判成相邻
    function [7:0] hit;
        input [3:0] idx;
        input [7:0] e;
        input [3:0] j;
        begin
            if (e == 8'd0)                                    hit = 8'd0;
            else if (idx == j)                                hit = e;
            else if ((idx + 4'd1 == j) || (j + 4'd1 == idx))   hit = e >> 2;
            else                                              hit = 8'd0;
        end
    endfunction

    function [7:0] mx3;
        input [7:0] a;
        input [7:0] b;
        input [7:0] c;
        reg   [7:0] m;
        begin
            m   = (a > b) ? a : b;
            mx3 = (m > c) ? m : c;
        end
    endfunction

    // 休止符(0x7F)不点亮
    wire [3:0] I0 = (n0 == 7'h7F) ? 4'd15 : {1'b0, nidx(n0)};
    wire [3:0] I1 = (n1 == 7'h7F) ? 4'd15 : {1'b0, nidx(n1)};
    wire [3:0] I2 = (n2 == 7'h7F) ? 4'd15 : {1'b0, nidx(n2)};

    wire [7:0] e0 = (n0 == 7'h7F) ? 8'd0 : lvl(g0);
    wire [7:0] e1 = (n1 == 7'h7F) ? 8'd0 : lvl(g1);
    wire [7:0] e2 = (n2 == 7'h7F) ? 8'd0 : lvl(g2);

    // 每根柱子的目标高度
    wire [7:0] t0 = mx3(hit(I0, e0, 4'd0), hit(I1, e1, 4'd0), hit(I2, e2, 4'd0));
    wire [7:0] t1 = mx3(hit(I0, e0, 4'd1), hit(I1, e1, 4'd1), hit(I2, e2, 4'd1));
    wire [7:0] t2 = mx3(hit(I0, e0, 4'd2), hit(I1, e1, 4'd2), hit(I2, e2, 4'd2));
    wire [7:0] t3 = mx3(hit(I0, e0, 4'd3), hit(I1, e1, 4'd3), hit(I2, e2, 4'd3));
    wire [7:0] t4 = mx3(hit(I0, e0, 4'd4), hit(I1, e1, 4'd4), hit(I2, e2, 4'd4));
    wire [7:0] t5 = mx3(hit(I0, e0, 4'd5), hit(I1, e1, 4'd5), hit(I2, e2, 4'd5));
    wire [7:0] t6 = mx3(hit(I0, e0, 4'd6), hit(I1, e1, 4'd6), hit(I2, e2, 4'd6));
    wire [7:0] t7 = mx3(hit(I0, e0, 4'd7), hit(I1, e1, 4'd7), hit(I2, e2, 4'd7));

    //---------------------------------------------------------
    // 32kHz 更新节拍 + 0.75/0.25 一阶平滑
    //   b = (3*b + target) / 4, 时间常数约 4 帧 (125ms)
    //   ★ 三个 b 相加会到 765, 必须扩到 10 位再移位, 否则溢出回绕
    //---------------------------------------------------------
    reg [10:0] sdiv;
    wire stk = (sdiv == 11'd1249);          // 40MHz / 32kHz = 1250

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)   sdiv <= 11'd0;
        else if (stk) sdiv <= 11'd0;
        else          sdiv <= sdiv + 11'd1;
    end

    reg  [7:0] b0, b1, b2, b3, b4, b5, b6, b7;
    reg [11:0] s0, s1, s2, s3, s4, s5, s6, s7;

    always @(*) begin
            s0 = {2'b0, b0} + {2'b0, b0} + {2'b0, b0} + {2'b0, t0};
            s1 = {2'b0, b1} + {2'b0, b1} + {2'b0, b1} + {2'b0, t1};
            s2 = {2'b0, b2} + {2'b0, b2} + {2'b0, b2} + {2'b0, t2};
            s3 = {2'b0, b3} + {2'b0, b3} + {2'b0, b3} + {2'b0, t3};
            s4 = {2'b0, b4} + {2'b0, b4} + {2'b0, b4} + {2'b0, t4};
            s5 = {2'b0, b5} + {2'b0, b5} + {2'b0, b5} + {2'b0, t5};
            s6 = {2'b0, b6} + {2'b0, b6} + {2'b0, b6} + {2'b0, t6};
            s7 = {2'b0, b7} + {2'b0, b7} + {2'b0, b7} + {2'b0, t7};
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            b0 <= 8'd0; b1 <= 8'd0; b2 <= 8'd0; b3 <= 8'd0;
            b4 <= 8'd0; b5 <= 8'd0; b6 <= 8'd0; b7 <= 8'd0;
        end else if (stk) begin
            b0 <= s0[9:2];
            b1 <= s1[9:2];
            b2 <= s2[9:2];
            b3 <= s3[9:2];
            b4 <= s4[9:2];
            b5 <= s5[9:2];
            b6 <= s6[9:2];
            b7 <= s7[9:2];
        end
    end

    assign bars = {b7, b6, b5, b4, b3, b2, b1, b0};

endmodule

//=============================================================================
// sd_spi —— TF/SD 卡 SPI 模式驱动 (50MHz 系统时钟域)
//
//   引脚: 4 线 SPI —— SCLK / MOSI(CMD) / MISO(DAT0) / CS(DAT3)
//   时钟: 初始化阶段 390kHz, 初始化完成后默认 12.5MHz
//         SCLK 用使能门控产生 (不是分频时钟), 输出为寄存器, 无毛刺。
//
//   对上层 (sd_img) 只暴露两个动作:
//     init_go 脉冲 -> 完整初始化流程 -> init_done / err
//     rd_go 脉冲 + rd_addr(LBA) -> CMD17 读一个 512 字节块
//                                  -> dout/dvalid 逐字节流出 -> blk_done
//
//   支持 SDHC/SDXC (块寻址, CCS=1) 和 SDSC v1/v2 (字节寻址, 内部 <<9)。
//   CRC: SPI 模式默认关闭, 仅 CMD0(0x95) / CMD8(0x87) 需要正确 CRC。
//=============================================================================
`timescale 1ns/1ps
module sd_spi #(
    // 50MHz / (2*(FAST_DIV+1)); DIV=1 keeps ample physical-pin timing margin.
    // DIV=0 is a simulation candidate only: this engine changes MOSI at SCLK rise.
    parameter [7:0] FAST_DIV = 8'd1
) (
    input  wire        clk,          // 50MHz
    input  wire        rst_n,
    output reg         sd_sclk,
    output wire        sd_mosi,
    output reg         sd_cs_n,
    input  wire        sd_miso,

    input  wire        init_go,
    input  wire        rd_go,
    input  wire [31:0] rd_addr,      // LBA (SDHC); SDSC 时内部左移 9 位
    output reg         init_done,
    output reg         ccs,          // 1 = SDHC/SDXC (块寻址)
    output reg         err,

    output reg  [7:0]  dout,
    output reg         dvalid,       // 数据字节有效 (1 拍脉冲)
    output reg         blk_done,     // 一个 512 字节块完成 (1 拍脉冲)
    output reg  [4:0]  step,         // 初始化里程碑(sticky): 0=CMD0应答 1=CMD8 2=ACMD41就绪 3=CMD58 4=CMD16/SDHC
    output reg  [7:0]  r1b           // 最近一次 ACMD41 的 R1 原始字节 (诊断用)
);

    // ---- SCLK 分频: 半周期 = (div+1) 个 clk50 ----
    localparam [7:0] DIV_INIT = 8'd63;   // 50M/128 = 390.6kHz
    localparam [7:0] DIV_FAST = FAST_DIV; // default 50M/4 = 12.5MHz

    // ---- 命令分支码 (S_BR 用) ----
    localparam [1:0] BR_R1    = 2'd0;    // 只要 R1
    localparam [1:0] BR_RESP4 = 2'd1;    // R1 + 4 字节 (CMD8/CMD58)
    localparam [1:0] BR_DATA  = 2'd2;    // R1 + 数据块 (CMD17)

    // ---- 状态 ----
    localparam [4:0] S_IDLE=5'd0,  S_PUP=5'd1,  S_SEND6=5'd2, S_POLL=5'd3,
                     S_BR=5'd4,    S_GET4=5'd5, S_TOK=5'd6,   S_DATA=5'd7,
                     S_CRC2=5'd8,  S_GAPB=5'd9, S_RDFAIL=5'd10, S_ERR=5'd11,
                     S_C0CHK=5'd12, S_C8CHK=5'd13, S_A41R=5'd14,
                     S_C58CHK=5'd15, S_C16CHK=5'd16, S_DIV=5'd17,
                     S_READY=5'd18, S_A55R=5'd19, S_RDSTART=5'd20;

    // ---- 命令帧 (48 位) ----
    localparam [47:0] CMD0  = {8'h40, 32'h00000000, 8'h95};
    localparam [47:0] CMD8  = {8'h48, 32'h000001AA, 8'h87};
    localparam [47:0] CMD55 = {8'h77, 32'h00000000, 8'h01};
    localparam [47:0] C41V2 = {8'h69, 32'h40000000, 8'h01};  // ACMD41 HCS=1
    localparam [47:0] C41V1 = {8'h69, 32'h00000000, 8'h01};
    localparam [47:0] CMD58 = {8'h7A, 32'h00000000, 8'h01};
    localparam [47:0] CMD16 = {8'h50, 32'h00000200, 8'h01};  // 块长 512

    reg  [4:0]  state;
    reg  [4:0]  ret;          // 命令完成后的返回状态
    reg  [1:0]  br;           // 命令分支
    reg  [47:0] cmdsh;        // 命令移位
    reg  [2:0]  sendcnt;
    reg         sending;      // 正在发命令字节 (否则发 0xFF)
    reg  [7:0]  div;
    reg  [7:0]  dcnt;
    reg         sclk_r;
    reg         eng_act;      // 字节引擎移位中
    reg         eng_ld;       // 装载新字节 (1 拍脉冲)
    reg  [7:0]  eng_txi;      // 待装载字节
    reg  [7:0]  eng_sh;
    reg  [2:0]  eng_bit;
    reg  [7:0]  eng_rx;
    reg         eng_done_r;
    reg  [7:0]  retrycnt;     // CMD0 重试计数
    reg  [3:0]  pollcnt;      // R1 轮询计数 (最多 8 字节)
    reg  [1:0]  get4cnt;
    reg  [31:0] resp;         // 4 字节响应
    reg  [7:0]  r1;           // 保存 R1, 不被后续 R7/OCR 字节覆盖
    reg  [7:0]  pupcnt;
    reg  [15:0] acmdcnt;      // ACMD41 轮询次数
    reg  [19:0] tokcnt;       // 数据 token 等待上限
    reg  [8:0]  bytecnt;      // 块内字节计数
    reg  [1:0]  crccnt;
    reg         v2;           // SD v2.0 (支持 CMD8)
    reg  [31:0] rdaddr;       // 已换算的读地址

    assign sd_mosi = eng_act ? eng_sh[7] : 1'b1;

    //---------------------------------------------------------
    // 字节引擎: eng_ld 装载 1 字节 -> 8 个 SCLK 周期 -> eng_done 暂停等下一步
    //   Internal sclk_r falling phase samples MISO and advances MOSI.
    //   Registered sd_sclk follows sclk_r ONE clk later (20ns at 50MHz).
    //   At FAST_DIV=1: sample is 60ns after prior physical falling edge;
    //   MOSI changes 20ns after physical rise and 20ns before physical fall.
    //   At FAST_DIV=0: MOSI changes at physical rise (no setup/hold margin).
    //   Keep direct MISO sampling: adding synchronizer stages changes bit phase.
    //---------------------------------------------------------
    wire half = (dcnt == div);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sd_sclk   <= 1'b0;
            dcnt      <= 8'd0;
            sclk_r    <= 1'b0;
            eng_sh    <= 8'hFF;
            eng_bit   <= 3'd0;
            eng_rx    <= 8'hFF;
            eng_done_r<= 1'b0;
            eng_act   <= 1'b0;
        end else begin
            eng_done_r <= 1'b0;
            if (eng_ld) begin
                eng_sh  <= eng_txi;
                eng_bit <= 3'd0;
                dcnt    <= 8'd0;
                sclk_r  <= 1'b0;
                eng_act <= 1'b1;
            end else if (eng_act) begin
                if (half) begin
                    dcnt   <= 8'd0;
                    sclk_r <= ~sclk_r;
                    if (sclk_r) begin
                        // 下降沿: 采样 MISO + 移出下一位
                        eng_rx  <= {eng_rx[6:0], sd_miso};
                        eng_sh  <= {eng_sh[6:0], 1'b1};
                        eng_bit <= eng_bit + 3'd1;
                        if (eng_bit == 3'd7) begin
                            eng_act    <= 1'b0;      // 8 位完成, 暂停
                            eng_done_r <= 1'b1;
                        end
                    end
                end else
                    dcnt <= dcnt + 8'd1;
            end
            sd_sclk <= eng_act ? sclk_r : 1'b0;
        end
    end

    wire eng_done = eng_done_r;

    //---------------------------------------------------------
    // 主状态机
    //---------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= S_IDLE;
            ret       <= 5'd0;
            br        <= 2'd0;
            cmdsh     <= 48'd0;
            sendcnt   <= 3'd0;
            sending   <= 1'b0;
            div       <= DIV_INIT;
            eng_ld    <= 1'b0;   // eng_act 归字节引擎块管, 此处不能重复驱动 (TD Error 8007)
            eng_txi   <= 8'hFF;
            sd_cs_n   <= 1'b1;
            init_done <= 1'b0;
            ccs       <= 1'b0;
            err       <= 1'b0;
            dout      <= 8'd0;
            dvalid    <= 1'b0;
            blk_done  <= 1'b0;
            pollcnt   <= 4'd0;
            get4cnt   <= 2'd0;
            resp      <= 32'd0;
            r1        <= 8'hFF;
            r1b       <= 8'hFF;
            pupcnt    <= 8'd0;
            acmdcnt   <= 16'd0;
            tokcnt    <= 20'd0;
            bytecnt   <= 9'd0;
            crccnt    <= 2'd0;
            v2        <= 1'b0;
            retrycnt  <= 8'd0;
            step      <= 5'd0;
            rdaddr    <= 32'd0;
        end else begin
            dvalid   <= 1'b0;
            blk_done <= 1'b0;
            eng_ld   <= 1'b0;
            case (state)
                S_IDLE: begin
                    if (init_go) begin
                        init_done <= 1'b0;
                        err       <= 1'b0;
                        ccs       <= 1'b0;
                        v2        <= 1'b0;
                        div       <= DIV_INIT;
                        r1        <= 8'hFF;
                        r1b       <= 8'hFF;
                        retrycnt  <= 8'd0;
                        acmdcnt   <= 16'd0;
                        step      <= 5'd0;
                        sd_cs_n   <= 1'b1;
                        pupcnt    <= 8'd0;
                        eng_txi   <= 8'hFF;
                        eng_ld    <= 1'b1;
                        state     <= S_PUP;
                    end
                end

                // 上电 80 个时钟 (10 字节 0xFF), CS=1
                S_PUP: begin
                    if (eng_done) begin
                        if (pupcnt == 8'd9) begin
                            eng_txi <= 8'h40;             // CMD0 首字节
                            cmdsh   <= CMD0;
                            sending <= 1'b1;
                            sendcnt <= 3'd0;
                            ret     <= S_C0CHK;
                            br      <= BR_R1;
                            sd_cs_n <= 1'b0;
                            eng_ld  <= 1'b1;
                            state   <= S_SEND6;
                        end else begin
                            pupcnt  <= pupcnt + 8'd1;
                            eng_txi <= 8'hFF;
                            eng_ld  <= 1'b1;
                        end
                    end
                end

                // 发送 6 字节命令 (首字节已由调用者装载)
                S_SEND6: begin
                    if (eng_done) begin
                        if (sendcnt == 3'd5) begin
                            sending <= 1'b0;
                            pollcnt <= 4'd0;
                            eng_txi <= 8'hFF;             // 开始轮询 R1
                            eng_ld  <= 1'b1;
                            state   <= S_POLL;
                        end else begin
                            sendcnt <= sendcnt + 3'd1;
                            cmdsh   <= {cmdsh[39:0], 8'hFF};
                            eng_txi <= cmdsh[39:32];
                            eng_ld  <= 1'b1;
                        end
                    end
                end

                // 等 R1: 轮询最多 8 字节, 收到非 0xFF 即响应
                S_POLL: begin
                    if (eng_done) begin
                        if (eng_rx != 8'hFF) begin
                            r1    <= eng_rx;
                            state <= S_BR;
                        end else if (pollcnt == 4'd7) begin
                            sd_cs_n <= 1'b1;
                            err     <= 1'b1;
                            state   <= S_ERR;
                        end else begin
                            pollcnt <= pollcnt + 4'd1;
                            eng_txi <= 8'hFF;
                            eng_ld  <= 1'b1;
                        end
                    end
                end

                // R1 之后的分支
                S_BR: begin
                    case (br)
                        BR_R1: state <= ret;
                        BR_RESP4: begin
                            if ((ret == S_C8CHK) && (r1 == 8'h05)) begin
                                // v1 卡的 illegal-command R1 后没有 R7 数据。
                                state <= ret;
                            end else if (((ret == S_C8CHK) && (r1 != 8'h01)) ||
                                         ((ret == S_C58CHK) && (r1 != 8'h00))) begin
                                sd_cs_n <= 1'b1;
                                err     <= 1'b1;
                                state   <= S_ERR;
                            end else begin
                                get4cnt <= 2'd0;
                                eng_txi <= 8'hFF;
                                eng_ld  <= 1'b1;
                                state   <= S_GET4;
                            end
                        end
                        default: begin // BR_DATA
                            if (eng_rx == 8'h00) begin
                                tokcnt  <= 20'd0;
                                bytecnt <= 9'd0;
                                eng_txi <= 8'hFF;
                                eng_ld  <= 1'b1;
                                state   <= S_TOK;
                            end else begin
                                sd_cs_n <= 1'b1;
                                err     <= 1'b1;
                                state   <= S_ERR;
                            end
                        end
                    endcase
                end

                // 连续收 4 字节响应 (CMD8 回显 / CMD58 OCR)
                S_GET4: begin
                    if (eng_done) begin
                        resp <= {resp[23:0], eng_rx};
                        if (get4cnt == 2'd3) begin
                            state <= ret;
                        end else begin
                            get4cnt <= get4cnt + 2'd1;
                            eng_txi <= 8'hFF;
                            eng_ld  <= 1'b1;
                        end
                    end
                end

                // 等数据起始 token 0xFE
                S_TOK: begin
                    if (eng_done) begin
                        if (eng_rx == 8'hFE) begin
                            bytecnt <= 9'd0;
                            eng_txi <= 8'hFF;
                            eng_ld  <= 1'b1;
                            state   <= S_DATA;
                        end else if (tokcnt == 20'hFFFFF) begin
                            sd_cs_n <= 1'b1;
                            err     <= 1'b1;
                            state   <= S_ERR;
                        end else begin
                            tokcnt <= tokcnt + 20'd1;
                            eng_txi <= 8'hFF;
                            eng_ld  <= 1'b1;
                        end
                    end
                end

                // 数据块 512 字节逐字节流出
                S_DATA: begin
                    if (eng_done) begin
                        dout   <= eng_rx;
                        dvalid <= 1'b1;
                        bytecnt<= bytecnt + 9'd1;
                        if (bytecnt == 9'd511) begin
                            crccnt <= 2'd0;
                            eng_txi<= 8'hFF;
                            eng_ld <= 1'b1;
                            state  <= S_CRC2;
                        end else begin
                            eng_txi <= 8'hFF;
                            eng_ld  <= 1'b1;
                        end
                    end
                end

                // 2 字节 CRC (忽略)
                S_CRC2: begin
                    if (eng_done) begin
                        crccnt <= crccnt + 2'd1;
                        if (crccnt == 2'd1) begin
                            eng_txi <= 8'hFF;
                            eng_ld  <= 1'b1;
                            state   <= S_GAPB;
                        end else begin
                            eng_txi <= 8'hFF;
                            eng_ld  <= 1'b1;
                        end
                    end
                end

                // 收尾: 1 个哑字节, 释放 CS, 通知上层
                S_GAPB: begin
                    if (eng_done) begin
                        sd_cs_n  <= 1'b1;
                        blk_done <= 1'b1;
                        state    <= S_READY;
                    end
                end

                S_ERR: begin
                    sd_cs_n   <= 1'b1;
                    init_done <= 1'b0;
                    state     <= S_IDLE;               // 停机, 等上层重新 init_go
                end

                // ---- CMD0 返回: 应为 0x01 (idle) ----
                S_C0CHK: begin
                    if (eng_rx == 8'h01) begin
                        step[0]  <= 1'b1;         // 里程碑: 卡有应答 (电气连接 OK)
                        eng_txi <= 8'h48;             // CMD8 首字节
                        cmdsh   <= CMD8;
                        sending <= 1'b1;
                        sendcnt <= 3'd0;
                        ret     <= S_C8CHK;
                        br      <= BR_RESP4;
                        eng_ld  <= 1'b1;
                        state   <= S_SEND6;
                    end else if (retrycnt < 8'd200) begin
                        retrycnt <= retrycnt + 8'd1;
                        pupcnt   <= 8'd0;
                        sd_cs_n  <= 1'b1;
                        eng_txi  <= 8'hFF;
                        eng_ld   <= 1'b1;
                        state    <= S_PUP;
                    end else begin
                        sd_cs_n <= 1'b1;
                        err     <= 1'b1;
                        state   <= S_ERR;
                    end
                end

                // ---- CMD8 返回: 仅接受正确 R7 或 v1 的 illegal-command ----
                S_C8CHK: begin
                    if (((r1 == 8'h01) && (resp == 32'h000001AA)) ||
                        (r1 == 8'h05)) begin
                        step[1] <= 1'b1;
                        v2      <= (r1 == 8'h01);
                        eng_txi <= 8'h77;             // CMD55 首字节
                        cmdsh   <= CMD55;
                        sending <= 1'b1;
                        sendcnt <= 3'd0;
                        ret     <= S_A55R;
                        br      <= BR_R1;
                        eng_ld  <= 1'b1;
                        state   <= S_SEND6;
                    end else begin
                        sd_cs_n <= 1'b1;
                        err     <= 1'b1;
                        state   <= S_ERR;
                    end
                end

                // ---- CMD55 (APP_CMD) 返回: 紧接着发 ACMD41 ----
                // ★ 关键: CMD55 只是"预告下一条是应用命令", 真正的初始化由
                //   ACMD41 完成。原实现漏发 ACMD41, 只循环发 CMD55, 导致
                //   卡永远停在第 3 个里程碑之前 (只亮前两个方块)。
                S_A55R: begin
                    if ((r1 == 8'h00) || (r1 == 8'h01)) begin
                        eng_txi <= 8'h69;             // ACMD41 首字节
                        // 保留已在板上验证的 HCS 优先及超时回退策略。
                        cmdsh   <= (acmdcnt > 16'd4000) ? C41V1 : C41V2;
                        sending <= 1'b1;
                        sendcnt <= 3'd0;
                        ret     <= S_A41R;
                        br      <= BR_R1;
                        eng_ld  <= 1'b1;
                        state   <= S_SEND6;
                    end else begin
                        sd_cs_n <= 1'b1;
                        err     <= 1'b1;
                        state   <= S_ERR;
                    end
                end

                // ---- ACMD41 返回: 0x00 = 就绪 ----
                S_A41R: begin
                    r1b <= eng_rx;                    // 诊断: 记下 ACMD41 的 R1
                    if (eng_rx == 8'h00) begin
                        step[2]  <= 1'b1;         // 里程碑: 卡初始化完成 (就绪)
                        eng_txi <= 8'h7A;             // CMD58 首字节
                        cmdsh   <= CMD58;
                        sending <= 1'b1;
                        sendcnt <= 3'd0;
                        ret     <= S_C58CHK;
                        br      <= BR_RESP4;
                        eng_ld  <= 1'b1;
                        state   <= S_SEND6;
                    end else if (acmdcnt == 16'd20000) begin
                        sd_cs_n <= 1'b1;
                        err     <= 1'b1;
                        state   <= S_ERR;
                    end else begin
                        acmdcnt <= acmdcnt + 16'd1;
                        eng_txi <= 8'h77;             // 再来一轮 CMD55 -> ACMD41
                        cmdsh   <= CMD55;
                        sending <= 1'b1;
                        sendcnt <= 3'd0;
                        ret     <= S_A55R;
                        br      <= BR_R1;
                        eng_ld  <= 1'b1;
                        state   <= S_SEND6;
                    end
                end

                // ---- CMD58 返回: OCR -> 判断 SDHC ----
                S_C58CHK: begin
                    // OCR: 上电完成且支持 2.7--3.6V, 才能采用 CCS。
                    if ((r1 == 8'h00) && resp[31] &&
                        ((resp & 32'h00FF8000) != 32'd0)) begin
                        step[3] <= 1'b1;
                        ccs     <= resp[30];
                        if (resp[30]) begin
                            step[4] <= 1'b1;         // SDHC 无需 CMD16
                            state   <= S_DIV;
                        end else begin
                            eng_txi <= 8'h50;         // CMD16: SDSC 设块长 512
                            cmdsh   <= CMD16;
                            sending <= 1'b1;
                            sendcnt <= 3'd0;
                            ret     <= S_C16CHK;
                            br      <= BR_R1;
                            eng_ld  <= 1'b1;
                            state   <= S_SEND6;
                        end
                    end else begin
                        sd_cs_n <= 1'b1;
                        err     <= 1'b1;
                        state   <= S_ERR;
                    end
                end

                // ---- CMD16 返回 ----
                S_C16CHK: begin
                    if (eng_rx == 8'h00) begin
                        step[4]  <= 1'b1;         // 里程碑: 块长设置完成
                        state <= S_DIV;
                    end else begin
                        sd_cs_n <= 1'b1;
                        err     <= 1'b1;
                        state   <= S_ERR;
                    end
                end

                // ---- 初始化完成: 切高速时钟 ----
                S_DIV: begin
                    div       <= DIV_FAST;
                    init_done <= 1'b1;
                    sd_cs_n   <= 1'b1;
                    state     <= S_READY;
                end

                // ---- 就绪: 等待读块请求 ----
                //   init_go 也接受: 读块中途出错会走 S_ERR -> S_IDLE 停机,
                //   上层 sd_img 超时重试时发的 init_go 必须能把它拉起来。
                //   ★ 这里绝不能清 step: step 是"曾经成功过"的记录, 清掉会让
                //     诊断画面永远回到全暗, 而且 sd_img 每轮重试都会发 init_go,
                //     会形成"初始化成功->被重置->再初始化"的无尽循环。
                S_READY: begin
                    sd_cs_n <= 1'b1;
                    if (init_go && !rd_go) begin
                        init_done <= 1'b0;
                        err       <= 1'b0;
                        ccs       <= 1'b0;
                        v2        <= 1'b0;
                        div       <= DIV_INIT;
                        r1        <= 8'hFF;
                        r1b       <= 8'hFF;
                        retrycnt  <= 8'd0;
                        acmdcnt   <= 16'd0;
                        pupcnt    <= 8'd0;
                        eng_txi   <= 8'hFF;
                        eng_ld    <= 1'b1;
                        state     <= S_PUP;
                    end else if (rd_go) begin
                        // 请求这一拍锁存, SDSC LBA 换算成字节地址 (<<9)。
                        rdaddr <= ccs ? rd_addr : {rd_addr[22:0], 9'd0};
                        state  <= S_RDSTART;
                    end
                end

                // 下一拍再组帧, 避免 NBA 读取上一次请求的 rdaddr。
                S_RDSTART: begin
                    eng_txi <= 8'h51;                 // CMD17 首字节
                    cmdsh   <= {8'h51, rdaddr, 8'h01};
                    sending <= 1'b1;
                    sendcnt <= 3'd0;
                    ret     <= S_READY;
                    br      <= BR_DATA;
                    sd_cs_n <= 1'b0;
                    eng_ld  <= 1'b1;
                    state   <= S_SEND6;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule

//=============================================================================
// sd_img —— TF 卡 FAT32 找 BMP -> 256x192 缩略图写入 tf_ram (50MHz 时钟域)
//
//   流程: 发起 sd_spi 初始化(失败 3s 后自动重试) -> MBR 找 FAT32 分区
//         -> BPB -> 根目录簇链收集最多32个 .BMP (8.3文件名), 排序后自动加载0
//         -> ANIMdddd优先, 其余文件名字典序; load_go/index选择后续图片
//         -> 沿 FAT 簇链读文件 -> 解析 BMP 头(24bpp 非压缩)
//         -> 逐像素抽取缩略图 (加法器抽点, 零乘法器)
//         -> RGB888 高 4 位查 4096 项调色板 ROM -> 写 tf_ram -> tf_valid
//
//   出错 (tf_err): 1=无卡/初始化失败 2=没有 BMP 3=格式/索引不符。
//   挂载/无文件/I/O错误3秒后重新扫描; 格式/索引错误保留目录并立即接受后续load_go。
//   支持首个MBR分区或无分区表FAT32, 512字节扇区。
//   BMP: 24bpp BI_RGB, 256<=宽<=65535, 192<=绝对高度<=65535。
//=============================================================================
module sd_img #(
    parameter integer RETRY_TICKS = 150_000_000,
    parameter integer FULL_FRAME = 0
) (
    input  wire        clk,          // 50MHz, 与 sd_spi 同域
    input  wire        rst_n,

    output reg         init_go,
    input  wire        init_done,
    input  wire        init_err,

    output reg         rd_go,
    output reg  [31:0] rd_addr,
    input  wire [7:0]  dout,
    input  wire        dvalid,
    input  wire        blk_done,

    // 缩略图写口 -> tf_ram (双时钟 BRAM, 读侧在视频时钟域)
    output reg  [15:0] tw_addr,
    output reg  [3:0]  tw_data,
    output reg         tw_wren,
    output reg         tf_valid,     // 1 = tf_ram 内容有效
    output reg  [1:0]  tf_err,       // 0无 1无卡 2无BMP 3格式不符
    output wire [1:0]  fdiag,        // 文件层里程碑: 0=目录里找到BMP 1=图片已写入
    input  wire [2:0]  dsel,         // 诊断轮询选择 0..5=BPB偏移11/12/13/14/15/36, 6=MBR类型, 7=状态
    output wire [7:0]  dbg,          // 被选中的诊断字节
    input  wire        load_go,
    input  wire        cancel_go,
    output reg         load_cancelled,
    input  wire [5:0]  load_index,
    output reg  [5:0]  file_count, seq_count, shown_index,
    output reg  [63:0] shown_name,  // eight basename bytes, MSB first
    output reg         cat_ready, busy, load_done,
    output reg  [15:0] src_width, src_height,
    output reg fb_start, fb_pixel_valid,
    output reg [18:0] fb_pixel_addr,
    output reg [23:0] fb_pixel_data
);

    // Original diagnostic state numbers 0..14 are retained.
    localparam [4:0] S_W0=5'd0,  S_WI=5'd1,  S_MBRI=5'd2, S_MBRW=5'd3,
                     S_MBRE=5'd4, S_BPBI=5'd5, S_BPBW=5'd6, S_BPBE=5'd7,
                     S_DREAD=5'd8, S_DWAIT=5'd9, S_FATI=5'd10, S_FATW=5'd11,
                     S_FATE=5'd12, S_DONE=5'd13, S_ERRW=5'd14,
                     S_SORT=5'd15, S_LOAD=5'd16;

    localparam [1:0] CH_ROOT = 2'd0, CH_FILE = 2'd1;

    reg  [4:0]  state;
    reg  [1:0]  chain;

    // One 512x8 synchronous RAM uses the remaining block RAM. Entries are
    // serialized as {basename64, cluster32, size32}; no array reset or wide mux.
    reg [7:0] catalog_mem [0:511];
    reg [7:0] cat_q;
    reg cat_start, cat_cmd_write;
    reg [4:0] cat_cmd_index;
    reg [127:0] cat_cmd_data;
    reg cat_busy, cat_done, cat_write, cat_phase;
    reg [4:0] cat_entry;
    reg [3:0] cat_byte;
    reg [127:0] cat_shift, cat_result;
    wire [8:0] cat_addr = {cat_entry, cat_byte};
    wire cat_we = cat_busy && cat_write;
    always @(posedge clk) begin
        if (cat_we) catalog_mem[cat_addr] <= cat_shift[127:120];
        cat_q <= catalog_mem[cat_addr];
    end
    // A write takes 16 cycles; a read takes 32 to respect synchronous latency.
    // Directory entries arrive at least 32 clocks apart, so no sector buffer
    // or backpressure is needed while the directory stream is being scanned.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cat_busy <= 1'b0;
            cat_done <= 1'b0;
            cat_write <= 1'b0;
            cat_phase <= 1'b0;
            cat_entry <= 5'd0;
            cat_byte <= 4'd0;
            cat_shift <= 128'd0;
            cat_result <= 128'd0;
        end else begin
            cat_done <= 1'b0;
            if (cat_start && !cat_busy) begin
                cat_busy <= 1'b1;
                cat_write <= cat_cmd_write;
                cat_entry <= cat_cmd_index;
                cat_byte <= 4'd0;
                cat_phase <= 1'b0;
                cat_shift <= cat_cmd_data;
            end else if (cat_busy) begin
                if (cat_write) begin
                    cat_shift <= {cat_shift[119:0], 8'd0};
                    if (cat_byte == 4'd15) begin
                        cat_busy <= 1'b0;
                        cat_done <= 1'b1;
                    end else cat_byte <= cat_byte + 4'd1;
                end else if (!cat_phase) begin
                    cat_phase <= 1'b1;
                end else begin
                    cat_result <= {cat_result[119:0], cat_q};
                    cat_phase <= 1'b0;
                    if (cat_byte == 4'd15) begin
                        cat_busy <= 1'b0;
                        cat_done <= 1'b1;
                    end else cat_byte <= cat_byte + 4'd1;
                end
            end
        end
    end
    reg [63:0] ename;
    reg [5:0] sort_pos, sort_pass, active_index;
    reg [2:0] sort_phase;
    reg [1:0] load_phase;
    reg [127:0] sort_a, selected_file;
    reg load_held, load_pending;
    reg cancel_pending;
    // Optional legacy input must not turn floating Z into a cancellation.
    wire cancel_active = cat_ready && load_pending &&
        (cancel_pending || (cancel_go === 1'b1));
    function anim_name;
        input [63:0] name;
        begin
            anim_name = name[63:32] == 32'h414E494D &&
                name[31:24] >= "0" && name[31:24] <= "9" &&
                name[23:16] >= "0" && name[23:16] <= "9" &&
                name[15:8] >= "0" && name[15:8] <= "9" &&
                name[7:0] >= "0" && name[7:0] <= "9";
        end
    endfunction
    wire swap_pair = (!anim_name(sort_a[127:64]) && anim_name(cat_result[127:64])) ||
        (anim_name(sort_a[127:64]) == anim_name(cat_result[127:64]) &&
         sort_a[127:64] > cat_result[127:64]);
    reg  [8:0]  cnt;           // 扇区内字节计数
    reg  [28:0] wt;            // 等待计数器 (29位容纳10秒=500_000_000拍)

    // ---- 分区 / 卷参数 ----
    reg  [31:0] vol, fat_lba, data_lba;
    reg  [7:0]  mbr_type;
    reg  [31:0] mbr_lba;
    reg  [7:0]  bps_lo, bps_hi;
    reg  [7:0]  spc;           // 每簇扇区数 (1/2/4/8/16/32/64/128)
    reg  [15:0] rsvd;
    reg  [7:0]  nfats;
    reg  [31:0] fatsz;
    reg  [31:0] rootclus;
    // 第 0 扇区自身像不像 FAT32 BPB (超级软盘格式, 无分区表)
    reg  [7:0]  bps0_lo, bps0_hi;
    reg  [39:0] f32txt;
    reg         mbr_bad;       // sticky: MBR 类型不被接受 (诊断显示类型值)
    reg  [23:0] tmo;           // 等待 blk_done 的超时计数 (50MHz -> 335ms 满量程)

    // ---- 簇链 ----
    reg  [31:0] cur_clus;
    reg  [7:0]  sec;
    reg  [31:0] fatent;
    reg  [8:0]  fat_off;

    // ---- 目录项捕获 ----
    reg  [7:0]  e0, eattr;
    reg  [23:0] ext;
    reg  [15:0] eclus;         // 首簇低 16 位 (偏移 26/27)
    reg  [15:0] echi;          // 首簇高 16 位 (偏移 20/21, FAT32)
    reg  [31:0] esize;
    reg         is_bmp, dir_end;
    reg         bmp_fnd;       // 整个目录扫描的 sticky 命中标志
    reg  [31:0] fcl;           // 命中项首簇 (32 位!)
    reg  [31:0] fsz;           // 命中项文件大小

    assign fdiag = {tf_valid, bmp_fnd};   // 供诊断画面显示

    //---------------------------------------------------------
    // 诊断: 把"看不见的寄存器"搬到画面上, 一眼看出卡在哪个字段
    //   0..5 = 最近一次BPB的第11/12/13/14/15/36字节, 跨状态保持
    //          (BPB 时: 每扇区字节数低/高、每簇扇区数、保留扇区低/高、FAT大小低)
    //   6    = 第 0 扇区偏移 450 (MBR 分区类型, 期望 0x0C/0x0B)
    //   7    = 状态机编号 (7=BPB校验瞬态, 14=出错等待)
    //   字段保持显示, 不用A5哨兵覆盖; 顶层在轮询项间消隐。
    //---------------------------------------------------------
    reg  [7:0] b11, b12, b13, b14, b15, b36, b450;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            b11 <= 8'h00; b12 <= 8'h00; b13 <= 8'h00; b14 <= 8'h00;
            b15 <= 8'h00; b36 <= 8'h00; b450 <= 8'h00;
        end else if (dvalid && (state == S_BPBW)) begin
            if (cnt == 9'd11)  b11  <= dout;
            if (cnt == 9'd12)  b12  <= dout;
            if (cnt == 9'd13)  b13  <= dout;
            if (cnt == 9'd14)  b14  <= dout;
            if (cnt == 9'd15)  b15  <= dout;
            if (cnt == 9'd36)  b36  <= dout;
        end else if (dvalid && state == S_MBRW && cnt == 9'd450) begin
            b450 <= dout;
        end
    end

    assign dbg = (dsel == 3'd0) ? b11 :
                 (dsel == 3'd1) ? b12 :
                 (dsel == 3'd2) ? b13 :
                 (dsel == 3'd3) ? b14 :
                 (dsel == 3'd4) ? b15 :
                 (dsel == 3'd5) ? b36 :
                 (dsel == 3'd6) ? b450 :
                                  {3'd0, state};

    // 第 0 扇区直接是 FAT32 BPB 的特征: 每扇区 512 字节 + 偏移 82..86 == "FAT32"
    wire s0_is_bpb = (bps0_lo == 8'h00) && (bps0_hi == 8'h02) &&
                     (f32txt == 40'h46_41_54_33_32);

    // ---- BMP 头 ----
    reg  [7:0]  sig0, sig1, bpp_lo, bpp_hi;
    reg  [31:0] pixoff, wpx, hpx;
    reg  [31:0] dibsz, compression;
    reg  [15:0] planes;
    reg  [31:0] esz;           // 文件大小 (来自目录项)
    reg         hdr_ok, hdr_bad, hneg;
    reg  [31:0] habs, rowsize;
    reg  [31:0] fbc;           // 文件内绝对字节

    // ---- 像素抽取 ----
    reg  [15:0] x;
    reg  [16:0] accx, accy;
    reg  [7:0]  tx, ty, rowty;
    reg  [1:0]  p;             // RGB 相位 0=B 1=G 2=R
    reg  [7:0]  breg, greg;
    reg  [1:0]  padcnt;
    reg  [31:0] row_cnt;
    reg         done_pend;

    // ---- 调色板映射 ROM (4096 x 4bit, tools/gen_tfmap.py 生成) ----
    reg  [3:0]  cmap [0:4095];
    initial $readmemh("D:/EG4S20_RPG_Game-main/rtl/gen/tf_map.hex", cmap);
    wire [11:0] cm_a = {dout[7:4], greg[7:4], breg[7:4]};   // R,G,B 高 4 位
    wire [3:0]  cidx = cmap[cm_a];

    //---------------------------------------------------------
    // 组合: 卷布局计算
    //---------------------------------------------------------
    wire [31:0] fatsz_nf = (nfats[0] ? fatsz          : 32'd0) +
                           (nfats[1] ? {fatsz[30:0],1'b0}   : 32'd0) +
                           (nfats[2] ? {fatsz[29:0],2'b00}  : 32'd0) +
                           (nfats[3] ? {fatsz[28:0],3'b000} : 32'd0) +
                           (nfats[4] ? {fatsz[27:0],4'b0}   : 32'd0) +
                           (nfats[5] ? {fatsz[26:0],5'b0}   : 32'd0) +
                           (nfats[6] ? {fatsz[25:0],6'b0}   : 32'd0) +
                           (nfats[7] ? {fatsz[24:0],7'b0}   : 32'd0);

    // 簇内偏移 = (cur_clus-2) << log2(spc)
    wire [31:0] cm2   = cur_clus - 32'd2;
    reg  [31:0] clusoff;
    always @(*) begin
        case (spc)
            8'd1:    clusoff = cm2;
            8'd2:    clusoff = {cm2[30:0], 1'b0};
            8'd4:    clusoff = {cm2[29:0], 2'b00};
            8'd8:    clusoff = {cm2[28:0], 3'b000};
            8'd16:   clusoff = {cm2[27:0], 4'b0000};
            8'd32:   clusoff = {cm2[26:0], 5'b00000};
            8'd64:   clusoff = {cm2[25:0], 6'b000000};
            default: clusoff = {cm2[24:0], 7'b0000000};
        endcase
    end

    // FAT 项地址: FAT 表内偏移 = 簇号*4 字节 -> 扇区 = 簇号*4/512 = 簇号>>7
    wire [31:0] fat_sec = fat_lba + {7'd0, cur_clus[31:7]};

    // 绝对高度 (BMP 头高度可为负 = 自上而下存储)
    wire [31:0] habs_c = hpx[31] ? (32'd0 - hpx) : hpx;

    // ---- 每行填充字节 rowsize - 3W (0..3) ----
    wire [31:0] rowbytes = {wpx[30:0], 1'b0} + wpx;          // 3W
    wire [1:0]  padsz    = rowsize[1:0] - rowbytes[1:0];
    wire [16:0] accx_sum = accx + 17'd256;
    wire [16:0] accy_sum = accy + 18'd192;
    wire [8:0] raw_y = hneg ? row_cnt[8:0] : 9'd479-row_cnt[8:0];
    wire [18:0] raw_addr = {raw_y,9'b0}+{raw_y,7'b0}+{3'd0,x};
    wire [31:0] fat_next = {4'd0, fatent[27:0]};

    //---------------------------------------------------------
    // 主状态机
    //---------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fb_start<=0;fb_pixel_valid<=0;fb_pixel_addr<=0;fb_pixel_data<=0;
            state    <= S_W0;
            chain    <= CH_ROOT;
            cat_start <= 1'b0;
            cat_cmd_write <= 1'b0;
            cat_cmd_index <= 5'd0;
            cat_cmd_data <= 128'd0;
            sort_phase <= 3'd0;
            load_phase <= 2'd0;
            sort_a <= 128'd0;
            selected_file <= 128'd0;
            ename <= 64'd0;
            file_count <= 6'd0;
            seq_count <= 6'd0;
            shown_index <= 6'd0;
            shown_name <= 64'd0;
            src_width <= 16'd0;
            src_height <= 16'd0;
            cat_ready <= 1'b0;
            busy <= 1'b1;
            load_done <= 1'b0;
            load_cancelled <= 1'b0;
            cancel_pending <= 1'b0;
            load_pending <= 1'b0;
            load_held <= 1'b0;
            sort_pos <= 6'd0;
            sort_pass <= 6'd0;
            active_index <= 6'd0;
            init_go  <= 1'b0;
            rd_go    <= 1'b0;
            rd_addr  <= 32'd0;
            tw_wren  <= 1'b0;
            tf_valid <= 1'b0;
            tf_err   <= 2'd0;
            cnt      <= 9'd0;
            wt       <= 29'd0;
            hdr_ok   <= 1'b0;
            hdr_bad  <= 1'b0;
            fbc      <= 32'd0;
            p        <= 2'd0;
            padcnt   <= 2'd0;
            row_cnt  <= 32'd0;
            done_pend<= 1'b0;
            dir_end  <= 1'b0;
            is_bmp   <= 1'b0;
            mbr_bad  <= 1'b0;
            tmo      <= 24'd0;
            bps0_lo  <= 8'd0;
            bps0_hi  <= 8'd0;
            f32txt   <= 40'd0;
            fatent   <= 32'h0FFFFFF8;   // 复位即"链结束", 避免未初始化
            fcl      <= 32'd0;
            fsz      <= 32'd0;
            esz      <= 32'd0;
            bmp_fnd  <= 1'b0;
            mbr_type <= 8'd0;
            mbr_lba  <= 32'd0;
        end else begin
            init_go <= 1'b0;
            rd_go   <= 1'b0;
            tw_wren <= 1'b0;
            fb_start<=0;fb_pixel_valid<=0;
            load_done <= 1'b0;
            load_cancelled <= 1'b0;
            cat_start <= 1'b0;
            load_held <= (load_go === 1'b1);
            if (cancel_active) begin
                // Never interrupt an SD transaction. blk_done follows all 512
                // data bytes and both CRC bytes; no following sector is issued.
                cancel_pending <= 1'b1;
                if ((state != S_DWAIT && state != S_FATW) || blk_done ||
                    init_err || !init_done || tmo == 24'hffffff) begin
                    cancel_pending <= 1'b0;
                    load_pending <= 1'b0;
                    busy <= 1'b0;
                    tf_valid <= 1'b0;
                    tf_err <= 2'd0;
                    load_done <= 1'b1;
                    load_cancelled <= 1'b1;
                    state <= S_DONE;
                end else if (dvalid) tmo <= 24'd0;
                else tmo <= tmo + 24'd1;
            end else case (state)
                // 发起 (或重试) 初始化
                //   ★ 只有 sd_spi 确实死掉(init_done=0 且 err=0, 即 S_IDLE 停机)才需要重新拉起;
                //     若它已经在跑或已经就绪, 无脑发 init_go 会把它反复打回初始化流程。
                S_W0: begin
                    file_count <= 6'd0;
                    seq_count <= 6'd0;
                    cat_ready <= 1'b0;
                    busy <= 1'b1;
                    load_pending <= 1'b0;
                    tf_valid <= 1'b0;
                    tf_err   <= 2'd0;
                    bmp_fnd  <= 1'b0;
                    mbr_bad  <= 1'b0;
                    wt       <= 29'd0;
                    if (!init_done) init_go <= 1'b1;   // 未就绪才拉起, 已就绪绝不打扰
                    state    <= S_WI;
                end

                S_WI: begin
                    if (init_done) begin
                        cnt   <= 9'd0;
                        state <= S_MBRI;
                    end else if (init_err) begin
                        tf_err <= 2'd1;
                        busy <= 1'b0;
                        if (wt >= RETRY_TICKS - 1) begin   // 3s retry
                            state <= S_W0;
                        end else
                            wt <= wt + 29'd1;
                    end else begin
                        // 既没完成也没报错: sd_spi 正在初始化, 给足耐心, 不要催
                        if (wt == 29'd500_000_000) begin
                            tf_err <= 2'd1;
                            wt     <= 29'd0;
                            state  <= S_W0;
                        end else
                            wt <= wt + 29'd1;
                    end
                end

                // ---- MBR ----
                S_MBRI: begin
                    rd_addr <= 32'd0;
                    rd_go   <= 1'b1;
                    cnt     <= 9'd0;
                    tmo     <= 24'd0;
                    state   <= S_MBRW;
                end

                S_MBRW: begin
                    if (dvalid) begin
                        cnt <= cnt + 9'd1;
                        case (cnt)
                            9'd11: bps0_lo <= dout;          // 第0扇区自身是否像 BPB
                            9'd12: bps0_hi <= dout;
                            9'd82: f32txt <= {f32txt[31:0], dout};
                            9'd83: f32txt <= {f32txt[31:0], dout};
                            9'd84: f32txt <= {f32txt[31:0], dout};
                            9'd85: f32txt <= {f32txt[31:0], dout};
                            9'd86: f32txt <= {f32txt[31:0], dout};   // "FAT32"
                            9'd450: mbr_type <= dout;
                            9'd454: mbr_lba[7:0]   <= dout;   // 小端序
                            9'd455: mbr_lba[15:8]  <= dout;
                            9'd456: mbr_lba[23:16] <= dout;
                            9'd457: mbr_lba[31:24] <= dout;
                            default: ;
                        endcase
                    end
                    if (blk_done) state <= S_MBRE;
                    else if (tmo == 24'hFFFFFF || init_err || !init_done) begin
                        tf_err <= 2'd1;                    // 读块无应答
                        wt     <= 29'd0;
                        state  <= S_ERRW;
                    end else
                        tmo <= tmo + 24'd1;
                end

                S_MBRE: begin
                    if (mbr_type == 8'h0B || mbr_type == 8'h0C) begin
                        vol   <= mbr_lba;
                        rd_addr <= mbr_lba;
                        rd_go <= 1'b1;
                        cnt   <= 9'd0;
                        tmo   <= 24'd0;
                        state <= S_BPBW;
                    end else if (s0_is_bpb) begin
                        // 无分区表: 第 0 扇区直接就是 FAT32 引导扇区
                        vol   <= 32'd0;
                        rd_addr <= 32'd0;
                        rd_go <= 1'b1;
                        cnt   <= 9'd0;
                        tmo   <= 24'd0;
                        state <= S_BPBW;
                    end else begin
                        tf_err  <= 2'd3;
                        mbr_bad <= 1'b1;
                        wt      <= 29'd0;
                        state   <= S_ERRW;
                    end
                end

                // ---- BPB ----
                S_BPBW: begin
                    if (dvalid) begin
                        cnt <= cnt + 9'd1;
                        case (cnt)
                            9'd11:    bps_lo <= dout;            // 每扇区字节数(小端)
                            9'd12:    bps_hi <= dout;
                            9'd13:    spc      <= dout;
                            9'd14:    rsvd[7:0]   <= dout;    // 保留扇区数(小端)
                            9'd15:    rsvd[15:8]  <= dout;
                            9'd16:    nfats     <= dout;
                            9'd36:    fatsz[7:0]   <= dout;   // 每 FAT 扇区数(小端)
                            9'd37:    fatsz[15:8]  <= dout;
                            9'd38:    fatsz[23:16] <= dout;
                            9'd39:    fatsz[31:24] <= dout;
                            9'd44:    rootclus[7:0]   <= dout;
                            9'd45:    rootclus[15:8]  <= dout;
                            9'd46:    rootclus[23:16] <= dout;
                            9'd47:    rootclus[31:24] <= dout;
                            default: ;
                        endcase
                    end
                    if (blk_done) state <= S_BPBE;
                    else if (tmo == 24'hFFFFFF || init_err || !init_done) begin
                        tf_err <= 2'd1;
                        wt     <= 29'd0;
                        state  <= S_ERRW;
                    end else
                        tmo <= tmo + 24'd1;
                end

                S_BPBE: begin
                    // 校验受支持的FAT32布局: 512字节扇区, 每簇1..128个扇区且为2的幂。
                    if (bps_lo == 8'h00 && bps_hi == 8'h02 && nfats != 8'd0 &&
                        fatsz != 32'd0 && rootclus >= 32'd2 &&
                        (spc != 8'd0 && (spc & (spc - 8'd1)) == 8'd0)) begin
                        fat_lba  <= vol + {16'd0, rsvd};
                        data_lba <= vol + {16'd0, rsvd} + fatsz_nf;
                        cur_clus <= {4'd0, rootclus[27:0]};
                        dir_end  <= 1'b0;
                        sec      <= 8'd0;
                        chain    <= CH_ROOT;
                        cnt      <= 9'd0;
                        tmo      <= 24'd0;
                        state    <= S_DREAD;
                    end else begin
                        tf_err <= 2'd3;
                        wt     <= 29'd0;
                        state  <= S_ERRW;
                    end
                end

                // ---- 读一个簇内扇区 ----
                S_DREAD: begin
                    rd_addr <= data_lba + clusoff + {24'd0, sec};
                    rd_go   <= 1'b1;
                    cnt     <= 9'd0;
                    tmo     <= 24'd0;
                    state   <= S_DWAIT;
                end

                // ---- 扇区流: 目录扫描 或 文件像素 ----
                S_DWAIT: begin
                    if (dvalid) begin
                        cnt <= cnt + 9'd1;
                        if (chain == CH_ROOT) begin
                            if (file_count < 6'd32 && !dir_end) begin
                            //---------------------------------------------
                            // 目录项扫描 (16 项 x 32 字节)
                            //---------------------------------------------
                            case (cnt[4:0])
                                5'd0: begin
                                    e0      <= dout;
                                    ename   <= {56'd0, dout};
                                    is_bmp  <= 1'b0;       // 每个目录项重判
                                    if (dout == 8'h00) dir_end <= 1'b1;
                                end
                                5'd1, 5'd2, 5'd3, 5'd4, 5'd5, 5'd6, 5'd7:
                                    ename <= {ename[55:0], dout};
                                5'd8:  ext[23:16] <= dout;   // 'B'
                                5'd9:  ext[15:8]  <= dout;   // 'M'
                                5'd10: ext[7:0]   <= dout;   // 'P'
                                5'd11: begin
                                    eattr <= dout;
                                    // 普通文件(非卷标 bit3 / 目录 bit4)且扩展名 BMP
                                    if (ext == 24'h424D50 && dout[4:3] == 2'b00 &&
                                        e0 != 8'hE5 && e0 != 8'h00)
                                        is_bmp <= 1'b1;
                                end
                                5'd20: echi[7:0]   <= dout;  // 首簇高字 (FAT32)
                                5'd21: echi[15:8]  <= dout;
                                5'd26: eclus[7:0]   <= dout;  // 首簇低位在前
                                5'd27: begin
                                    eclus[15:8] <= dout;
                                    if (is_bmp) fcl <= {4'd0, echi[11:0], dout, eclus[7:0]};
                                end
                                5'd28: esize[7:0]   <= dout;
                                5'd29: esize[15:8]  <= dout;
                                5'd30: esize[23:16] <= dout;
                                5'd31: begin
                                    esize[31:24] <= dout;
                                    if (is_bmp) begin
                                        cat_start <= 1'b1;
                                        cat_cmd_write <= 1'b1;
                                        cat_cmd_index <= file_count[4:0];
                                        cat_cmd_data <= {ename, fcl, dout, esize[23:0]};
                                        file_count <= file_count + 6'd1;
                                        if (anim_name(ename)) seq_count <= seq_count + 6'd1;
                                        bmp_fnd <= 1'b1;
                                    end
                                end
                                default: ;
                            endcase
                            end
                        end else begin
                            //---------------------------------------------
                            // 文件数据: 头解析 + 缩略图抽取
                            //---------------------------------------------
                            fbc <= fbc + 32'd1;
                            // ---- BMP 头捕获 (前 64 字节) ----
                            if (fbc < 32'd64) begin
                                case (fbc)
                                    32'd0:  sig0   <= dout;
                                    32'd1:  sig1   <= dout;
                                    32'd10: pixoff[7:0]   <= dout;  // 像素数据偏移(小端)
                                    32'd11: pixoff[15:8]  <= dout;
                                    32'd12: pixoff[23:16] <= dout;
                                    32'd13: pixoff[31:24] <= dout;
                                    32'd14: dibsz[7:0]   <= dout;
                                    32'd15: dibsz[15:8]  <= dout;
                                    32'd16: dibsz[23:16] <= dout;
                                    32'd17: dibsz[31:24] <= dout;
                                    32'd18: wpx[7:0]   <= dout;     // 宽(小端)
                                    32'd19: wpx[15:8]  <= dout;
                                    32'd20: wpx[23:16] <= dout;
                                    32'd21: wpx[31:24] <= dout;
                                    32'd22: hpx[7:0]   <= dout;     // 高(小端, 可为负)
                                    32'd23: hpx[15:8]  <= dout;
                                    32'd24: hpx[23:16] <= dout;
                                    32'd25: hpx[31:24] <= dout;
                                    32'd26: planes[7:0] <= dout;
                                    32'd27: planes[15:8] <= dout;
                                    32'd28: bpp_lo <= dout;
                                    32'd29: bpp_hi <= dout;
                                    32'd30: compression[7:0]   <= dout;
                                    32'd31: compression[15:8]  <= dout;
                                    32'd32: compression[23:16] <= dout;
                                    32'd33: compression[31:24] <= dout;
                                    32'd53: begin
                                        // BITMAPINFOHEADER 或更长头; 当前仅支持缩小到256x192。
                                        if (sig0 == 8'h42 && sig1 == 8'h4D &&
                                            bpp_hi == 8'h00 && bpp_lo == 8'h18 &&
                                            dibsz >= 32'd40 && planes == 16'd1 && compression == 32'd0 &&
                                            pixoff >= 32'd54 && pixoff < esz && dibsz <= pixoff - 32'd14 &&
                                            ((FULL_FRAME!=0 && wpx==32'd640 && habs_c==32'd480) ||
                                             (FULL_FRAME==0 && wpx>=32'd256 && wpx<=32'd65535 &&
                                              habs_c>=32'd192 && habs_c<=32'd65535))) begin
                                            hdr_ok  <= 1'b1;
                                            if(wpx==640 && habs_c==480) fb_start<=1;
                                            hneg    <= hpx[31];
                                            habs    <= habs_c;
                                            rowsize <= ({wpx[30:0],1'b0} + wpx + 32'd3) & ~32'd3;
                                            rowty   <= hpx[31] ? 8'd0 : 8'd191;
                                        end else
                                            hdr_bad <= 1'b1;
                                    end
                                    default: ;
                                endcase
                            end
                            // ---- 像素抽取 ----
                            if (hdr_ok && !hdr_bad && !done_pend && fbc >= pixoff &&
                                fbc < esz && padcnt == 2'd0) begin
                                case (p)
                                    2'd0: begin breg <= dout; p <= 2'd1; end
                                    2'd1: begin greg <= dout; p <= 2'd2; end
                                    default: begin        // R 到齐: 写缩略图
                                        p      <= 2'd0;
                                        tw_addr<= {rowty, tx};
                                        tw_data<= cidx;
                                        tw_wren<= 1'b1;
                                        if(wpx==640 && habs==480) begin
                                            fb_pixel_addr<=raw_addr;
                                            fb_pixel_data<={dout,greg,breg};
                                            fb_pixel_valid<=1;
                                        end
                                        // x 方向抽点
                                        accx <= accx_sum;
                                        if (accx_sum >= {1'b0, wpx[15:0]}) begin
                                            accx <= accx_sum - {1'b0, wpx[15:0]};
                                            if (tx != 8'd255) tx <= tx + 8'd1;
                                        end
                                        if (x == wpx[15:0] - 16'd1) begin
                                            // ---- 行尾: 复位 x/tx/accx, 推进行 ----
                                            x      <= 16'd0;
                                            tx     <= 8'd0;
                                            accx   <= 18'd0;
                                            padcnt <= padsz;
                                            accy   <= accy_sum;
                                            if (accy_sum >= habs[16:0]) begin
                                                accy <= accy_sum - habs[16:0];
                                                if (ty != 8'd191) ty <= ty + 8'd1;
                                                rowty <= hneg ? ((ty == 8'd191) ? 8'd191 : ty + 8'd1)
                                                              : ((ty == 8'd191) ? 8'd0 : 8'd191 - (ty + 8'd1));
                                            end else begin
                                                rowty <= hneg ? ty : (8'd191 - ty);
                                            end
                                            row_cnt <= row_cnt + 32'd1;
                                            if (row_cnt + 32'd1 >= habs)
                                                done_pend <= 1'b1;
                                        end else begin
                                            x <= x + 16'd1;
                                        end
                                    end
                                endcase
                            end else if (padcnt != 2'd0) begin
                                padcnt <= padcnt - 2'd1;
                            end
                        end
                    end
                    // 超时看门狗: 335ms 没有新字节 -> 本轮放弃, 3 秒后重来
                    if (dvalid)         tmo <= 24'd0;
                    else if (!blk_done) tmo <= tmo + 24'd1;

                    if (blk_done) begin
                        if (chain == CH_ROOT) begin
                            if (dir_end || file_count == 6'd32) begin
                                sort_pos <= 6'd0;
                                sort_pass <= 6'd0;
                                sort_phase <= 3'd0;
                                state <= S_SORT;
                            end else if ({1'b0, sec} + 9'd1 < {1'b0, spc}) begin
                                sec   <= sec + 8'd1;
                                cnt   <= 9'd0;
                                state <= S_DREAD;
                            end else begin
                                cnt   <= 9'd0;
                                state <= S_FATI;           // 根目录簇用完, 沿 FAT 走
                            end
                        end else begin
                            // 文件模式: 结束条件
                            if (done_pend || hdr_bad || fbc >= esz) begin
                                if (hdr_bad || !done_pend) begin
                                    tf_err <= 2'd3;
                                    wt     <= 29'd0;
                                    state  <= S_ERRW;
                                end else begin
                                    tf_valid <= 1'b1;
                                    tf_err <= 2'd0;
                                    busy <= 1'b0;
                                    load_done <= 1'b1;
                                    load_pending <= 1'b0;
                                    shown_index <= active_index;
                                    shown_name <= selected_file[127:64];
                                    src_width <= wpx[15:0];
                                    src_height <= habs[15:0];
                                    state    <= S_DONE;
                                end
                            end else if ({1'b0, sec} + 9'd1 < {1'b0, spc}) begin
                                sec   <= sec + 8'd1;
                                cnt   <= 9'd0;
                                state <= S_DREAD;
                            end else begin
                                cnt   <= 9'd0;
                                state <= S_FATI;
                            end
                        end
                    end else if (tmo == 24'hFFFFFF || init_err || !init_done) begin
                        tf_err <= 2'd1;
                        wt     <= 29'd0;
                        state  <= S_ERRW;
                    end
                end

                // ---- 读 FAT 项 ----
                S_FATI: begin
                    fat_off <= {cur_clus[6:0], 2'b00};     // (c*4) mod 512
                    rd_addr <= fat_sec;
                    rd_go   <= 1'b1;
                    cnt     <= 9'd0;
                    tmo     <= 24'd0;
                    state   <= S_FATW;
                end

                S_FATW: begin
                    if (dvalid) begin
                        cnt <= cnt + 9'd1;
                        // FAT32 项 = 小端 32 位: 偏移+0 是最低字节
                        if (cnt == fat_off)
                            fatent[7:0]   <= dout;
                        else if (cnt == fat_off + 9'd1)
                            fatent[15:8]  <= dout;
                        else if (cnt == fat_off + 9'd2)
                            fatent[23:16] <= dout;
                        else if (cnt == fat_off + 9'd3)
                            fatent[31:24] <= dout;
                    end
                    if (blk_done) state <= S_FATE;
                    else if (tmo == 24'hFFFFFF || init_err || !init_done) begin
                        tf_err <= 2'd1;
                        wt     <= 29'd0;
                        state  <= S_ERRW;
                    end else
                        tmo <= tmo + 24'd1;
                end

                S_FATE: begin
                    if (fat_next < 32'd2 || fat_next >= 32'h0FFFFFF7) begin
                        // 簇链结束
                        if (chain == CH_ROOT) begin
                            sort_pos <= 6'd0;
                            sort_pass <= 6'd0;
                            sort_phase <= 3'd0;
                            state <= S_SORT;
                        end else begin
                            tf_err <= 2'd3;                // 簇链提前结束, 拒绝显示未填满RAM
                            wt     <= 29'd0;
                            state  <= S_ERRW;
                        end
                    end else begin
                        cur_clus <= fat_next;
                        sec      <= 8'd0;
                        cnt      <= 9'd0;
                        state    <= S_DREAD;
                    end
                end

                // Adjacent bubble-sort: ANIMdddd first, then lexical 8.3 name.
                // BMP is the same extension for every catalog member.
                S_SORT: begin
                    case (sort_phase)
                        3'd0: if (!cat_busy && !cat_start) begin
                            if (file_count == 6'd0) begin
                                tf_err <= 2'd2;
                                wt <= 29'd0;
                                state <= S_ERRW;
                            end else if (file_count == 6'd1 || sort_pass + 6'd1 >= file_count) begin
                                cat_ready <= 1'b1;
                                active_index <= 6'd0;
                                load_pending <= 1'b1;
                                load_phase <= 2'd0;
                                state <= S_LOAD;
                            end else begin
                                cat_start <= 1'b1;
                                cat_cmd_write <= 1'b0;
                                cat_cmd_index <= sort_pos[4:0];
                                sort_phase <= 3'd1;
                            end
                        end
                        3'd1: if (cat_done) begin
                            sort_a <= cat_result;
                            cat_start <= 1'b1;
                            cat_cmd_write <= 1'b0;
                            cat_cmd_index <= sort_pos[4:0] + 5'd1;
                            sort_phase <= 3'd2;
                        end
                        3'd2: if (cat_done) begin
                            if (swap_pair) begin
                                cat_start <= 1'b1;
                                cat_cmd_write <= 1'b1;
                                cat_cmd_index <= sort_pos[4:0];
                                cat_cmd_data <= cat_result;
                                sort_phase <= 3'd3;
                            end else sort_phase <= 3'd5;
                        end
                        3'd3: if (cat_done) begin
                            cat_start <= 1'b1;
                            cat_cmd_write <= 1'b1;
                            cat_cmd_index <= sort_pos[4:0] + 5'd1;
                            cat_cmd_data <= sort_a;
                            sort_phase <= 3'd4;
                        end
                        3'd4: if (cat_done) sort_phase <= 3'd5;
                        default: begin
                            if (sort_pos + 6'd2 >= file_count - sort_pass) begin
                                sort_pos <= 6'd0;
                                sort_pass <= sort_pass + 6'd1;
                            end else sort_pos <= sort_pos + 6'd1;
                            sort_phase <= 3'd0;
                        end
                    endcase
                end

                S_LOAD: begin
                    tf_valid <= 1'b0;
                    tf_err <= 2'd0;
                    busy <= 1'b1;
                    if (load_phase == 2'd0) begin
                        if (!cat_busy && !cat_start) begin
                            cat_start <= 1'b1;
                            cat_cmd_write <= 1'b0;
                            cat_cmd_index <= active_index[4:0];
                            load_phase <= 2'd1;
                        end
                    end else if (load_phase == 2'd1) begin
                        if (cat_done) begin
                            selected_file <= cat_result;
                            load_phase <= 2'd2;
                        end
                    end else if (active_index >= file_count || selected_file[63:32] < 32'd2 ||
                        selected_file[31:0] < 32'd54) begin
                        tf_err <= 2'd3;
                        wt <= 29'd0;
                        state <= S_ERRW;
                    end else begin
                        cur_clus <= selected_file[63:32];
                        esz <= selected_file[31:0];
                        chain <= CH_FILE;
                        sec <= 8'd0;
                        fbc <= 32'd0;
                        hdr_ok <= 1'b0;
                        hdr_bad <= 1'b0;
                        x <= 16'd0;
                        accx <= 17'd0;
                        accy <= 17'd0;
                        tx <= 8'd0;
                        ty <= 8'd0;
                        rowty <= 8'd191;
                        p <= 2'd0;
                        padcnt <= 2'd0;
                        row_cnt <= 32'd0;
                        done_pend <= 1'b0;
                        cnt <= 9'd0;
                        state <= S_DREAD;
                    end
                end

                S_DONE: begin
                    busy <= 1'b0;
                end

                // Catalog-backed failures remain immediately requestable.
                // Mount/no-file failures rescan after three seconds.
                S_ERRW: begin
                    busy <= 1'b0;
                    if (load_pending) begin
                        load_done <= 1'b1;
                        load_pending <= 1'b0;
                    end
                    // An I/O failure can leave sd_spi stopped in S_IDLE.
                    // Complete this request first, then remount instead of using
                    // stale cluster metadata against an uninitialized card.
                    if (tf_err == 2'd1) begin
                        cat_ready <= 1'b0;
                        tf_valid <= 1'b0;
                    end
                    if (!cat_ready || tf_err == 2'd1) begin
                        if (wt >= RETRY_TICKS - 1) state <= S_W0;
                        else wt <= wt + 29'd1;
                    end
                end

                default: state <= S_W0;
            endcase
            // Case equality preserves compatibility with unconnected legacy ports.
            // A held request is accepted once and cannot retrigger on completion.
            if ((state == S_DONE || state == S_ERRW) && cat_ready &&
                tf_err != 2'd1 &&
                (load_go === 1'b1) && !load_held && !(cancel_go === 1'b1)) begin
                cancel_pending <= 1'b0;
                active_index <= load_index;
                load_phase <= 2'd0;
                load_pending <= 1'b1;
                busy <= 1'b1;
                tf_valid <= 1'b0;
                tf_err <= 2'd0;
                state <= S_LOAD;
            end
        end
    end

endmodule

//=============================================================================
// media_ctrl: immediate buffered background loads; legacy single-cache fades.
// K1/K2 pause auto and retain a latest manual destination while reads drain.
// Mode0 ANIM sequence (fallback all BMPs); mode1 gallery; mode2 original RPG.
// All outputs in pixel domain; loader handshake crosses through media_cdc.
//=============================================================================
module media_ctrl #(
    parameter integer FPS=60,
    parameter integer GALLERY_SEC=4,
    parameter integer SEQUENCE_FRAMES=3,
    parameter integer FADE_FRAMES=2,
    parameter integer LOCK_FRAMES=15,
    parameter integer VISUAL_DEFAULT=1
)(
    input wire clk, rst_n, frame_tick,
    input wire [3:0] keys, longs,
    input wire cat_ready, image_busy, image_valid, load_done,
    input wire [1:0] image_error,
    input wire [5:0] file_count, seq_count, shown_index,
    input wire req_ready,
    input wire fb_front_valid,
    output reg load_req,
    output reg cancel_req,
    output reg [5:0] load_index,
    output reg [1:0] media_mode,
    output reg media_auto, media_settings, media_osd, media_visual, media_mute,
    output reg [3:0] media_brightness,
    output reg [1:0] media_contrast, media_view,
    output reg [3:0] gal_fade,
    output wire gal_on, gal_block, media_loading
);
    localparam [2:0] C_BOOT=0,C_HOLD=1,C_OUT=2,C_BLACK=3,C_WAIT=4,C_IN=5,C_ERROR=6;
    reg [2:0] state;
    reg [15:0] dwell;
    reg [7:0] fade_count,lock_count;
    reg [5:0] target;
    reg restart_pending, cancel_sent;
    reg manual_pending_valid, manual_cursor_valid;
    reg [5:0] manual_pending_target, manual_cursor;
    reg manual_unresolved;
    reg signed [15:0] manual_unresolved_target;
    // Every manual click is acknowledged now, even if the loader is occupied.
    wire manual_key = gal_on && !media_settings && !longs[3] &&
        !keys[3] && !keys[2] && (keys[0] || keys[1]);
    wire control_key = longs[3] || (gal_on && !media_settings && (keys[3] || keys[2]));
    wire buffered=(fb_front_valid===1'b1);
    wire [5:0] limit = (media_mode==0 && seq_count!=0) ? seq_count : file_count;
    wire signed [15:0] signed_limit = {10'd0,limit};
    // A failed load retains last successful metadata. Navigate from the attempted
    // slot on errors, so automatic playback skips corrupt files instead of retrying forever.
    wire [5:0] cursor = (image_error!=0 && state!=C_BOOT) ? load_index : shown_index;
    wire [5:0] next_index = (cursor+6'd1>=limit) ? 6'd0 : cursor+6'd1;
    // First manual navigation during auto prefetch starts at the visible frame.
    // Further clicks before completion step from the last manual destination.
    wire [5:0] manual_base = manual_cursor_valid ? manual_cursor :
        ((state==C_WAIT && buffered) ? shown_index : cursor);
    wire [5:0] manual_next = (manual_base+6'd1>=limit && limit!=0) ? 6'd0 : manual_base+6'd1;
    wire [5:0] manual_prev = (manual_base==0 || (limit!=0 && manual_base>=limit)) ? limit-6'd1 : manual_base-6'd1;
    wire [5:0] manual_choice = keys[0] ? manual_prev : manual_next;
    assign gal_on = media_mode!=2;
    assign gal_block = gal_on || lock_count!=0;
    assign media_loading = (state==C_BLACK || state==C_WAIT || (state==C_BOOT && image_busy));
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state<=C_BOOT; media_mode<=0; media_auto<=1; media_settings<=0;
            media_osd<=1; media_visual<=(VISUAL_DEFAULT!=0); media_mute<=0;
            media_brightness<=4; media_contrast<=1; media_view<=0;
            gal_fade<=8; load_req<=0; load_index<=0; target<=0;
            dwell<=0; fade_count<=0; lock_count<=0; restart_pending<=0;
            cancel_req<=0; cancel_sent<=0;
            manual_pending_valid<=0; manual_cursor_valid<=0;
            manual_pending_target<=0; manual_cursor<=0;
            manual_unresolved<=0; manual_unresolved_target<=0;
        end else begin
            load_req<=0; cancel_req<=0;
            if(load_done) begin
                cancel_sent<=0;
                if(!manual_pending_valid) manual_cursor_valid<=0;
            end
            if(frame_tick && lock_count!=0) lock_count<=lock_count-1'b1;
            // Processing loader completions remains active while RPG owns video.
            case(state)
                C_BOOT: begin
                    if(cat_ready && !image_busy && image_valid) begin
                        gal_fade<=buffered?8:0; state<=buffered?C_HOLD:C_IN; fade_count<=0; dwell<=0;
                    end else if(cat_ready && !image_busy && image_error!=0) begin
                        gal_fade<=8; state<=C_ERROR; dwell<=0;
                    end
                end
                C_HOLD: if(gal_on && frame_tick && media_auto && !manual_pending_valid && !media_settings && limit>1) begin
                    if(dwell>=((media_mode==0)?SEQUENCE_FRAMES:(FPS*GALLERY_SEC))-1) begin
                        dwell<=0; target<=next_index; state<=buffered?C_BLACK:C_OUT; fade_count<=0;
                        if(buffered && req_ready && cat_ready && !image_busy) begin
                            load_index<=next_index; load_req<=1; state<=C_WAIT; cancel_sent<=0;
                        end
                    end else dwell<=dwell+1'b1;
                end
                C_OUT: if(buffered || frame_tick) begin
                    if(buffered) begin
                        gal_fade<=8;state<=C_BLACK;
                    end else if(media_mode==0 || gal_fade==0) begin
                        gal_fade<=0; state<=C_BLACK;
                    end else if(fade_count>=FADE_FRAMES-1) begin
                        gal_fade<=gal_fade-1'b1; fade_count<=0;
                    end else fade_count<=fade_count+1'b1;
                end
                // Legacy single-cache writes require a complete black interval.
                C_BLACK: if(!manual_pending_valid && (buffered || frame_tick) && req_ready && cat_ready && !image_busy) begin
                    load_index<=target; load_req<=1; state<=C_WAIT; cancel_sent<=0;
                end
                C_WAIT: if(load_done) begin
                    if(restart_pending) begin
                        restart_pending<=0; target<=0; state<=C_BLACK;
                    end else if(image_error!=0 || !image_valid) begin
                        state<=C_ERROR; gal_fade<=8; dwell<=0;
                    end else begin
                        state<=buffered?C_HOLD:C_IN; gal_fade<=buffered?8:0; fade_count<=0; dwell<=0;
                    end
                end
                C_IN: if(frame_tick) begin
                    if(media_mode==0 || gal_fade==8) begin
                        gal_fade<=8; state<=C_HOLD; dwell<=0;
                    end else if(fade_count>=FADE_FRAMES-1) begin
                        gal_fade<=gal_fade+1'b1; fade_count<=0;
                    end else fade_count<=fade_count+1'b1;
                end
                C_ERROR: if(gal_on && frame_tick && media_auto && !manual_pending_valid && !media_settings && limit>1) begin
                    if(dwell>=FPS*2-1) begin
                        target<=next_index; state<=buffered?C_BLACK:C_OUT; dwell<=0;
                        if(buffered && req_ready && cat_ready && !image_busy) begin
                            load_index<=next_index; load_req<=1; state<=C_WAIT; cancel_sent<=0;
                        end
                    end
                    else dwell<=dwell+1'b1;
                end
                default: state<=C_BOOT;
            endcase
            // Ready buffered writes never wait for a raster interval: the front
            // bank and published metadata are retained by the loader until commit.
            // Gate old pending work when a new key shares the completion clock.
            // Before catalog publication keep a signed destination. Normalize
            // with one small add/subtract per clock once the wrap limit is known.
            if(manual_unresolved && cat_ready && limit!=0 && !manual_key && !control_key) begin
                if(manual_unresolved_target<0)
                    manual_unresolved_target<=manual_unresolved_target+signed_limit;
                else if(manual_unresolved_target>=signed_limit)
                    manual_unresolved_target<=manual_unresolved_target-signed_limit;
                else begin
                    manual_pending_target<=manual_unresolved_target[5:0];
                    manual_cursor<=manual_unresolved_target[5:0];
                    manual_unresolved<=0;
                end
            end
            if(manual_pending_valid && !manual_unresolved && !manual_key && !control_key && gal_on &&
               cat_ready && limit!=0 && !image_busy && (state!=C_WAIT || load_done) &&
               (state!=C_BOOT || image_valid || image_error!=0)) begin
                target<=manual_pending_target;
                if(buffered && req_ready) begin
                    load_index<=manual_pending_target; load_req<=1; state<=C_WAIT;
                    cancel_sent<=0; manual_pending_valid<=0; gal_fade<=8;
                end else if(!buffered) begin
                    // Keep the legacy single-cache black/fade write protection.
                    if(state==C_BLACK && frame_tick && req_ready) begin
                        load_index<=manual_pending_target; load_req<=1; state<=C_WAIT;
                        cancel_sent<=0; manual_pending_valid<=0;
                    end else if(state!=C_OUT && state!=C_BLACK) begin
                        state<=C_OUT; fade_count<=0;
                    end
                end else state<=C_BLACK;
            end
            if(longs[3]) begin
                if(media_mode==2) begin
                    media_mode<=0; media_settings<=0; media_auto<=1; target<=0; dwell<=0;
                    manual_pending_valid<=0; manual_cursor_valid<=0; manual_unresolved<=0;
                    if(state==C_WAIT || image_busy) restart_pending<=1;
                    else if(cat_ready) state<=C_OUT;
                end else media_settings<=!media_settings;
            end else if(gal_on) begin
                if(longs[0]) media_osd<=!media_osd;
                if(longs[1]) media_visual<=!media_visual;
                if(longs[2]) media_mute<=!media_mute;
                if(media_settings) begin
                    if(keys[0]) media_brightness<=(media_brightness==8)?0:media_brightness+1'b1;
                    else if(keys[1]) media_contrast<=(media_contrast==2)?0:media_contrast+1'b1;
                    else if(keys[2]) begin
                        if(buffered) media_visual<=!media_visual;
                        else media_view<=(media_view==2)?0:media_view+1'b1;
                    end
                    else if(keys[3]) media_settings<=0;
                end else if(keys[3]) begin
                    media_mode<=(media_mode==0)?1:2; dwell<=0; lock_count<=LOCK_FRAMES;
                    manual_pending_valid<=0; manual_cursor_valid<=0; manual_unresolved<=0;
                    load_req<=0;
                    media_auto<=(media_mode==0)?0:media_auto;
                    if(buffered) begin
                        restart_pending<=0;
                        if(state==C_WAIT && load_done && restart_pending) begin
                            state<=C_HOLD; gal_fade<=8;
                        end
                        if(state==C_WAIT && !load_done && !cancel_sent) begin
                            cancel_req<=1; cancel_sent<=!load_done;
                        end else if(state==C_OUT || state==C_BLACK) begin
                            // Override BLACK's same-cycle request and keep front.
                            load_req<=0; state<=C_HOLD; gal_fade<=8; fade_count<=0;
                        end else if(state==C_HOLD || state==C_ERROR) state<=state;
                    end
                end else if(keys[2]) begin
                    // Pause/resume is immediate; a buffered back read is cancelled
                    // at the next complete SD sector while the front stays visible.
                    media_auto<=!media_auto;
                    dwell<=0;
                    if(media_auto) begin
                        manual_pending_valid<=0; manual_cursor_valid<=0; manual_unresolved<=0;
                        load_req<=0;
                        if(buffered && state==C_WAIT) begin
                            restart_pending<=0;
                            if(!load_done && !cancel_sent) begin cancel_req<=1; cancel_sent<=1; end
                            if(load_done && restart_pending) begin state<=C_HOLD; gal_fade<=8; end
                        end
                        if(state==C_HOLD || state==C_ERROR) state<=state; // Override same-frame auto advance.
                        else if(state==C_OUT || state==C_BLACK) begin
                            // Cancel a transition which has not issued its read yet,
                            // including BLACK's same-cycle load_req assignment above.
                            load_req<=0;
                            fade_count<=0;
                            if(image_valid) state<=C_IN;
                            else if(image_busy) state<=C_BOOT;
                            else begin state<=C_ERROR; gal_fade<=8; end
                        end
                    end
                end else if(keys[0] || keys[1]) begin
                    // Manual override pauses auto, so a new frame is not replaced
                    // by the 50ms sequence deadline. K3 resumes without cancelling
                    // an already paused manual request.
                    media_auto<=0; dwell<=0; fade_count<=0; restart_pending<=0;
                    manual_cursor<=manual_choice; manual_cursor_valid<=1;
                    manual_pending_target<=manual_choice; manual_pending_valid<=1;
                    target<=manual_choice; load_req<=0;
                    if(manual_unresolved || !cat_ready || limit==0) begin
                        manual_unresolved<=1;
                        if(manual_unresolved)
                            manual_unresolved_target<=manual_unresolved_target+(keys[0]?-16'sd1:16'sd1);
                        else
                            manual_unresolved_target<=$signed({10'd0,manual_base})+(keys[0]?-16'sd1:16'sd1);
                    end
                    if(state==C_WAIT && !load_done) begin
                        if(buffered && !cancel_sent) begin cancel_req<=1; cancel_sent<=1; end
                    end else if(!manual_unresolved && cat_ready && limit!=0 && !image_busy &&
                                (state!=C_BOOT || image_valid || image_error!=0)) begin
                        if(buffered && req_ready) begin
                            load_index<=manual_choice; load_req<=1; state<=C_WAIT;
                            manual_pending_valid<=0; cancel_sent<=0; gal_fade<=8;
                        end else begin
                            state<=buffered?C_BLACK:C_OUT;
                        end
                    end
                end
            end
        end
    end
endmodule

//=============================================================================
// media_cdc: bundled-data, toggle/ack transfer for requests and loader snapshots.
// Source holds each complete payload until destination acknowledges. Multi-bit
// metadata is never independently bit-synchronized. No additional image memory.
//=============================================================================
module media_cdc(
    input wire pclk, prst_n, sclk, srst_n,
    input wire p_req,
    input wire p_cancel,
    input wire [5:0] p_index,
    output wire p_req_ready,
    output reg s_load_go,
    output reg s_cancel_go,
    output reg [5:0] s_load_index,
    input wire s_cat_ready,s_busy,s_valid,s_done,
    input wire [1:0] s_error,
    input wire [5:0] s_count,s_seq_count,s_shown,
    input wire [63:0] s_name,
    input wire [7:0] s_diag,s_panel,
    input wire s_fill,
    output reg p_cat_ready,p_busy,p_valid,p_done,
    output reg [1:0] p_error,
    output reg [5:0] p_count,p_seq_count,p_shown,
    output reg [7:0] p_diag,p_panel,
    output reg p_fill,
    output reg [63:0] p_name
);
    reg req_toggle,req_ack;
    reg [6:0] req_payload;
    reg cancel_pending;
    reg [1:0] req_sync,ack_sync;
    wire command_ready=(ack_sync[1]==req_toggle);
    assign p_req_ready=command_ready && !cancel_pending;
    always @(posedge pclk or negedge prst_n) begin
        if(!prst_n) begin
            req_toggle<=0; req_payload<=0; ack_sync<=0; cancel_pending<=0;
        end else begin
            ack_sync<={ack_sync[0],req_ack};
            // A cancel arriving just after a load request must survive until
            // that request's acknowledgement. Keep its command bit bundled.
            if(p_cancel === 1'b1) cancel_pending<=1;
            if(command_ready) begin
                if(cancel_pending || (p_cancel === 1'b1)) begin
                    req_payload<={1'b1,6'd0}; req_toggle<=!req_toggle;
                    cancel_pending<=0;
                end else if(p_req) begin
                    req_payload<={1'b0,p_index}; req_toggle<=!req_toggle;
                end
            end
        end
    end
    always @(posedge sclk or negedge srst_n) begin
        if(!srst_n) begin
            req_sync<=0; req_ack<=0; s_load_go<=0; s_cancel_go<=0; s_load_index<=0;
        end else begin
            req_sync<={req_sync[0],req_toggle}; s_load_go<=0; s_cancel_go<=0;
            if(req_sync[1]!=req_ack) begin
                if(req_payload[6]) s_cancel_go<=1;
                else begin s_load_index<=req_payload[5:0]; s_load_go<=1; end
                req_ack<=req_sync[1];
            end
        end
    end
    reg done_toggle;
    reg status_toggle,status_ack;
    reg [1:0] status_sync,status_ack_sync;
    // Complete105-bit status includes diagnostics, so no separate unsafe bus crossing.
    reg [104:0] status_payload;
    wire [104:0] live_status={done_toggle,s_cat_ready,s_busy,s_valid,s_error,s_count,s_seq_count,s_shown,s_name,s_diag,s_panel,s_fill};
    always @(posedge sclk or negedge srst_n) begin
        if(!srst_n) begin
            done_toggle<=0; status_toggle<=0; status_payload<=0; status_ack_sync<=0;
        end else begin
            status_ack_sync<={status_ack_sync[0],status_ack};
            if(s_done) done_toggle<=!done_toggle;
            if(status_ack_sync[1]==status_toggle && live_status!=status_payload) begin
                status_payload<=live_status; status_toggle<=!status_toggle;
            end
        end
    end
    reg last_done;
    always @(posedge pclk or negedge prst_n) begin
        if(!prst_n) begin
            status_sync<=0; status_ack<=0; last_done<=0;
            p_cat_ready<=0;p_busy<=0;p_valid<=0;p_error<=0;
            p_count<=0;p_seq_count<=0;p_shown<=0;p_name<=0;p_done<=0;p_diag<=0;p_panel<=0;p_fill<=0;
        end else begin
            status_sync<={status_sync[0],status_toggle};p_done<=0;
            if(status_sync[1]!=status_ack) begin
                {last_done,p_cat_ready,p_busy,p_valid,p_error,p_count,p_seq_count,p_shown,p_name,p_diag,p_panel,p_fill}<=status_payload;
                p_done<=status_payload[104]!=last_done;
                status_ack<=status_sync[1];
            end
        end
    end
endmodule

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
    output wire [1:0] s_front_bank
);
    localparam [3:0] IDLE=0, BUILD_FETCH=1, BUILD_HAVE=2, CMD_WRITE=3,
        WRITE_FETCH=4, WRITE_SEND=5, WRITE_WAIT=6, CMD_READ=7,
        READ_WAIT=8, READ_RECOVER=9;
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
                                                     {front_bank, fetch_addr};
    wire [7:0] cmd_len = cmd_write ? {3'd0,burst_count} : 8'd128;
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
    wire video_read = pixel_req && p_gate && p_front && !p_wait && !frame_tick && !video_empty;
    media_async_fifo #(.WIDTH(24), .ADDR_BITS(11)) video_fifo (
        .wclk(sclk), .wrst_n(srst_n), .wclear(epoch_state==E_CLEAR),
        .w_en(video_write), .w_data(ctrl_rd_data[23:0]),
        .w_full(video_full), .w_level(video_used),
        .rclk(pclk), .rrst_n(prst_n), .rclear(p_wait),
        .r_en(video_read), .r_data(video_data), .r_valid(video_rvalid),
        .r_empty(video_empty)
    );
    assign pixel_rgb = p_show && video_rvalid ? video_data : 24'd0;
    assign front_valid = p_front;

    // Gray-pointer FIFO read is synchronous: request S2 -> registered data S3.
    // On underrun, consume any subsequently available pixels but hide the rest
    // of this frame. The next blank epoch discards all residual FIFO contents.
    always @(posedge pclk or negedge prst_n) begin
        if (!prst_n) begin
            p_epoch<=0; p_return<=0; p_wait<=0; p_gate<=0;
            p_front<=0; p_bad<=0; p_show<=0; pixel_valid<=0; underrun<=0;
            ack_meta<=0; ack_sync<=0; front_meta<=0; front_sync<=0;
        end else begin
            ack_meta<=s_ack; ack_sync<=ack_meta;
            front_meta<=front_live; front_sync<=front_meta;
            p_show<=video_read && !p_bad;
            pixel_valid<=video_read && !p_bad;
            if (frame_tick) begin
                p_epoch<=!p_epoch; p_wait<=1; p_gate<=0;
                p_bad<=0; underrun<=0; p_show<=0; pixel_valid<=0;
            end else if (p_wait && ack_sync==p_epoch) begin
                p_wait<=0; p_gate<=1; p_front<=front_sync; p_return<=ack_sync;
            end else if (pixel_req && p_gate && p_front && !p_wait && video_empty) begin
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
                        if (front_live && fetch_addr<307200 && video_used<=1920 &&
                            (video_used<1024 || source_used<16 && !end_pending)) begin
                            state<=CMD_READ;
                        end else if (!commit_pending && !swap_waiting &&
                            (source_used>=16 || end_pending && source_used!=0)) begin
                            burst_count<=0; state<=BUILD_FETCH;
                        end else if (front_live && fetch_addr<307200 && video_used<=1920) begin
                            state<=CMD_READ;
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
                CMD_READ: if (cmd_ready) begin fetch_addr<=fetch_addr+19'd128; state<=READ_WAIT; end
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
// MEDIA_FRAMEBUFFER_END


//=============================================================================
// img_chime —— 每张图一个专属换图音
//
//   用途: TF 相册切换图片时, 按"当前显示的图号"给出一个专属音, 换到不同图
//         声音就不同。每张图是一小段两音动机: 基音(55ms) -> 上五度(90ms),
//         听感像"叮—咚", 比单音更容易分辨。
//
//   ★ 为什么音高表是乱序的:
//       如果按图号升半音排, 连续翻页听起来就是爬音阶, 很单调; 这里用一张
//       打散过的 25 音表 (0..24 半音各用一次, 顺序打乱), 相邻两张图的音程
//       是随机的, 既能听出"这张和上一张不一样", 又不会像音阶。
//
//   ★ 为什么不用 sfx_id:
//       sound 模块的 sfx_id 是 4bit / 15 个编号, 装不下 25 张图; 而且换图音
//       不应该顶掉受击、击杀这些游戏音效, 所以在 sound 里单开一路 (s4)。
//
//   ★ 稳定判定: 换图过程中 shown_index 会经历若干中间值, 这里要求新序号
//       连续保持 8ms 才认账, 避免一次换图响好几声。
//
//   时钟: 与 sound 同一个域 (clk_pix), 不需要跨时钟处理。
//=============================================================================
module img_chime #(
    parameter integer CLK_HZ    = 25175000,
    parameter integer SAMPLE_HZ = 32000
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire [5:0]  index,      // 当前显示的图片序号
    input  wire [5:0]  count,      // 图库总数 (0 = 无图)
    input  wire        ready,      // 目录已就绪
    output reg         trig,       // 单拍触发, 接 sound.chime_trig
    output reg  [23:0] step,       // 相位步进, 接 sound.chime_step
    output reg  [15:0] len         // 时长(采样数), 接 sound.chime_len
);
    localparam integer STABLE = (CLK_HZ / 1000) * 8;     // 序号稳定 8ms
    localparam integer HOLD1  = (CLK_HZ / 1000) * 55;    // 基音 55ms
    localparam integer HOLD2  = (CLK_HZ / 1000) * 90;    // 上五度 90ms
    localparam integer SAMP1  = (SAMPLE_HZ / 1000) * 55; // 1760 采样
    localparam integer SAMP2  = (SAMPLE_HZ / 1000) * 90; // 2880 采样

    localparam [1:0] C_IDLE = 2'd0, C_N1 = 2'd1, C_N2 = 2'd2;

    // 图号 -> 相位步进 (step = f * 2^24 / SAMPLE_HZ), 25 个音各不同
    function [23:0] note_step;
        input [5:0] n;
        begin
            case (n)
                6'd0:  note_step = 24'd137167;  // 261.6Hz C4
                6'd1:  note_step = 24'd205519;  // 392.0Hz G4
                6'd2:  note_step = 24'd163120;  // 311.1Hz Eb4
                6'd3:  note_step = 24'd274334;  // 523.3Hz C5
                6'd4:  note_step = 24'd183096;  // 349.2Hz F4
                6'd5:  note_step = 24'd230687;  // 440.0Hz A4
                6'd6:  note_step = 24'd366192;  // 698.5Hz F5
                6'd7:  note_step = 24'd153965;  // 293.7Hz D4
                6'd8:  note_step = 24'd307930;  // 587.3Hz D5
                6'd9:  note_step = 24'd193984;  // 370.0Hz F#4
                6'd10: note_step = 24'd461374;  // 880.0Hz A5
                6'd11: note_step = 24'd244404;  // 466.2Hz Bb4
                6'd12: note_step = 24'd145324;  // 277.2Hz C#4
                6'd13: note_step = 24'd411037;  // 784.0Hz G5
                6'd14: note_step = 24'd217739;  // 415.3Hz Ab4
                6'd15: note_step = 24'd326240;  // 622.3Hz Eb5
                6'd16: note_step = 24'd548669;  // 1046.5Hz C6
                6'd17: note_step = 24'd172820;  // 329.6Hz E4
                6'd18: note_step = 24'd258937;  // 493.9Hz B4
                6'd19: note_step = 24'd488808;  // 932.3Hz Bb5
                6'd20: note_step = 24'd345640;  // 659.3Hz E5
                6'd21: note_step = 24'd290647;  // 554.4Hz C#5
                6'd22: note_step = 24'd435479;  // 830.6Hz Ab5
                6'd23: note_step = 24'd387967;  // 740.0Hz F#5
                6'd24: note_step = 24'd517874;  // 987.8Hz B5
                default: note_step = 24'd0;
            endcase
        end
    endfunction

    reg [5:0]  idx_d;       // 上一次已经响过的图号
    reg [5:0]  cand;        // 候选图号
    reg [23:0] scnt;        // 候选保持计数
    reg [1:0]  st;
    reg [23:0] tick;
    reg [23:0] step1;       // 本图的基音

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            idx_d <= 6'd0;
            cand  <= 6'd0;
            scnt  <= 24'd0;
            st    <= C_IDLE;
            tick  <= 24'd0;
            step1 <= 24'd0;
            trig  <= 1'b0;
            step  <= 24'd0;
            len   <= 16'd0;
        end else begin
            trig <= 1'b0;

            // 候选序号保持计数
            if (index != cand) begin
                cand <= index;
                scnt <= 24'd0;
            end else if (scnt != STABLE) begin
                scnt <= scnt + 24'd1;
            end

            case (st)
            C_IDLE: begin
                if (ready && (count != 6'd0) && (index != idx_d) && (scnt == STABLE)) begin
                    idx_d <= index;
                    step1 <= note_step(index);
                    step  <= note_step(index);
                    len   <= SAMP1;
                    trig  <= 1'b1;
                    tick  <= HOLD1;
                    st    <= C_N1;
                end
            end

            C_N1: begin
                if (tick <= 24'd1) begin
                    step <= step1 + (step1 >> 1);      // 纯五度 (3/2)
                    len  <= SAMP2;
                    trig <= 1'b1;
                    tick <= HOLD2;
                    st   <= C_N2;
                end else begin
                    tick <= tick - 24'd1;
                end
            end

            C_N2: begin
                if (tick <= 24'd1) st <= C_IDLE;
                else               tick <= tick - 24'd1;
            end

            default: st <= C_IDLE;
            endcase
        end
    end
endmodule
