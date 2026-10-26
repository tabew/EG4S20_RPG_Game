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
    output wire [3:0]  mon_fade
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
`ifdef SIM_FAST
    localparam [21:0] PIC_PERIOD = 22'd2_000_000;  // 仿真: 约 5 帧换一次, 一屏内不混帧
`else
    localparam [21:0] PIC_PERIOD = 22'd3_125_000;  // 25MHz / 8 = 8 帧每秒
`endif
    reg [21:0] pic_tmr;
    reg        pic_pause;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pic_tmr    <= 22'd0;
            pic_pause  <= 1'b0;
            anim_frame <= 3'd0;
        end else if (scene == SC_PIC && !pic_pause) begin
            if (pic_tmr >= PIC_PERIOD) begin
                pic_tmr    <= 22'd0;
                anim_frame <= anim_frame + 3'd1;
            end else begin
                pic_tmr <= pic_tmr + 22'd1;
            end
        end else begin
            pic_tmr <= 22'd0;
        end
    end

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
    reg        fade_dir;        // 1=淡入 0=淡出

    assign mon_on   = (scene == SC_BATTLE);
    assign mon_id   = enemy_id;
    assign mon_fade = mon_fade_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mon_fade_r <= 4'd0;
            fade_tmr   <= 22'd0;
            fade_dir   <= 1'b1;
        end else if (scene != SC_BATTLE) begin
            mon_fade_r <= 4'd0;
            fade_tmr   <= 22'd0;
            fade_dir   <= 1'b1;          // 下一场从头淡入
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
    reg [11:0] msg_addr;
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
    reg  [9:0]  cmd_a;
    wire [31:0] cmd_d;
    reg  [10:0] str_a;
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

    //---------------------------------------------------------
    // 解释器
    //---------------------------------------------------------
    localparam [4:0] R_IDLE = 5'd0, R_FETCH = 5'd1, R_DEC = 5'd2,
                     R_CLR  = 5'd3, R_TXT_A = 5'd4, R_TXT_B = 5'd5, R_TXT_C = 5'd6,
                     R_NUM  = 5'd7, R_BAR  = 5'd8,
                     R_ART_A = 5'd9, R_ART_B = 5'd10, R_ART_C = 5'd11,
                     R_NAME = 5'd12, R_FRM = 5'd13,
                     // 同步 ROM 的输出要 2 拍才有效, 取址后必须空等 1 拍
                     R_FETCH_W = 5'd14, R_TXT_W = 5'd15, R_ART_W = 5'd16;

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
    reg [5:0]  art_id;
    reg [5:0]  frm_x, frm_y, frm_i;
    reg [5:0]  frm_w;
    reg [4:0]  frm_h, frm_j;
    reg [8:0]  ch;

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
            cmd_a     <= 10'd0;
            str_a     <= 11'd0;
            art_a     <= 12'd0;
        end else begin
            we <= 1'b0;

            case (rstt)

            R_IDLE: begin
                rendering <= 1'b0;
                if (redraw) begin
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
                4'd9: begin                       // MSG
                    sptr <= msg_addr[10:0];
                    tx   <= cx;
                    ty   <= cy;
                    rstt <= R_TXT_A;
                end
                4'd11: begin                      // ADESC: 按当前区域取环境描述
                    sptr <= tab_adesc[area*11 +: 11];
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
                if (str_d == 16'hFFFF || sptr >= 11'd2040) begin
                    pc   <= pc + 10'd1;
                    rstt <= R_FETCH;
                end else begin
                    if (tx < 6'd40) begin
                        we    <= 1'b1;
                        waddr <= cell_a;
                        wdata <= {bg, fg, ch};
                    end
                    if (tx == 6'd39) begin tx <= 6'd0; ty <= ty + 6'd1; end
                    else             tx <= tx + 6'd1;
                    sptr <= sptr + 11'd1;
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

            default: rstt <= R_IDLE;
            endcase
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
            msg_addr  <= `MSG_NONE;
            bst       <= B_IDLE;
            dly       <= 22'd0;
            redraw    <= 1'b1;
            start_battle <= 1'b0;
        end else begin
            redraw <= 1'b0;

            //---------------- 开战: 装载敌人 ----------------
            if (start_battle) begin
                start_battle <= 1'b0;
                scene        <= SC_BATTLE;
                bst          <= B_IDLE;
                dly          <= 22'd0;
                ehp          <= tab_es[9:0];
                emaxhp       <= tab_es[9:0];
                eatk         <= tab_es[17:10];
                edef         <= tab_es[25:18];
                eexp         <= tab_es[35:26];
                egold        <= tab_es[47:36];
                e_spr        <= tab_es[52:48];
                e_boss       <= tab_es[53];
                msg_addr     <= `MSG_HIT;
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
                            msg_addr <= `MSG_ENEMY;
                        end
                        bst    <= B_CHECK;
                        redraw <= 1'b1;
                    end

                    B_CHECK: begin
                        if (ehp == 10'd0) begin
                            fade_dir <= 1'b0;            // 立绘淡出
                            gold     <= gold + egold;
                            exp      <= exp + eexp;
                            kills    <= (kills < 4'd15) ? (kills + 4'd1) : kills;
                            if (e_boss) boss_dead <= 1'b1;
                            msg_addr <= `MSG_KILL;
                            bst      <= B_LVUP;
                        end else if (hp == 10'd0) begin
                            scene <= SC_DEAD;
                            bst   <= B_IDLE;
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
                            msg_addr <= `MSG_LEVEL;
                            redraw   <= 1'b1;
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
                            end
                            redraw <= 1'b1;
                        end else if (key_e[3]) begin
                            if (boss_dead) begin
                                if (area == 3'd4) begin
                                    scene <= SC_WIN;
                                end else begin
                                    area      <= area + 3'd1;
                                    kills     <= 4'd0;
                                    boss_dead <= 1'b0;
                                end
                            end else if (kills >= 4'd4) begin
                                enemy_id     <= ar_boss;
                                start_battle <= 1'b1;
                            end
                            redraw <= 1'b1;
                        end
                    end

                    SC_BATTLE: begin
                        if (key_e[0]) begin
                            last_dmg <= p_dmg;
                            ehp      <= (ehp > p_dmg) ? (ehp - p_dmg) : 10'd0;
                            msg_addr <= `MSG_HIT;
                            bst      <= B_DELAY;
                            redraw   <= 1'b1;
                        end else if (key_e[1]) begin
                            if ({2'b00, mp} >= {2'b00, sk_cost}) begin
                                mp       <= mp - {2'b00, sk_cost};
                                last_dmg <= sk_dmg;
                                ehp      <= (ehp > sk_dmg) ? (ehp - sk_dmg) : 10'd0;
                                msg_addr <= `MSG_SKILL;
                                bst      <= B_DELAY;
                            end else begin
                                msg_addr <= `MSG_NOMANA;
                            end
                            redraw <= 1'b1;
                        end else if (key_e[2]) begin
                            if (potxl != 4'd0) begin
                                potxl    <= potxl - 4'd1;
                                hp       <= (hp + 10'd130 > maxhp) ? maxhp : (hp + 10'd130);
                                msg_addr <= `MSG_POTION;
                                bst      <= B_DELAY;
                            end else if (pot != 4'd0) begin
                                pot      <= pot - 4'd1;
                                hp       <= (hp + 10'd60 > maxhp) ? maxhp : (hp + 10'd60);
                                msg_addr <= `MSG_POTION;
                                bst      <= B_DELAY;
                            end else if (herb != 4'd0) begin
                                herb     <= herb - 4'd1;
                                hp       <= (hp + 10'd30 > maxhp) ? maxhp : (hp + 10'd30);
                                msg_addr <= `MSG_POTION;
                                bst      <= B_DELAY;
                            end else begin
                                msg_addr <= `MSG_NOPOT;
                            end
                            redraw <= 1'b1;
                        end else if (key_e[3]) begin
                            if (rnd[3:0] < 4'd10) begin
                                msg_addr <= `MSG_FLEE;
                                scene    <= SC_MAP;
                                bst      <= B_IDLE;
                            end else begin
                                msg_addr <= `MSG_FAIL;
                                bst      <= B_DELAY;
                            end
                            redraw <= 1'b1;
                        end
                    end

                    SC_SHOP: begin                       // 第 1 页：消耗品
                        if (key_e[0]) begin
                            if (gold >= 12'd15) begin
                                gold <= gold - 12'd15;
                                herb <= herb + 4'd1;
                                msg_addr <= `MSG_BUY;
                            end
                            redraw <= 1'b1;
                        end else if (key_e[1]) begin
                            if (gold >= 12'd30) begin
                                gold <= gold - 12'd30;
                                pot  <= pot + 4'd1;
                                msg_addr <= `MSG_BUY;
                            end
                            redraw <= 1'b1;
                        end else if (key_e[2]) begin
                            if (gold >= 12'd60) begin
                                gold  <= gold - 12'd60;
                                potxl <= potxl + 4'd1;
                                msg_addr <= `MSG_BUY;
                            end
                            redraw <= 1'b1;
                        end else if (key_e[3]) begin
                            scene  <= SC_SHOP2;      // 翻到装备页
                            redraw <= 1'b1;
                        end
                    end

                    SC_SHOP2: begin                      // 第 2 页：永久强化
                        if (key_e[0]) begin
                            if (gold >= 12'd120) begin
                                gold <= gold - 12'd120;
                                atk  <= atk + 8'd3;
                                msg_addr <= `MSG_UPGRADE;
                            end
                            redraw <= 1'b1;
                        end else if (key_e[1]) begin
                            if (gold >= 12'd120) begin
                                gold <= gold - 12'd120;
                                def  <= def + 8'd3;
                                msg_addr <= `MSG_UPGRADE;
                            end
                            redraw <= 1'b1;
                        end else if (key_e[2]) begin
                            if (gold >= 12'd200) begin
                                gold <= gold - 12'd200;
                                atk  <= atk + 8'd3;
                                def  <= def + 8'd3;
                                msg_addr <= `MSG_UPGRADE;
                            end
                            redraw <= 1'b1;
                        end else if (key_e[3]) begin
                            scene  <= SC_MAP;
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
                            redraw <= 1'b1;
                        end
                    end

                    SC_PIC: begin
                        if (key_e[3]) begin              // 4: 返回标题
                            scene     <= SC_TITLE;
                            pic_pause <= 1'b0;
                            redraw    <= 1'b1;
                        end else if (key_e[2]) begin     // 3: 暂停/继续
                            pic_pause <= ~pic_pause;
                        end else if (key_e[0]) begin     // 1: 上一帧(并暂停)
                            anim_frame <= anim_frame - 3'd1;
                            pic_pause  <= 1'b1;
                        end else if (key_e[1]) begin     // 2: 下一帧(并暂停)
                            anim_frame <= anim_frame + 3'd1;
                            pic_pause  <= 1'b1;
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
        end
    end

endmodule
