#=============================================================================
# timing.sdc —— 时序约束（安路 TD 支持 SDC 语法）
#
# 本工程只有两个时钟：
#   clk_pix = 25.175MHz  全部逻辑都在这个域里
#   clk_p5x = 125.875MHz 只给 TMDS 串行化用
# 二者同源（都来自 PLL），TD 一般能自动推导派生时钟；
# 若综合报告里看不到 clk_pix / clk_p5x，就把下面注释的两行打开并核对 PLL 引脚名。
#=============================================================================

create_clock -name clk50 -period 20.000 -waveform {0 10.000} [get_ports {clk50}]

# ---- PLL 派生时钟（工具未自动识别时手动加，注意引脚名要按实际 PLL 实例改）----
# create_generated_clock -name clk_pix -source [get_ports {clk50}] \
#     -divide_by 320 -multiply_by 161 -master_clock clk50 [get_pins {u_clk/u_pll|clk_out1}]
# create_generated_clock -name clk_p5x -source [get_ports {clk50}] \
#     -divide_by 64  -multiply_by 161 -master_clock clk50 [get_pins {u_clk/u_pll|clk_out2}]

# ---- 串行化域与像素域之间没有逻辑路径 ----
set_false_path -from [get_clocks clk_pix] -to [get_clocks clk_p5x]
set_false_path -from [get_clocks clk_p5x] -to [get_clocks clk_pix]

# ---- 按键是异步输入，已经过两级同步 + 消抖 ----
set_false_path -from [get_ports {key_n[*]}]
set_false_path -from [get_ports {rst_key_n}]
