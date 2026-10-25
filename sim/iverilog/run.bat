@echo off
chcp 65001 >nul
cd /d "%~dp0..\.."
echo === 编译 ===
iverilog -g2012 -DSIM_FAST -o sim.out -I rtl/gen ^
  rtl/gen/rpg_defs.vh ^
  rtl/video/vid_timing.v rtl/video/rpg_video.v ^
  rtl/gen/ui_rom.v rtl/gen/rpg_msgs.v rtl/gen/anim_rom.v ^
  rtl/ctrl/rpg_core.v sim/iverilog/tb_play.v
if errorlevel 1 goto :err
echo === 仿真 ===
if exist sim\iverilog\frames.rgb del sim\iverilog\frames.rgb
vvp sim.out
echo === 转成 PNG ===
python tools\rgb2png.py 2>nul || py -3 tools\rgb2png.py
goto :eof
:err
echo 编译失败, 请检查是否已安装 Icarus Verilog 并把它加入 PATH
