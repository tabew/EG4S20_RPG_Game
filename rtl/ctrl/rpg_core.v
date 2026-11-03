//=============================================================================
// rpg_core.v —— 游戏核心: 界面指令解释器 + 游戏状态机
//
// 一、界面怎么画
//   每个界面在 cmd.hex 里是一串 32bit 指令:
//     {op[31:28], y[27:23], x[22:17], arg[16:0]}
//   状态一变就整屏重画(约 5000 个时钟 = 200us @25MHz), 看不出来。
//
// 二、为什么用"指令表 + 解释器"
//   每种界面写一段专用绘制逻辑的话, 光排版就上千行, 改一个字要动一片代码。
//   现在排版全在 tools/build_rom.py 里, 改界面不用碰 Verilog。
//
// 三、按键
//   4 个按键就是界面上的 1/2/3/4, 每个界面含义不同。
//=============================================================================
`timescale 1ns/1ps
`include "rpg_defs.vh"

module rpg_core (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [3:0]  key,          // 消抖后的单周期脉冲
    input  wire        emergency,    // 长按 K1：1 级通告，不要求先打满四只怪
    output wire        level1_on,    // 1 级字幕还在，视频层用来盖一条红条

    output reg         we,
    output reg  [10:0] waddr,
    output reg  [16:0] wdata,

    // 调试端口(仿真观察 + 上板可接 LED/逻辑分析仪)
    output wire [3:0]  dbg_scene,
    output wire [9:0]  dbg_hp,
    output wire [9:0]  dbg_maxhp,
    output wire [7:0]  dbg_atk,
    output wire [7:0]  dbg_def,
    output wire [11:0] dbg_gold,
    output wire [3:0]  dbg_lv,
    output wire [3:0]  dbg_state,
    output wire [9:0]  dbg_pc,
    output wire [9:0]  dbg_ehp,

    // 动态插图（给 rpg_video 的图片层）
    output reg         anim_on,
    output reg  [2:0]  anim_frame,

    // 怪物立绘（战斗界面，带淡入淡出）
    output wire        mon_on,
    output wire [4:0]  mon_id,
    output wire [3:0]  mon_fade,

    // 蜂鸣器音效：id 选择音色/时长(1..15, 0=静音), trig 为单拍触发脉冲
    output reg  [3:0]  sfx_id,
    output reg         sfx_trig,
    // 打击特效：1 普攻  2 技能  3 怪物反击。trig 单拍。
    output reg         hit_trig,
    output reg  [1:0]  hit_kind
);

    //---------------------------------------------------------
    // 常量
    //---------------------------------------------------------
    localparam [3:0] SC_TITLE = 4'd0, SC_CLASS = 4'd1, SC_MAP = 4'd2,
                     SC_BATTLE = 4'd3, SC_SHOP = 4'd4, SC_DEAD = 4'd5,
                     SC_WIN   = 4'd6, SC_PIC = 4'd7, SC_SHOP2 = 4'd8;

    localparam [1:0] CL_WAR = 2'd0, CL_MAG = 2'd1, CL_RAN = 2'd2;

    // 自绘图元码(与 build_rom.py 的 CUSTOM 顺序一致)
    // 9 位: 和格子的字形字段一样宽, 否则 {bg,fg,glyph} 拼出来少一位会错位
    localparam [8:0] G_FULL = 9'd1, G_SHADE = 9'd2,
                     G_H    = 9'd6, G_V     = 9'd7,
                     G_TL   = 9'd8, G_TR    = 9'd9,
                     G_BL   = 9'd10, G_BR   = 9'd11;

    //---------------------------------------------------------
    // 游戏寄存器
    //---------------------------------------------------------
    reg [3:0]  scene;

    // 动态插图：帧号 + 自动播放计时 + 暂停
    // ★ 本工程像素时钟 = 40MHz (800x600), 计数器因此要 23 位
    //   (5000000 > 2^22-1, 原来的 22 位装不下)
`ifdef SIM_FAST
    localparam [22:0] PIC_PERIOD = 23'd2_000_000;  // 仿真: 约 5 帧换一次, 一屏内不混帧
`else
    localparam [22:0] PIC_PERIOD = 23'd5_000_000;  // 40MHz / 8 = 8 帧每秒
`endif
    reg [22:0] pic_tmr;
    reg        pic_pause;
    // 注意: anim_frame/pic_tmr/pic_pause 全部只在下面的主 FSM 块里驱动,
    //       否则 HDL-8007 多驱动错误(自动播放与按键翻帧在同一块内仲裁)

    // 图片层只在插图页打开
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) anim_on <= 1'b0;
        else        anim_on <= (scene == SC_PIC);
    end

    //---------------------------------------------------------
    // 怪物立绘：淡入淡出
    //   进战斗 -> 从 0 涨到 8；敌人倒下 -> 从 8 退到 0，退干净才回地图
    //---------------------------------------------------------
`ifdef SIM_FAST
    localparam [21:0] FADE_STEP = 22'd20000;      // 仿真: 每级约 0.8ms
