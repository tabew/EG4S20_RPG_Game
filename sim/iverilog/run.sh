#!/bin/sh
set -e
cd "$(dirname "$0")/../.."
echo "=== 编译 ==="
iverilog -g2012 -DSIM_FAST -o sim.out -I rtl/gen \
  rtl/gen/rpg_defs.vh \
  rtl/video/vid_timing.v rtl/video/mon_layer.v rtl/video/rpg_video.v \
  rtl/gen/ui_rom.v rtl/gen/rpg_msgs.v rtl/gen/anim_rom.v \
  rtl/ctrl/rpg_core.v sim/iverilog/tb_play.v
echo "=== 仿真 ==="
rm -f sim/iverilog/frames.rgb
vvp sim.out
echo "=== 转成 PNG ==="
python3 tools/rgb2png.py