`else
    localparam [21:0] FADE_STEP = 22'd2_000_000;  // 上板: 每级约 80ms, 全程 0.64s
`endif

    reg [3:0]  mon_fade_r;
    reg [21:0] fade_tmr;
    reg        fade_dir;        // 1=淡入 0=淡出 (仅主 FSM 块驱动, 避免 HDL-8007 多驱动)

    assign mon_on   = (scene == SC_BATTLE);
    assign mon_id   = enemy_id;
    assign mon_fade = mon_fade_r;

    // 本块只负责"按 fade_dir 逐步改变透明度", 不写 fade_dir 本身
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mon_fade_r   <= 4'd0;
            fade_tmr     <= 22'd0;
        end else if (scene != SC_BATTLE) begin
            mon_fade_r   <= 4'd0;
            fade_tmr     <= 22'd0;
        end else if (fade_tmr >= FADE_STEP) begin
            fade_tmr <= 22'd0;
            if (fade_dir && mon_fade_r < 4'd8)      mon_fade_r <= mon_fade_r + 4'd1;
            else if (!fade_dir && mon_fade_r > 4'd0) mon_fade_r <= mon_fade_r - 4'd1;
        end else begin
            fade_tmr <= fade_tmr + 22'd1;
        end
    end
    reg [1:0]  cls;
    reg [9:0]  hp, maxhp, mp, maxmp;
    reg [7:0]  atk, def, wb, ab;
    reg [11:0] gold;
    reg [3:0]  lv, herb, pot, potxl;
    reg [9:0]  exp, need;
    reg [2:0]  area;
    reg [3:0]  kills;
    reg        boss_dead;

    reg [4:0]  enemy_id;
    reg [9:0]  ehp, emaxhp;
    reg [7:0]  eatk, edef;
    reg [9:0]  eexp, egold;
    reg        e_boss;
    reg [5:0]  e_spr;

    reg [9:0]  last_dmg;
    reg        req_stb;
    reg [1:0]  req_pri;
    reg [10:0] req_addr;
    reg [15:0] rnd;

    reg [2:0]  bst;
    localparam [2:0] B_IDLE = 3'd0, B_ENEMY = 3'd1, B_CHECK = 3'd2,
                     B_LVUP = 3'd3, B_DELAY = 3'd4;

    reg [21:0] dly;
`ifdef SIM_FAST
    // 仿真用: 把"出招 -> 敌人反击"的间隔缩短, 否则每次攻击要等 3M 周期(7 帧)
    localparam [21:0] DLY_MAX = 22'd200;
`else
    localparam [21:0] DLY_MAX = 22'd3_000_000;   // 上板: 约 0.12s, 让玩家看清消息
`endif

    reg        rendering;
    reg        redraw;

    assign dbg_scene = scene;
    assign dbg_hp    = hp;
    assign dbg_maxhp = maxhp;
    assign dbg_atk   = atk;
    assign dbg_def   = def;
    assign dbg_gold  = gold;
    assign dbg_lv    = lv;
    assign dbg_state = rstt;
    assign dbg_pc    = pc;
    assign dbg_ehp   = ehp;

    //---------------------------------------------------------
    // 派生量 / 伤害计算
    //---------------------------------------------------------
    wire [9:0] atk_t = {2'b00, atk} + {6'd0, wb};
    wire [9:0] def_t = {2'b00, def} + {6'd0, ab};
    wire [9:0] edef_h = {2'b00, edef[7:1]};
    wire [9:0] def_h  = def_t[9:1];
    wire [9:0] var_m  = 10'd56 + {6'd0, rnd[3:0]};

    // 普攻
    wire [9:0]  p_base = (atk_t > edef_h) ? (atk_t - edef_h) : 10'd1;
    wire [16:0] p_prod = p_base * var_m;
    wire [9:0]  p_dmg  = p_prod[15:6];

    // 技能
    reg [7:0] mul_q6, arm_q6, sk_cost;
    always @(*) begin
        case (cls)
            CL_WAR: begin mul_q6 = 8'd122; arm_q6 = 8'd38; sk_cost = 8'd10; end
            CL_MAG: begin mul_q6 = 8'd134; arm_q6 = 8'd26; sk_cost = 8'd14; end
            default:begin mul_q6 = 8'd112; arm_q6 = 8'd64; sk_cost = 8'd12; end
        endcase
    end

    wire [16:0] sk_a    = (atk_t * mul_q6) >> 6;
    wire [12:0] sk_d    = (edef * arm_q6) >> 6;
    wire [16:0] sk_base = (sk_a > {4'd0, sk_d[12:1]}) ? (sk_a - {4'd0, sk_d[12:1]}) : 17'd1;
    wire [23:0] sk_prod = sk_base * var_m;
    wire [16:0] sk_dmg17= sk_prod[22:6];
    wire [9:0]  sk_dmg  = (sk_dmg17 > 17'd999) ? 10'd999 : sk_dmg17[9:0];

    // 休息回血 / 死亡扣金(用宽位中间量, 避免乘法被截断)
    wire [13:0] rest_amt = ({4'd0, maxhp} * 14'd11) >> 4;
    wire [13:0] rest_new = {4'd0, hp} + rest_amt + 14'd15;
    wire [15:0] gold_lost= ({4'd0, gold} * 16'd4) / 16'd10;

    // 敌人
    wire [9:0]  e_base = (eatk > def_h) ? ({2'b00, eatk} - def_h) : 10'd1;
    wire [16:0] e_prod = e_base * var_m;
    wire [9:0]  e_dmg  = e_prod[15:6];

    //---------------------------------------------------------
    // ROM / 表
    //---------------------------------------------------------
    reg  [8:0]  cmd_a;
    wire [31:0] cmd_d;
    reg  [9:0] str_a;
    wire [15:0] str_d;
    reg  [11:0] art_a;
    wire [7:0]  art_d;

    wire [9:0]  scr_addr;
    wire [62:0] tab_ename;
    wire [53:0] tab_aname;
    wire [54:0] tab_adesc;
    wire [63:0] tab_es;
    wire [4:0]  ar_mob0, ar_mob1, ar_mob2, ar_mob3, ar_boss;
    wire [11:0] art_base;
    reg  [5:0]  art_id;      // 当前 ART 精灵编号(须在 u_ab 例化前声明)

    cmd_rom     u_cmd  (.clk(clk), .addr(cmd_a), .data(cmd_d));
    str_rom     u_str  (.clk(clk), .addr(str_a), .data(str_d));
    art_rom     u_art  (.clk(clk), .addr(art_a), .data(art_d));
    rpg_screens u_scr  (.scene(scene), .addr(scr_addr));
    rpg_artbase u_ab   (.id(art_id), .b(art_base));
    rpg_area    u_areamap (.area(area), .mob0(ar_mob0), .mob1(ar_mob1),
                           .mob2(ar_mob2), .mob3(ar_mob3), .boss(ar_boss));
    rpg_tables  u_tab  (
        .ename_id (enemy_id),
        .area_id  (area),
        .stat_id  (enemy_id),
        .sel      (1'b0),
        .ename    (tab_ename),
        .area_name(tab_aname),
        .adesc    (tab_adesc),
        .es       (tab_es)
    );

    // 血量低于三成，并且小怪已清/未清，和区域一起选一句。
    wire [13:0] hp_x10 = {1'b0, hp, 3'b0} + {3'b0, hp, 1'b0};
    wire [11:0] max_x3 = {1'b0, maxhp, 1'b0} + {2'b0, maxhp};
    wire        hp_low = hp_x10 < {2'b0, max_x3};
    wire        mobs_clear = (kills >= 4'd4) || boss_dead;
    wire [1:0]  ctx_var = hp_low ? (mobs_clear ? 2'd1 : 2'd2) : 2'd0;
    wire        boss_ready = (kills >= 4'd4) && !boss_dead;
    wire [10:0] ctx_addr, danger_addr;
    rpg_ctx u_ctx (
        .area  (area),
        .varq  (ctx_var),
        .ctx   (ctx_addr),
        .danger(danger_addr)
    );

    // 1 级抢占主字幕，2 级走侧栏，3 级排队。数值越小越优先。
    localparam [1:0] PRI_L1 = 2'd1, PRI_L2 = 2'd2, PRI_L3 = 2'd3;
`ifdef SIM_FAST
    localparam [26:0] T_L1   = 27'd20000;
    localparam [26:0] T_L2   = 27'd200000;
    localparam [26:0] T_BOSS = 27'd80000;  // 盖过整屏停留，避免演示还没看完就响
    localparam [26:0] T_BIG  = 27'd12000;
    localparam [26:0] T_CHAR = 27'd400;       // 仿真里逐字间隔，短于 1 级倒计时
    localparam [26:0] T_AFTER = 27'd4000;     // 整句跳完后，一行再留一会儿
    localparam [26:0] T_COVER = 27'd12000;    // 3 级黄字先亮，再被 1 级盖住
`else
    localparam [26:0] T_L1   = 27'd80_000_000;   // 盖过最长一句的逐字时间
    localparam [26:0] T_L2   = 27'd80_000_000;
    localparam [26:0] T_BOSS = 27'd20_000_000;   // 买完约半秒就报强敌
    localparam [26:0] T_BIG  = 27'd6_000_000;
    localparam [26:0] T_CHAR = 27'd4_000_000;    // 40MHz 下 0.1 秒一个字
    localparam [26:0] T_AFTER = 27'd8_000_000;   // 整句出来后再留 0.2 秒
    localparam [26:0] T_COVER = 27'd40_000_000;  // 黄字先停约 1 秒，再被红字盖住
`endif
    reg        banner_v, side_v, queue_v, alert_pending;
    reg [1:0]  banner_pri;
    // 整屏阶段才拉高视频红条。收成一行后关掉，避免英文条盖住中文。
    reg        splash_v;
    reg [1:0]  splash_pri;
    reg [10:0] splash_addr;
    reg [26:0] splash_tmr;
    reg        type_done;
    reg        type_ping;     // 整屏刚写出一个字，下一拍给警报
    // 新提示当拍的整屏请求。字幕寄存器要等时钟沿才更新，解释器直接看这组信号。
    reg        splash_req;
    reg [1:0]  splash_req_pri;
    reg [10:0] splash_req_addr;
    wire       scene_changed = (scene != scene_d);
    // 整屏还在，而且它对应的那条字幕没有被撤掉。回血或切走就马上收掉。
    wire       splash_alive = (banner_v && banner_addr == splash_addr &&
                               banner_pri == splash_pri) ||
                              (side_v && side_addr == splash_addr &&
                               splash_pri == PRI_L2);
    // 这几条每回合都会出现，整屏会把战斗演示拖死。
    wire       chatter = (banner_addr_n == `MSG_HIT)  || (banner_addr_n == `MSG_SKILL) ||
                         (banner_addr_n == `MSG_POTION) || (banner_addr_n == `MSG_ENEMY) ||
                         (banner_addr_n == `MSG_NOMANA) || (banner_addr_n == `MSG_NOPOT);
    wire       show_big = splash_req ||
                          (splash_v && !type_done &&
                           !scene_changed && splash_alive);
    assign level1_on = splash_v && (splash_pri == 2'd1);
    // 1 级红、2 级橙、3 级黄。红底用白字，橙/黄底用黑字。
    function [3:0] pri_bg;
        input [1:0] p;
        begin
            case (p)
                2'd1:    pri_bg = 4'd5;
                2'd2:    pri_bg = 4'd7;
                default: pri_bg = 4'd8;
            endcase
        end
    endfunction
    function [3:0] pri_ink;
        input [1:0] p;
        begin
            pri_ink = (p == 2'd1) ? 4'd4 : 4'd0;
        end
    endfunction
    reg [10:0] banner_addr, side_addr, queue_addr;
    reg [26:0] banner_tmr, side_tmr, boss_tmr, cover_tmr;
    reg        boss_arm, boss_latched, map_l1_done, cover_arm;
    reg [3:0]  scene_d;
    reg [2:0]  area_d;
    reg        hp_low_d;
    reg [1:0]  ctx_var_d;

    //---------------------------------------------------------
    // 解释器
    //---------------------------------------------------------
    localparam [4:0] R_IDLE = 5'd0, R_FETCH = 5'd1, R_DEC = 5'd2,
                     R_CLR  = 5'd3, R_TXT_A = 5'd4, R_TXT_B = 5'd5, R_TXT_C = 5'd6,
                     R_NUM  = 5'd7, R_BAR  = 5'd8,
                     R_ART_A = 5'd9, R_ART_B = 5'd10, R_ART_C = 5'd11,
                     R_NAME = 5'd12, R_FRM = 5'd13,
                     // 同步 ROM 的输出要 2 拍才有效, 取址后必须空等 1 拍
                     R_FETCH_W = 5'd14, R_TXT_W = 5'd15, R_ART_W = 5'd16,
                     R_BIG_CLR = 5'd17, R_BIG_LEN = 5'd18,
                     R_BIG_LEN_W = 5'd19, R_BIG_LEN_B = 5'd20,
                     R_TYPE_A = 5'd21, R_TYPE_W = 5'd22, R_TYPE_B = 5'd23,
                     R_TYPE_C = 5'd24, R_TYPE_WAIT = 5'd25, R_TYPE_HOLD = 5'd26;

    reg [4:0]  rstt;
    reg [9:0]  pc;
    reg [3:0]  fg, bg;
    reg [5:0]  tx, ty;

    reg [10:0] cnt11, sptr;
    reg [5:0]  ncell;
    reg [3:0]  digit_idx, num_cnt;
    reg [13:0] num_rem;
    reg        num_leading;
    reg [13:0] bar_prod, bar_m;
    reg [3:0]  bar_n, bar_t;
    reg [9:0]  bar_cur, bar_max;
    reg [3:0]  art_row, art_col;
    reg [5:0]  frm_x, frm_y, frm_i;
    reg [5:0]  frm_w;
    reg [4:0]  frm_h, frm_j;
    reg [8:0]  ch;
    reg        big_draw;
    reg [5:0]  big_len, big_got, big_row;
    reg [10:0] big_base;
    reg [26:0] type_tmr;

    wire [3:0]  op   = cmd_d[31:28];
    wire [4:0]  cy   = cmd_d[27:23];
    wire [5:0]  cx   = cmd_d[22:17];
    wire [16:0] arg  = cmd_d[16:0];

    // 数字显示的取值
    reg [13:0] src_val;
    always @(*) begin
        case (arg[4:0])
            5'd0:  src_val = {4'd0, hp};
            8'd1:  src_val = {4'd0, maxhp};
            8'd2:  src_val = {6'd0, mp};
            8'd3:  src_val = {6'd0, maxmp};
            8'd4:  src_val = {4'd0, atk_t};
            8'd5:  src_val = {4'd0, def_t};
            8'd6:  src_val = {2'b00, gold};
            8'd7:  src_val = {10'd0, lv};
            8'd8:  src_val = {4'd0, exp};
            8'd9:  src_val = {4'd0, need};
            5'd10: src_val = {10'd0, pot};
            5'd11: src_val = {10'd0, potxl};
            5'd12: src_val = {10'd0, kills};
            5'd13: src_val = {4'd0, ehp};
            5'd14: src_val = {4'd0, emaxhp};
            5'd15: src_val = {4'd0, last_dmg};
            default: src_val = 14'd0;
        endcase
    end

    // 进度条上限
    wire [3:0]  bar_w = arg[12:8];                     // 进度条宽度(格数)
    // 进度条的上限也按源号取
    reg [9:0] bar_max_sel;
    always @(*) begin
        case (arg[7:4])
            4'd1:  bar_max_sel = maxhp;
            4'd3:  bar_max_sel = {2'b00, maxmp};
            4'd9:  bar_max_sel = need;
            4'd13,
            4'd14: bar_max_sel = emaxhp;
            default: bar_max_sel = 10'd100;
        endcase
    end
    // 数字位权
    wire [13:0] pw = (digit_idx == 4'd0) ? 14'd10000 :
                     (digit_idx == 4'd1) ? 14'd1000  :
                     (digit_idx == 4'd2) ? 14'd100   :
                     (digit_idx == 4'd3) ? 14'd10    : 14'd1;
    // 精灵颜色: 按怪物档位取色(史莱姆绿 -> 深渊领主紫)
    reg [3:0] art_fg;
    always @(*) begin
        case (art_id)
            6'd0,  6'd10: art_fg = 4'd9;    // 绿
            6'd1,  6'd11: art_fg = 4'd10;   // 亮绿
            6'd2,  6'd3:  art_fg = 4'd10;   // 森林系
            6'd4:         art_fg = 4'd11;   // 青
            6'd5:         art_fg = 4'd15;   // 石魔: 银
            6'd6,  6'd12: art_fg = 4'd7;    // 火系: 橙
            6'd7,  6'd13: art_fg = 4'd5;    // 熔岩: 红
            6'd8:         art_fg = 4'd15;   // 不死骑士: 银
            6'd9:         art_fg = 4'd13;   // 骨法师: 紫
            6'd14:        art_fg = 4'd14;   // 深渊领主: 品红
            default:      art_fg = 4'd3;    // 场景图标: 浅灰
        endcase
    end

    // 精灵地址
    wire [11:0] art_addr = art_base +
                           ({7'd0, art_row} * 12) + {8'd0, art_col};

    wire [10:0] cell_a = (ty * 40) + tx;

    //=========================================================
    // 渲染
    //=========================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rstt      <= R_IDLE;
            rendering <= 1'b1;
            we        <= 1'b0;
            waddr     <= 11'd0;
            wdata     <= 17'd0;
            pc        <= 10'd0;
            fg        <= 4'd3;
            bg        <= 4'd0;
            tx        <= 6'd0;
            ty        <= 6'd0;
            cnt11     <= 11'd0;
            sptr      <= 11'd0;
            ncell     <= 6'd0;
            digit_idx <= 4'd0;
            num_rem   <= 14'd0;
            num_cnt   <= 4'd0;
            num_leading <= 1'b1;
            bar_prod  <= 14'd0;
            bar_m     <= 14'd0;
            bar_n     <= 4'd0;
            bar_t     <= 4'd0;
            bar_cur   <= 10'd0;
            bar_max   <= 10'd0;
            art_row   <= 4'd0;
            art_col   <= 4'd0;
            art_id    <= 5'd0;
            frm_w     <= 6'd0;
            frm_h     <= 5'd0;
            frm_i     <= 6'd0;
                    frm_j     <= 5'd0;
            frm_x     <= 6'd0;
            frm_y     <= 6'd0;
            ch        <= 8'd0;
            big_draw  <= 1'b0;
            big_len   <= 6'd0;
            big_got   <= 6'd0;
            big_row   <= 6'd0;
            big_base  <= 11'd0;
            type_tmr  <= 27'd0;
            type_done <= 1'b0;
            type_ping <= 1'b0;
            cmd_a     <= 9'd0;
            str_a     <= 10'd0;
            art_a     <= 12'd0;
        end else begin
            we <= 1'b0;
            type_ping <= 1'b0;

            case (rstt)

            R_IDLE: begin
                rendering <= 1'b0;
                if (redraw && show_big) begin
                    rendering <= 1'b1;
                    big_draw  <= 1'b0;
                    bg        <= pri_bg(splash_req ? splash_req_pri : splash_pri);
                    fg        <= pri_ink(splash_req ? splash_req_pri : splash_pri);
                    cnt11     <= 11'd0;
                    sptr      <= splash_req ? splash_req_addr : splash_addr;
                    big_base  <= splash_req ? splash_req_addr : splash_addr;
                    big_len   <= 6'd0;
                    big_row   <= ((splash_req ? splash_req_pri : splash_pri) == PRI_L1)
                                 ? 6'd8 : 6'd14;
                    rstt      <= R_BIG_CLR;
                end else if (redraw && !splash_v) begin
                    rendering <= 1'b1;
                    pc        <= scr_addr;
                    fg        <= 4'd3;
                    bg        <= 4'd0;
                    rstt      <= R_FETCH;
                end
            end

            R_FETCH: begin
                cmd_a <= pc;
                rstt  <= R_FETCH_W;
            end

            R_FETCH_W: begin          // 同步 ROM 输出就绪
                rstt <= R_DEC;
            end

            R_DEC: begin
                case (op)
                4'd0: begin                       // END
                    rstt      <= R_IDLE;
                    rendering <= 1'b0;
                end
                4'd1: begin                       // CLEAR
                    bg    <= arg[3:0];
                    fg    <= 4'd3;
                    cnt11 <= 11'd0;
                    rstt  <= R_CLR;
                end
                4'd2: begin                       // COLOR
                    fg   <= arg[3:0];
                    bg   <= arg[7:4];
                    pc   <= pc + 10'd1;
                    rstt <= R_FETCH;
                end
                4'd3: begin                       // TEXT
                    sptr <= arg[10:0];
                    tx   <= cx;
                    ty   <= cy;
                    rstt <= R_TXT_A;
                end
                4'd4: begin                       // NUM
                    num_rem     <= src_val;
                    digit_idx   <= 4'd0;
                    num_cnt     <= 4'd0;
                    num_leading <= 1'b1;
                    tx          <= cx;
                    ty          <= cy;
                    rstt        <= R_NUM;
                end
                4'd5: begin                       // ART
                    art_id  <= (arg[7:0] == 8'd255) ? e_spr :
                               (arg[7:0] == 8'd254) ? (6'd30 + {3'd0, area}) : {2'd0, arg[5:0]};
                    art_row <= 4'd0;
                    art_col <= 4'd0;
                    frm_x   <= cx;
                    frm_y   <= {1'b0, cy};
                    rstt    <= R_ART_A;
                end
                4'd6: begin                       // BAR
                    bar_cur  <= src_val[9:0];
                    bar_max  <= bar_max_sel;
                    bar_prod <= {4'd0, src_val[9:0]} * {10'd0, bar_w};  // 比例按实际宽度算
                    bar_m    <= {4'd0, bar_max_sel};
                    bar_t    <= 4'd0;
                    tx       <= cx;
                    ty       <= cy;
                    rstt     <= R_BAR;
                end
                4'd7: begin                       // ENAME
                    tx    <= cx;
                    ty    <= cy;
                    ncell <= 6'd7;
                    cnt11 <= 11'd0;
                    rstt  <= R_NAME;
                end
                4'd8: begin                       // ANAME
                    tx    <= cx;
                    ty    <= cy;
                    ncell <= 6'd6;
                    cnt11 <= 11'd0;
                    rstt  <= R_NAME;
                end
                4'd9: begin                       // MSG: 商店/战斗字幕，底色按等级
                    if (banner_v) begin
                        sptr <= banner_addr;
                        bg   <= pri_bg(banner_pri);
                        fg   <= pri_ink(banner_pri);
                    end else if (scene == SC_SHOP) begin
                        sptr <= `MSG_HINT;
                        fg   <= 4'd1;
                    end else if (scene == SC_SHOP2) begin
                        sptr <= `MSG_HINT2;
                        fg   <= 4'd1;
                    end else begin
                        sptr <= `MSG_NONE;
                        fg   <= 4'd3;
                    end
                    tx   <= cx;
                    ty   <= cy;
                    rstt <= R_TXT_A;
                end
                4'd11: begin                      // ADESC: 上下文句子，1 级时整行换成警告色
                    if (banner_v && banner_pri == 2'd1) begin
                        sptr <= banner_addr;
                        bg   <= pri_bg(banner_pri);
                        fg   <= pri_ink(banner_pri);
                    end else begin
                        sptr <= ctx_addr;
                    end
                    tx   <= cx;
                    ty   <= cy;
                    rstt <= R_TXT_A;
                end
                4'd12: begin                      // SIDE: 2 级提示，橙底，和区域句子共存
                    if (banner_v && banner_pri == 2'd1) begin
                        sptr <= `MSG_NONE;
                        fg   <= 4'd3;
                    end else if (side_v) begin
                        sptr <= side_addr;
                        bg   <= pri_bg(PRI_L2);
                        fg   <= pri_ink(PRI_L2);
                    end else begin
                        sptr <= `MSG_FAR;
                        fg   <= 4'd3;
                    end
                    tx   <= cx;
                    ty   <= cy;
                    rstt <= R_TXT_A;
                end
                4'd10: begin                      // FRAME
                    frm_x <= cx;
                    frm_y <= {1'b0, cy};
                    frm_w <= arg[5:0];
                    frm_h <= arg[12:8];
                    frm_i <= 6'd0;
                    frm_j <= 5'd0;
                    rstt  <= R_FRM;
                end
                default: begin
                    rstt      <= R_IDLE;
                    rendering <= 1'b0;
                end
                endcase
            end

            R_CLR: begin
                we    <= 1'b1;
                waddr <= cnt11;
                wdata <= {bg, 4'd0, 9'd0};
                if (cnt11 == 11'd1199) begin
                    pc   <= pc + 10'd1;
                    rstt <= R_FETCH;
                end else begin
                    cnt11 <= cnt11 + 11'd1;
                end
            end

            R_TXT_A: begin
                str_a <= sptr;
                rstt  <= R_TXT_W;
            end

            R_TXT_W: begin            // 同步 ROM 输出就绪
                rstt <= R_TXT_B;
            end

            R_TXT_B: begin
                ch   <= str_d[8:0];
                rstt <= R_TXT_C;
            end

            R_TXT_C: begin
                // sptr 越界(或字符串没有结束符)时也要收手, 否则会把整屏刷成垃圾
                if (str_d == 16'hFFFF || sptr >= 11'd1020 ||
                    (big_draw && big_got == big_len)) begin
                    if (big_draw) begin
                        big_draw  <= 1'b0;
                        rstt      <= R_IDLE;
                        rendering <= 1'b0;
                    end else begin
                        pc   <= pc + 10'd1;
                        rstt <= R_FETCH;
                    end
                end else begin
                    if (tx < 6'd40) begin
                        we    <= 1'b1;
                        waddr <= cell_a;
                        wdata <= {bg, fg, ch};
                    end
                    if (tx == 6'd39) begin tx <= 6'd0; ty <= ty + 6'd1; end
                    else             tx <= tx + 6'd1;
                    sptr <= sptr + 11'd1;
                    if (big_draw)
                        big_got <= big_got + 6'd1;
                    rstt <= R_TXT_A;
                end
            end

            R_NUM: begin
                if (num_rem >= pw) begin
                    num_rem <= num_rem - pw;
                    num_cnt <= num_cnt + 4'd1;
                end else begin
                    if (!num_leading || num_cnt != 4'd0 || digit_idx == 4'd4) begin
                        if (tx < 6'd40) begin
                            we    <= 1'b1;
                            waddr <= cell_a;
                            wdata <= {bg, fg, `G_DIG_BASE + {4'd0, num_cnt}};
                        end
                        if (tx == 6'd39) begin tx <= 6'd0; ty <= ty + 6'd1; end
                        else             tx <= tx + 6'd1;
                        num_leading <= 1'b0;
                    end
                    num_cnt <= 4'd0;
                    if (digit_idx == 4'd4) begin
                        pc   <= pc + 10'd1;
                        rstt <= R_FETCH;
                    end else begin
                        digit_idx <= digit_idx + 4'd1;
                    end
                end
            end

            R_BAR: begin
                if (bar_t == bar_w) begin
                    pc   <= pc + 10'd1;
                    rstt <= R_FETCH;
                end else begin
                    we    <= 1'b1;
                    waddr <= cell_a;
                    wdata <= {bg, fg, (bar_prod >= bar_m) ? G_FULL : G_SHADE};
                    bar_m <= bar_m + {4'd0, bar_max};
                    bar_t <= bar_t + 4'd1;
                    if (tx == 6'd39) begin tx <= 6'd0; ty <= ty + 6'd1; end
                    else             tx <= tx + 6'd1;
                end
            end

            // 精灵: 9 行 x 12 列, 每个像素一次 ROM 读
            R_ART_A: begin
                if (art_row == 4'd9) begin
                    pc   <= pc + 10'd1;
                    rstt <= R_FETCH;
                end else begin
                    art_a <= art_addr;
                    rstt  <= R_ART_W;
                end
            end

            R_ART_W: begin            // 同步 ROM 输出就绪
                rstt <= R_ART_B;
            end

            R_ART_B: begin
                ch   <= art_d;
                rstt <= R_ART_C;
            end

            R_ART_C: begin
                // 空白格也写(与参考渲染器一致, 精灵块 12x9=108 格, 开销可忽略)
                we    <= 1'b1;
                waddr <= (({5'd0, frm_y} + {8'd0, art_row}) * 40) +
                         {5'd0, frm_x} + {8'd0, art_col};
                wdata <= {bg, art_fg, ch};
                if (art_col == 4'd11) begin
                    art_col <= 4'd0;
                    art_row <= art_row + 4'd1;
                end else begin
                    art_col <= art_col + 4'd1;
                end
                rstt <= R_ART_A;
            end

            R_NAME: begin
                if (cnt11 >= ncell) begin
                    pc   <= pc + 10'd1;
                    rstt <= R_FETCH;
                end else begin
                    if (tx < 6'd40) begin
                        we    <= 1'b1;
                        waddr <= cell_a;
                        wdata <= {bg, fg,
                                  (ncell == 6'd7) ? tab_ename[cnt11[2:0]*9 +: 9]
                                                  : tab_aname[cnt11[2:0]*9 +: 9]};
                    end
                    tx    <= tx + 6'd1;
                    cnt11 <= cnt11 + 11'd1;
                end
            end

            R_FRM: begin
                if (frm_j == frm_h) begin
                    pc   <= pc + 10'd1;
                    rstt <= R_FETCH;
                end else if (frm_i == frm_w) begin
                    frm_i <= 6'd0;
                    frm_j <= frm_j + 5'd1;
                end else begin
                    // 只写边框: 内部格子本来就该是空的, 写了也是白写
                    // (实测 40x30 的框要 1200 格, 只写边框只要 136 格)
                    if ((frm_j == 5'd0) || (frm_j == frm_h - 5'd1) ||
                        (frm_i == 6'd0) || (frm_i == frm_w - 6'd1))
                        we <= 1'b1;
                    waddr <= (({5'd0, frm_y} + {8'd0, frm_j}) * 40) +
                             {5'd0, frm_x} + {8'd0, frm_i};
                    // 先判底行: 高为 1 的分隔框上下是同一行, 底角优先(与参考渲染器一致)
                    wdata <= {4'd0, fg,
                              (frm_j == frm_h - 5'd1) ? ((frm_i == 6'd0) ? G_BL :
                                                 (frm_i == frm_w - 6'd1) ? G_BR : G_H) :
                              (frm_j == 4'd0) ? ((frm_i == 6'd0) ? G_TL :
                                                 (frm_i == frm_w - 6'd1) ? G_TR : G_H) :
                              ((frm_i == 6'd0) || (frm_i == frm_w - 6'd1)) ? G_V : 9'd0};
                    frm_i <= frm_i + 6'd1;
                end
            end

            // 整屏：实心色块铺满，再把这句话居中画在色块上。1 级避开视频红条。
            R_BIG_CLR: begin
                we    <= 1'b1;
                waddr <= cnt11;
                wdata <= {4'd0, bg, G_FULL};
                if (cnt11 == 11'd1199) begin
                    sptr <= big_base;
                    rstt <= R_BIG_LEN;
                end else begin
                    cnt11 <= cnt11 + 11'd1;
                end
            end

            R_BIG_LEN: begin
                str_a <= sptr[9:0];
                rstt  <= R_BIG_LEN_W;
            end

            R_BIG_LEN_W: begin
                rstt <= R_BIG_LEN_B;
            end

            R_BIG_LEN_B: begin
                if (str_d == 16'hFFFF || big_len == 6'd36 || sptr >= 11'd1020) begin
                    tx       <= (6'd40 - big_len) >> 1;
                    ty       <= big_row;
                    sptr     <= big_base;
                    big_got  <= 6'd0;
                    rstt     <= R_TYPE_A;
                end else begin
                    big_len <= big_len + 6'd1;
                    sptr    <= sptr + 11'd1;
                    rstt    <= R_BIG_LEN;
                end
            end

            // 整屏句子：一个字写上，再等 0.1 秒，再写下一个。
            R_TYPE_A: begin
                str_a <= sptr[9:0];
                rstt  <= R_TYPE_W;
            end

            R_TYPE_W: begin
                rstt <= R_TYPE_B;
            end

            R_TYPE_B: begin
                ch   <= str_d[8:0];
                rstt <= R_TYPE_C;
            end

            R_TYPE_C: begin
                if (str_d == 16'hFFFF || big_got == big_len || sptr >= 11'd1020) begin
                    type_tmr <= T_CHAR;
                    rstt     <= R_TYPE_HOLD;
                end else begin
                    if (tx < 6'd40) begin
                        we    <= 1'b1;
                        waddr <= cell_a;
                        wdata <= {bg, fg, ch};
                    end
                    tx       <= tx + 6'd1;
                    sptr     <= sptr + 11'd1;
                    big_got  <= big_got + 6'd1;
                    type_tmr <= T_CHAR;
                    type_ping <= 1'b1;
                    // 最后一个字写上后只再停 0.1 秒，然后收成一行。
                    if (big_got + 6'd1 == big_len)
                        rstt <= R_TYPE_HOLD;
                    else
                        rstt <= R_TYPE_WAIT;
                end
            end

            R_TYPE_WAIT: begin
                if (type_tmr == 27'd0)
                    rstt <= R_TYPE_A;
                else
                    type_tmr <= type_tmr - 27'd1;
            end

            R_TYPE_HOLD: begin
                if (type_tmr == 27'd0) begin
                    type_done <= 1'b1;
                    rendering <= 1'b0;
                    rstt      <= R_IDLE;
                end else
                    type_tmr <= type_tmr - 27'd1;
            end

            default: rstt <= R_IDLE;
            endcase

            // 提示被撤掉，或来了新的一句，就停掉正在跳的字。
            if ((splash_req || !show_big) &&
                (rstt == R_BIG_CLR || rstt == R_BIG_LEN || rstt == R_BIG_LEN_W ||
                 rstt == R_BIG_LEN_B || rstt == R_TYPE_A || rstt == R_TYPE_W ||
                 rstt == R_TYPE_B || rstt == R_TYPE_C || rstt == R_TYPE_WAIT ||
                 rstt == R_TYPE_HOLD)) begin
                rstt      <= R_IDLE;
                rendering <= 1'b0;
                big_draw  <= 1'b0;
                we        <= 1'b0;
            end
            if (splash_req)
                type_done <= 1'b0;
        end
    end

    //=========================================================
    // 游戏状态机
    //=========================================================
    // 按键边沿检测: 电平触发会被一次长按连跳好几个界面
    reg  [3:0] key_d;
    wire [3:0] key_e = key & ~key_d;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) key_d <= 4'd0;
        else        key_d <= key;
    end

    reg start_battle;

    // 随机数
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) rnd <= 16'hACE1;
        else        rnd <= {rnd[14:0], rnd[15] ^ rnd[13] ^ rnd[12] ^ rnd[10]};
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            scene     <= SC_TITLE;
            cls       <= CL_WAR;
            hp        <= 10'd130; maxhp <= 10'd130;
            mp        <= 10'd40;  maxmp <= 10'd40;
            atk       <= 8'd13;   def   <= 8'd9;
            wb        <= 8'd0;    ab    <= 8'd0;
            gold      <= 12'd40;
            lv        <= 4'd1;
            pot       <= 4'd2;    potxl <= 4'd0;
            exp       <= 10'd0;   need  <= 10'd24;
            area      <= 3'd0;
            kills     <= 4'd0;
            boss_dead <= 1'b0;
            enemy_id  <= 5'd0;
            ehp       <= 10'd36;  emaxhp <= 10'd36;
            eatk      <= 8'd8;    edef   <= 8'd2;
            eexp      <= 10'd9;   egold  <= 10'd7;
            e_boss    <= 1'b0;
            e_spr     <= 5'd0;
            last_dmg  <= 10'd0;
            req_stb   <= 1'b0;
            req_pri   <= 2'd0;
            req_addr  <= `MSG_NONE;
            bst       <= B_IDLE;
            dly       <= 22'd0;
            redraw    <= 1'b1;
            start_battle <= 1'b0;
            pic_tmr      <= 23'd0;
            pic_pause    <= 1'b0;
            anim_frame   <= 3'd0;
            fade_dir     <= 1'b1;
            sfx_id       <= 4'd0;
            sfx_trig     <= 1'b0;
            hit_trig     <= 1'b0;
            hit_kind     <= 2'd0;
        end else begin
            // 渲染还没回到空闲时，保留这次重绘请求，避免和自动重绘撞车后丢画面。
            if (rstt == R_IDLE)
                redraw <= 1'b0;
            req_stb <= 1'b0;
            sfx_trig <= 1'b0;                        // 音效触发默认清零(单拍脉冲)
            hit_trig <= 1'b0;
            if (alert_pending && !rendering)
                redraw <= 1'b1;
            if (scene != SC_PIC) pic_tmr <= 23'd0;   // 离开插图页就清自动播放计时

            // 四个键各一声。后面的战斗、购买音效会盖过这一声。
            if (key_e[0]) begin
                sfx_id   <= 4'd1;             // 1 键 1200Hz
                sfx_trig <= 1'b1;
            end else if (key_e[1]) begin
                sfx_id   <= 4'd11;            // 2 键 1800Hz
                sfx_trig <= 1'b1;
            end else if (key_e[2]) begin
                sfx_id   <= 4'd13;            // 3 键 2600Hz
                sfx_trig <= 1'b1;
            end else if (key_e[3]) begin
                sfx_id   <= 4'd7;             // 4 键 1000Hz
                sfx_trig <= 1'b1;
            end

            //---------------- 开战: 装载敌人 ----------------
            if (start_battle) begin
                start_battle <= 1'b0;
                scene        <= SC_BATTLE;
                bst          <= B_IDLE;
                dly          <= 22'd0;
                fade_dir     <= 1'b1;        // 新一场战斗: 立绘重新淡入
                ehp          <= tab_es[9:0];
                emaxhp       <= tab_es[9:0];
                eatk         <= tab_es[17:10];
                edef         <= tab_es[25:18];
                eexp         <= tab_es[35:26];
                egold        <= tab_es[47:36];
                e_spr        <= tab_es[52:48];
                e_boss       <= tab_es[53];
                req_stb      <= 1'b1;
                req_pri      <= tab_es[53] ? PRI_L1 : PRI_L2;
                req_addr     <= tab_es[53] ? `MSG_BOSS : `MSG_MEET;
                last_dmg     <= 10'd0;
                redraw       <= 1'b1;
            end

            if (!rendering) begin

                //---------------- 战斗自动流程 ----------------
                if (scene == SC_BATTLE) begin
                    case (bst)
                    B_IDLE: dly <= 22'd0;

                    B_DELAY: begin
                        if (dly >= DLY_MAX) begin
                            dly  <= 22'd0;
                            bst  <= B_ENEMY;
                        end else begin
                            dly <= dly + 22'd1;
                        end
                    end

                    B_ENEMY: begin
                        if (ehp != 10'd0) begin
                            last_dmg <= e_dmg;
                            hp       <= (hp > e_dmg) ? (hp - e_dmg) : 10'd0;
                            req_stb  <= 1'b1;
                            req_pri  <= PRI_L2;
                            req_addr <= `MSG_ENEMY;
                        end
                        bst    <= B_CHECK;
                        redraw <= 1'b1;
                        sfx_id   <= 4'd2;            // 被怪物击中: 低音
                        sfx_trig <= 1'b1;
                        if (ehp != 10'd0) begin
                            hit_kind <= 2'd3;        // 怪物还活着才扑过来
                            hit_trig <= 1'b1;
                        end
                    end

                    B_CHECK: begin
                        if (ehp == 10'd0) begin
                            fade_dir <= 1'b0;            // 敌人倒下 -> 立绘淡出
                            sfx_id   <= 4'd3;            // 击杀: 高音短促
                            sfx_trig <= 1'b1;
                            gold     <= gold + egold;
                            exp      <= exp + eexp;
                            kills    <= (kills < 4'd15) ? (kills + 4'd1) : kills;
                            if (e_boss) boss_dead <= 1'b1;
                            req_stb  <= 1'b1;
                            req_pri  <= PRI_L2;
                            req_addr <= `MSG_KILL;
                            bst      <= B_LVUP;
                        end else if (hp == 10'd0) begin
                            scene <= SC_DEAD;
                            bst   <= B_IDLE;
                            sfx_id   <= 4'd5;            // 阵亡: 低沉长音
                            sfx_trig <= 1'b1;
                        end else begin
                            bst   <= B_IDLE;
                        end
                        redraw <= 1'b1;
                    end

                    B_LVUP: begin
                        if (exp >= need) begin
                            exp      <= exp - need;
                            need     <= (({2'd0, need} * 12'd3) >> 1) + 10'd8;
                            lv       <= lv + 4'd1;
                            maxhp    <= maxhp + 10'd26;
                            maxmp    <= maxmp + 10'd8;
                            atk      <= atk + 8'd4;
                            def      <= def + 8'd2;
                            hp       <= maxhp + 10'd26;
                            mp       <= maxmp + 10'd8;
                            req_stb  <= 1'b1;
                            req_pri  <= PRI_L2;
                            req_addr <= `MSG_LEVEL;
                            redraw   <= 1'b1;
                            sfx_id   <= 4'd4;            // 升级: 中高音较长
                            sfx_trig <= 1'b1;
                        end else if (mon_fade_r == 4'd0) begin
                            scene  <= SC_MAP;
                            bst    <= B_IDLE;
                            redraw <= 1'b1;
                        end
                    end

                    default: bst <= B_IDLE;
                    endcase
                end

                //---------------- 按键 ----------------
                // 注意: 这里是独立的 if, 不是上面 if 的 else!
                // 原来写成 else if, 结果战斗场景永远进不到按键分支 —— 战斗中按键全无反应。
                if (bst == B_IDLE) begin
                    case (scene)

                    SC_TITLE: begin
                        if (key_e != 4'd0) begin
                            if (key_e[1]) begin
                                scene    <= SC_PIC;
                                pic_pause <= 1'b0;
                            end else begin
                                scene <= SC_CLASS;
                            end
                            redraw <= 1'b1;
                        end
                    end

                    SC_CLASS: begin
                        if (key_e != 4'd0) begin
                            if (key_e[1]) begin
                                cls <= CL_MAG; maxhp <= 10'd92;  maxmp <= 10'd90;
                                atk <= 8'd11;  def <= 8'd5;  hp <= 10'd92;  mp <= 10'd90;
                            end else if (key_e[2]) begin
                                cls <= CL_RAN; maxhp <= 10'd106; maxmp <= 10'd56;
                                atk <= 8'd11;  def <= 8'd7;  hp <= 10'd106; mp <= 10'd56;
                            end else begin
                                cls <= CL_WAR; maxhp <= 10'd130; maxmp <= 10'd40;
                                atk <= 8'd13;  def <= 8'd9;  hp <= 10'd130; mp <= 10'd40;
                            end
                            gold      <= 12'd40;
                            lv        <= 4'd1;
                            exp       <= 10'd0;  need <= 10'd24;
                            herb      <= 4'd2;   pot   <= 4'd1;   potxl <= 4'd0;
                            wb        <= 8'd0;   ab    <= 8'd0;
                            area      <= 3'd0;   kills <= 4'd0;
                            boss_dead <= 1'b0;
                            scene     <= SC_MAP;
                            redraw    <= 1'b1;
                        end
                    end

                    SC_MAP: begin
                        if (key_e[0]) begin
                            // 每个区域 4 只小怪，用随机数低 2 位挑
                            case (rnd[1:0])
                                2'd0:    enemy_id <= ar_mob0;
                                2'd1:    enemy_id <= ar_mob1;
                                2'd2:    enemy_id <= ar_mob2;
                                default: enemy_id <= ar_mob3;
                            endcase
                            start_battle <= 1'b1;
                        end else if (key_e[1]) begin
                            scene  <= SC_SHOP;
                            redraw <= 1'b1;
                        end else if (key_e[2]) begin
                            if (gold >= 12'd10) begin
                                gold <= gold - 12'd10;
                                hp   <= (rest_new > {4'd0, maxhp}) ? maxhp : rest_new[9:0];
                                mp   <= (mp + (maxmp >> 1) > maxmp) ? maxmp : mp + (maxmp >> 1);
                                sfx_id   <= 4'd8;            // 旅店休息回血
                                sfx_trig <= 1'b1;
                            end else begin
                                req_stb  <= 1'b1;
                                req_pri  <= PRI_L2;
                                req_addr <= `MSG_NOGOLD;
                                sfx_id   <= 4'd10;           // 金币不足
                                sfx_trig <= 1'b1;
                            end
                            redraw <= 1'b1;
                        end else if (key_e[3]) begin
                            if (boss_dead) begin
                                if (area == 3'd3) begin
                                    scene <= SC_WIN;
                                    sfx_id   <= 4'd6;    // 通关: 高音长鸣
                                    sfx_trig <= 1'b1;
                                end else begin
                                    area      <= area + 3'd1;
                                    kills     <= 4'd0;
                                    boss_dead <= 1'b0;
                                    sfx_id    <= 4'd11;  // 进入下一区域: 翻页音
                                    sfx_trig  <= 1'b1;
                                end
                            end else if (kills >= 4'd4) begin
                                enemy_id     <= ar_boss;
                                start_battle <= 1'b1;
                                sfx_id       <= 4'd12;   // BOSS 出场: 低沉长鸣
                                sfx_trig     <= 1'b1;
                            end
                            redraw <= 1'b1;
                        end
                    end

                    SC_BATTLE: begin
                        if (key_e[0]) begin
                            last_dmg <= p_dmg;
                            ehp      <= (ehp > p_dmg) ? (ehp - p_dmg) : 10'd0;
                            req_stb  <= 1'b1;
                            req_pri  <= PRI_L2;
                            req_addr <= `MSG_HIT;
                            bst      <= B_DELAY;
                            sfx_id   <= 4'd11;           // 挥击: 短促高频
                            sfx_trig <= 1'b1;
                            hit_kind <= 2'd1;
                            hit_trig <= 1'b1;
                            redraw   <= 1'b1;
                        end else if (key_e[1]) begin
                            if ({2'b00, mp} >= {2'b00, sk_cost}) begin
                                mp       <= mp - {2'b00, sk_cost};
                                last_dmg <= sk_dmg;
                                ehp      <= (ehp > sk_dmg) ? (ehp - sk_dmg) : 10'd0;
                                req_stb  <= 1'b1;
                                req_pri  <= PRI_L2;
                                req_addr <= `MSG_SKILL;
                                bst      <= B_DELAY;
                                sfx_id   <= 4'd13;       // 释放技能: 高音
                                sfx_trig <= 1'b1;
                                hit_kind <= 2'd2;
                                hit_trig <= 1'b1;
                            end else begin
                                req_stb  <= 1'b1;
                                req_pri  <= PRI_L2;
                                req_addr <= `MSG_NOMANA;
                                sfx_id   <= 4'd14;       // 蓝不够: 失败音
                                sfx_trig <= 1'b1;
                            end
                            redraw <= 1'b1;
                        end else if (key_e[2]) begin
                            if (potxl != 4'd0) begin
                                potxl    <= potxl - 4'd1;
                                hp       <= (hp + 10'd130 > maxhp) ? maxhp : (hp + 10'd130);
                                req_stb  <= 1'b1;
                                req_pri  <= PRI_L2;
                                req_addr <= `MSG_POTION;
                                bst      <= B_DELAY;
                                sfx_id   <= 4'd8;        // 用药回血
                                sfx_trig <= 1'b1;
                            end else if (pot != 4'd0) begin
                                pot      <= pot - 4'd1;
                                hp       <= (hp + 10'd60 > maxhp) ? maxhp : (hp + 10'd60);
                                req_stb  <= 1'b1;
                                req_pri  <= PRI_L2;
                                req_addr <= `MSG_POTION;
                                bst      <= B_DELAY;
                                sfx_id   <= 4'd8;
                                sfx_trig <= 1'b1;
                            end else if (herb != 4'd0) begin
                                herb     <= herb - 4'd1;
                                hp       <= (hp + 10'd30 > maxhp) ? maxhp : (hp + 10'd30);
                                req_stb  <= 1'b1;
                                req_pri  <= PRI_L2;
                                req_addr <= `MSG_POTION;
                                bst      <= B_DELAY;
                                sfx_id   <= 4'd8;
                                sfx_trig <= 1'b1;
                            end else begin
                                req_stb  <= 1'b1;
                                req_pri  <= PRI_L2;
                                req_addr <= `MSG_NOPOT;
                                sfx_id   <= 4'd14;       // 没有药: 失败音
                                sfx_trig <= 1'b1;
                            end
                            redraw <= 1'b1;
                        end else if (key_e[3]) begin
                            if (rnd[3:0] < 4'd10) begin
                                req_stb  <= 1'b1;
                                req_pri  <= PRI_L2;
                                req_addr <= `MSG_FLEE;
                                scene    <= SC_MAP;
                                bst      <= B_IDLE;
                                sfx_id   <= 4'd15;       // 逃跑成功: 清脆短音
                                sfx_trig <= 1'b1;
                            end else begin
                                req_stb  <= 1'b1;
                                req_pri  <= PRI_L2;
                                req_addr <= `MSG_FAIL;
                                bst      <= B_DELAY;
                                sfx_id   <= 4'd14;       // 逃跑失败: 低音
                                sfx_trig <= 1'b1;
                            end
                            redraw <= 1'b1;
                        end
                    end

                    SC_SHOP: begin                       // 第 1 页：消耗品
                        if (key_e[0]) begin
                            if (gold >= 12'd15) begin
                                gold <= gold - 12'd15;
                                herb <= herb + 4'd1;
                                req_stb  <= 1'b1;
                                req_pri  <= PRI_L3;
                                req_addr <= `MSG_BUY;
                                sfx_id   <= 4'd9;        // 购买成功
                                sfx_trig <= 1'b1;
                            end else begin
                                req_stb  <= 1'b1;
                                req_pri  <= PRI_L3;
                                req_addr <= `MSG_NOGOLD;
                                sfx_id   <= 4'd10;       // 金币不足
                                sfx_trig <= 1'b1;
                            end
                            redraw <= 1'b1;
                        end else if (key_e[1]) begin
                            if (gold >= 12'd30) begin
                                gold <= gold - 12'd30;
                                pot  <= pot + 4'd1;
                                req_stb  <= 1'b1;
                                req_pri  <= PRI_L3;
                                req_addr <= `MSG_BUY;
                                sfx_id   <= 4'd9;
                                sfx_trig <= 1'b1;
                            end else begin
                                req_stb  <= 1'b1;
                                req_pri  <= PRI_L3;
                                req_addr <= `MSG_NOGOLD;
                                sfx_id   <= 4'd10;
                                sfx_trig <= 1'b1;
                            end
                            redraw <= 1'b1;
                        end else if (key_e[2]) begin
                            if (gold >= 12'd60) begin
                                gold  <= gold - 12'd60;
                                potxl <= potxl + 4'd1;
                                req_stb  <= 1'b1;
                                req_pri  <= PRI_L3;
                                req_addr <= `MSG_BUY;
                                sfx_id   <= 4'd9;
                                sfx_trig <= 1'b1;
                            end else begin
                                req_stb  <= 1'b1;
                                req_pri  <= PRI_L3;
                                req_addr <= `MSG_NOGOLD;
                                sfx_id   <= 4'd10;
                                sfx_trig <= 1'b1;
                            end
                            redraw <= 1'b1;
                        end else if (key_e[3]) begin
                            scene  <= SC_SHOP2;      // 翻到装备页
                            sfx_id   <= 4'd11;           // 翻页音
                            sfx_trig <= 1'b1;
                            redraw <= 1'b1;
                        end
                    end

                    SC_SHOP2: begin                      // 第 2 页：永久强化
                        if (key_e[0]) begin
                            if (gold >= 12'd120) begin
                                gold <= gold - 12'd120;
                                atk  <= atk + 8'd3;
                                req_stb  <= 1'b1;
                                req_pri  <= PRI_L3;
                                req_addr <= `MSG_UPGRADE;
                                sfx_id   <= 4'd9;        // 强化成功
                                sfx_trig <= 1'b1;
                            end else begin
                                req_stb  <= 1'b1;
                                req_pri  <= PRI_L3;
                                req_addr <= `MSG_NOGOLD;
                                sfx_id   <= 4'd10;
                                sfx_trig <= 1'b1;
                            end
                            redraw <= 1'b1;
                        end else if (key_e[1]) begin
                            if (gold >= 12'd120) begin
                                gold <= gold - 12'd120;
                                def  <= def + 8'd3;
                                req_stb  <= 1'b1;
                                req_pri  <= PRI_L3;
                                req_addr <= `MSG_UPGRADE;
                                sfx_id   <= 4'd9;
                                sfx_trig <= 1'b1;
                            end else begin
                                req_stb  <= 1'b1;
                                req_pri  <= PRI_L3;
                                req_addr <= `MSG_NOGOLD;
                                sfx_id   <= 4'd10;
                                sfx_trig <= 1'b1;
                            end
                            redraw <= 1'b1;
                        end else if (key_e[2]) begin
                            if (gold >= 12'd200) begin
                                gold <= gold - 12'd200;
                                atk  <= atk + 8'd3;
                                def  <= def + 8'd3;
                                req_stb  <= 1'b1;
                                req_pri  <= PRI_L3;
                                req_addr <= `MSG_UPGRADE;
                                sfx_id   <= 4'd9;
                                sfx_trig <= 1'b1;
                            end else begin
                                req_stb  <= 1'b1;
                                req_pri  <= PRI_L3;
                                req_addr <= `MSG_NOGOLD;
                                sfx_id   <= 4'd10;
                                sfx_trig <= 1'b1;
                            end
                            redraw <= 1'b1;
                        end else if (key_e[3]) begin
                            scene  <= SC_MAP;
                            sfx_id   <= 4'd11;           // 返回: 翻页音
                            sfx_trig <= 1'b1;
                            redraw <= 1'b1;
                        end
                    end

                    SC_DEAD: begin
                        if (key_e[0]) begin
                            hp     <= maxhp >> 1;
                            mp     <= maxmp >> 1;
                            gold   <= gold - gold_lost[11:0];
                            kills  <= 4'd0;
                            scene  <= SC_MAP;
                            sfx_id   <= 4'd8;            // 复活: 回血音
                            sfx_trig <= 1'b1;
                            redraw <= 1'b1;
                        end
                    end

                    SC_PIC: begin
                        if (key_e[3]) begin              // 4: 返回标题
                            scene     <= SC_TITLE;
                            pic_pause <= 1'b0;
                            pic_tmr   <= 23'd0;
                            redraw    <= 1'b1;
                        end else if (key_e[2]) begin     // 3: 暂停/继续
                            pic_pause <= ~pic_pause;
                        end else if (key_e[0]) begin     // 1: 上一帧(并暂停)
                            anim_frame <= anim_frame - 3'd1;
                            pic_pause  <= 1'b1;
                            sfx_id   <= 4'd11;           // 翻帧音
                            sfx_trig <= 1'b1;
                        end else if (key_e[1]) begin     // 2: 下一帧(并暂停)
                            anim_frame <= anim_frame + 3'd1;
                            pic_pause  <= 1'b1;
                            sfx_id   <= 4'd11;
                            sfx_trig <= 1'b1;
                        end else if (!pic_pause) begin   // 自动播放: 8 帧/秒
                            if (pic_tmr >= PIC_PERIOD) begin
                                pic_tmr    <= 23'd0;
                                anim_frame <= anim_frame + 3'd1;
                            end else begin
                                pic_tmr <= pic_tmr + 23'd1;
                            end
                        end else begin
                            pic_tmr <= 23'd0;            // 暂停时清计时
                        end
                    end

                    SC_WIN: begin
                        if (key_e[0]) begin
                            scene  <= SC_TITLE;
                            redraw <= 1'b1;
                        end
                    end

                    default: ;
                    endcase
                end
            end

            // 整屏每跳出一个字响一声。音高按这句话区分，不跟按键抢同一拍。
            if (type_ping && key_e == 4'd0) begin
                sfx_trig <= 1'b1;
                sfx_id   <= prompt_tone(splash_pri, splash_addr);
            end
        end
    end

    function [3:0] prompt_tone;
        input [1:0]  pri;
        input [10:0] addr;
        begin
            if (addr == `MSG_ALERT)        prompt_tone = 4'd2;
            else if (addr == `MSG_DYING)   prompt_tone = 4'd5;
            else if (addr == `MSG_BOSS)    prompt_tone = 4'd12;
            else if (addr == `MSG_MEET)    prompt_tone = 4'd14;
            else if (addr == `MSG_KILL)    prompt_tone = 4'd3;
            else if (addr == `MSG_LEVEL)   prompt_tone = 4'd4;
            else if (addr == `MSG_FLEE)    prompt_tone = 4'd15;
            else if (addr == `MSG_FAIL)    prompt_tone = 4'd14;
            else if (addr == `MSG_NOGOLD)  prompt_tone = 4'd10;
            else if (addr == `MSG_BUY)     prompt_tone = 4'd9;
            else if (addr == `MSG_UPGRADE) prompt_tone = 4'd4;
            else if (addr == `MSG_HINT)    prompt_tone = 4'd11;
            else if (addr == `MSG_HINT2)   prompt_tone = 4'd10;
            else if (addr == `MSG_AD)      prompt_tone = 4'd7;
            else if (pri == PRI_L1)        prompt_tone = 4'd12;
            else if (pri == PRI_L2)        prompt_tone = 4'd10;
            else                           prompt_tone = 4'd9;
        end
    endfunction

    //=========================================================
    // 消息优先级
    //   1 级抢占主字幕，把正在看的 3 级公告放进队列，超时后再弹回来
    //   2 级战斗字写在主行；地图上写在下一行，不盖住区域句子
    //   3 级商店公告。主行空着就直接显示，并一直留到被更高优先级打断或离开界面
    //=========================================================
    reg        banner_v_n, side_v_n, queue_v_n, alert_n;
    reg        boss_arm_n, boss_latched_n, map_l1_n, cover_arm_n;
    reg [1:0]  banner_pri_n;
    reg [10:0] banner_addr_n, side_addr_n, queue_addr_n;
    reg [26:0] banner_tmr_n, side_tmr_n, boss_tmr_n, cover_tmr_n;
    wire       area_changed  = (area != area_d);
    wire       shop_now = (scene == SC_SHOP) || (scene == SC_SHOP2);

    always @(*) begin
        banner_v_n     = banner_v;
        banner_pri_n   = banner_pri;
        banner_addr_n  = banner_addr;
        banner_tmr_n   = banner_tmr;
        side_v_n       = side_v;
        side_addr_n    = side_addr;
        side_tmr_n     = side_tmr;
        queue_v_n      = queue_v;
        queue_addr_n   = queue_addr;
        boss_arm_n     = boss_arm;
        boss_tmr_n     = boss_tmr;
        boss_latched_n = boss_latched;
        cover_arm_n    = cover_arm;
        cover_tmr_n    = cover_tmr;
        map_l1_n       = map_l1_done;
        alert_n        = alert_pending;
        splash_req     = 1'b0;
        splash_req_pri = 2'd0;
        splash_req_addr = 11'd0;

        if (alert_pending && !rendering)
            alert_n = 1'b0;
        if (!hp_low)
            map_l1_n = 1'b0;
        if (boss_dead || area_changed)
            boss_latched_n = 1'b0;

        if (scene_changed) begin
            banner_v_n    = 1'b0;
            banner_pri_n  = 2'd0;
            banner_tmr_n  = 27'd0;
            side_v_n      = 1'b0;
            side_tmr_n    = 27'd0;
            queue_v_n     = 1'b0;
            boss_arm_n    = 1'b0;
            boss_tmr_n    = 27'd0;
            cover_arm_n   = 1'b0;
            cover_tmr_n   = 27'd0;
        end

        if (banner_v_n && (banner_pri_n == PRI_L1 || banner_pri_n == PRI_L2)) begin
            if (banner_tmr_n != 27'd0)
                banner_tmr_n = banner_tmr_n - 27'd1;
            else begin
                alert_n = 1'b1;
                if (queue_v_n) begin
                    banner_v_n    = 1'b1;
                    banner_pri_n  = PRI_L3;
                    banner_addr_n = queue_addr_n;
                    banner_tmr_n  = 27'd0;
                    queue_v_n     = 1'b0;
                end else begin
                    banner_v_n   = 1'b0;
                    banner_pri_n = 2'd0;
                end
            end
        end

        if (side_v_n) begin
            if (side_tmr_n != 27'd0)
                side_tmr_n = side_tmr_n - 27'd1;
            else begin
                side_v_n = 1'b0;
                alert_n  = 1'b1;
            end
        end

        if (boss_arm_n) begin
            if (boss_tmr_n != 27'd0)
                boss_tmr_n = boss_tmr_n - 27'd1;
            else begin
                boss_arm_n     = 1'b0;
                boss_latched_n = 1'b1;
                if (banner_v_n && banner_pri_n == PRI_L3) begin
                    queue_v_n    = 1'b1;
                    queue_addr_n = banner_addr_n;
                end
                banner_v_n    = 1'b1;
                banner_pri_n  = PRI_L1;
                banner_addr_n = `MSG_BOSS;
                banner_tmr_n  = T_L1;
                alert_n       = 1'b1;
            end
        end

        if (scene == SC_MAP && (scene_changed || area_changed)) begin
            if (danger_addr != 11'd0) begin
                side_v_n    = 1'b1;
                side_addr_n = danger_addr;
                side_tmr_n  = T_L2;
            end else begin
                side_v_n   = 1'b0;
                side_tmr_n = 27'd0;
            end
            if (!scene_changed)
                alert_n = 1'b1;
        end

        if (req_stb) begin
            if (req_pri == PRI_L1) begin
                if (banner_v_n && banner_pri_n == PRI_L3) begin
                    queue_v_n    = 1'b1;
                    queue_addr_n = banner_addr_n;
                end
                banner_v_n    = 1'b1;
                banner_pri_n  = PRI_L1;
                banner_addr_n = req_addr;
                banner_tmr_n  = T_L1;
            end else if (req_pri == PRI_L2) begin
                if (scene == SC_BATTLE) begin
                    if (!(banner_v_n && banner_pri_n == PRI_L1)) begin
                        banner_v_n    = 1'b1;
                        banner_pri_n  = PRI_L2;
                        banner_addr_n = req_addr;
                        banner_tmr_n  = T_L2;
                    end
                end else begin
                    side_v_n    = 1'b1;
                    side_addr_n = req_addr;
                    side_tmr_n  = T_L2;
                end
            end else if (req_pri == PRI_L3) begin
                if (banner_v_n && banner_pri_n == PRI_L1) begin
                    queue_v_n    = 1'b1;
                    queue_addr_n = req_addr;
                end else begin
                    banner_v_n    = 1'b1;
                    banner_pri_n  = PRI_L3;
                    banner_addr_n = req_addr;
                    banner_tmr_n  = 27'd0;
                end
                if (shop_now && boss_ready && !boss_latched_n && !boss_arm_n) begin
                    boss_arm_n = 1'b1;
                    boss_tmr_n = T_BOSS;
                end
            end
        end

        if (scene == SC_MAP && scene_changed && hp_low && !map_l1_n) begin
            if (banner_v_n && banner_pri_n == PRI_L3) begin
                queue_v_n    = 1'b1;
                queue_addr_n = banner_addr_n;
            end
            banner_v_n    = 1'b1;
            banner_pri_n  = PRI_L1;
            banner_addr_n = `MSG_DYING;
            banner_tmr_n  = T_L1;
            map_l1_n      = 1'b1;
        end

        if (scene == SC_MAP && ctx_var != ctx_var_d)
            alert_n = 1'b1;

        if (hp_low && !hp_low_d) begin
            if (banner_v_n && banner_pri_n == PRI_L3) begin
                queue_v_n    = 1'b1;
                queue_addr_n = banner_addr_n;
            end
            banner_v_n    = 1'b1;
            banner_pri_n  = PRI_L1;
            banner_addr_n = `MSG_DYING;
            banner_tmr_n  = T_L1;
            map_l1_n      = 1'b1;
            alert_n       = 1'b1;
        end

        // 回血只撤掉低血量警告。BOSS 警告和紧急通告不在这里清掉。
        if (!hp_low && banner_v_n && banner_pri_n == PRI_L1 &&
            banner_addr_n == `MSG_DYING) begin
            banner_tmr_n = 27'd0;
            alert_n = 1'b1;
            if (queue_v_n) begin
                banner_v_n = 1'b1;
                banner_pri_n = PRI_L3;
                banner_addr_n = queue_addr_n;
                queue_v_n = 1'b0;
            end else begin
                banner_v_n = 1'b0;
                banner_pri_n = 2'd0;
            end
        end

        // 没打满四只时，进商店先亮 3 级黄字，约一秒后 1 级红字盖住，结束后黄字回来。
        // 已经能打强敌时不走这条，留给购买后的强敌提示。
        if (scene_changed && scene == SC_SHOP && !boss_ready) begin
            banner_v_n    = 1'b1;
            banner_pri_n  = PRI_L3;
            banner_addr_n = `MSG_HINT;
            banner_tmr_n  = 27'd0;
            cover_arm_n   = 1'b1;
            cover_tmr_n   = T_COVER;
            alert_n       = 1'b1;
        end

        if (cover_arm_n) begin
            if (banner_v_n && banner_pri_n == PRI_L1)
                cover_arm_n = 1'b0;
            else if (cover_tmr_n != 27'd0)
                cover_tmr_n = cover_tmr_n - 27'd1;
            else begin
                cover_arm_n = 1'b0;
                if (banner_v_n && banner_pri_n == PRI_L3) begin
                    queue_v_n    = 1'b1;
                    queue_addr_n = banner_addr_n;
                end else if (!queue_v_n) begin
                    queue_v_n    = 1'b1;
                    queue_addr_n = `MSG_HINT;
                end
                banner_v_n    = 1'b1;
                banner_pri_n  = PRI_L1;
                banner_addr_n = `MSG_ALERT;
                banner_tmr_n  = T_L1;
                alert_n       = 1'b1;
            end
        end

        // 演示键最后生效。地图上的区域句本身就是被抢走的字幕，超时后自己回来。
        // 商店没有 3 级公告时，塞进一条短广告，超时后由同一行弹回。
        if (emergency) begin
            cover_arm_n = 1'b0;
            if (banner_v_n && banner_pri_n == PRI_L3) begin
                queue_v_n    = 1'b1;
                queue_addr_n = banner_addr_n;
            end else if (shop_now && !queue_v_n) begin
                queue_v_n    = 1'b1;
                queue_addr_n = `MSG_AD;
            end
            banner_v_n    = 1'b1;
            banner_pri_n  = PRI_L1;
            banner_addr_n = `MSG_ALERT;
            banner_tmr_n  = T_L1;
            alert_n       = 1'b1;
        end

        // 整句跳完后，1 级主字幕再留一小会儿。地图侧栏按原倒计时留着。
        if (type_done && splash_v && banner_v_n && banner_pri_n == PRI_L1 &&
            banner_tmr_n > T_AFTER)
            banner_tmr_n = T_AFTER;

        // 攻击、技能、喝药、反击是战斗流水账，直接一行，不再盖住画面。
        // 主字幕优先整屏。地图上的 2 级在没有 1 级时单独整屏。
        if (banner_v_n && !chatter && (banner_addr_n != banner_addr ||
                           banner_pri_n != banner_pri || !banner_v)) begin
            splash_req      = 1'b1;
            splash_req_pri  = banner_pri_n;
            splash_req_addr = banner_addr_n;
        end else if (side_v_n && (side_addr_n != side_addr || !side_v) &&
                     !(banner_v_n && banner_pri_n == PRI_L1)) begin
            splash_req      = 1'b1;
            splash_req_pri  = PRI_L2;
            splash_req_addr = side_addr_n;
        end
        if (splash_req || (splash_v && (splash_tmr == 27'd0 || !splash_alive)))
            alert_n = 1'b1;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            banner_v      <= 1'b0;
            banner_pri    <= 2'd0;
            banner_addr   <= `MSG_NONE;
            banner_tmr    <= 27'd0;
            side_v        <= 1'b0;
            side_addr     <= `MSG_FAR;
            side_tmr      <= 27'd0;
            queue_v       <= 1'b0;
            queue_addr    <= `MSG_NONE;
            boss_arm      <= 1'b0;
            boss_tmr      <= 27'd0;
            boss_latched  <= 1'b0;
            cover_arm     <= 1'b0;
            cover_tmr     <= 27'd0;
            map_l1_done   <= 1'b0;
            alert_pending <= 1'b0;
            scene_d       <= SC_TITLE;
            area_d        <= 3'd0;
            hp_low_d      <= 1'b0;
            ctx_var_d     <= 2'd0;
            splash_v      <= 1'b0;
            splash_pri    <= 2'd0;
            splash_addr   <= `MSG_NONE;
            splash_tmr    <= 27'd0;
        end else begin
            banner_v      <= banner_v_n;
            banner_pri    <= banner_pri_n;
            banner_addr   <= banner_addr_n;
            banner_tmr    <= banner_tmr_n;
            side_v        <= side_v_n;
            side_addr     <= side_addr_n;
            side_tmr      <= side_tmr_n;
            queue_v       <= queue_v_n;
            queue_addr    <= queue_addr_n;
            boss_arm      <= boss_arm_n;
            boss_tmr      <= boss_tmr_n;
            boss_latched  <= boss_latched_n;
            cover_arm     <= cover_arm_n;
            cover_tmr     <= cover_tmr_n;
            map_l1_done   <= map_l1_n;
            alert_pending <= alert_n;
            scene_d       <= scene;
            area_d        <= area;
            hp_low_d      <= hp_low;
            ctx_var_d     <= ctx_var;
            if (splash_req) begin
                splash_v    <= 1'b1;
                splash_pri  <= splash_req_pri;
                splash_addr <= splash_req_addr;
                splash_tmr  <= 27'd1;          // 逐字期间不倒计时
            end else if (scene_changed || !splash_alive) begin
                splash_v <= 1'b0;
            end else if (splash_v && type_done) begin
                if (splash_tmr != 27'd0)
                    splash_tmr <= splash_tmr - 27'd1;
                else
                    splash_v <= 1'b0;
            end
        end
    end

endmodule
