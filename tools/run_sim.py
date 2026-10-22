# -*- coding: utf-8 -*-
"""
run_sim.py —— 一键跑仿真: 生成 ROM -> yosys sim -> VCD 重建屏幕 -> 与参考渲染器比对

    python tools/run_sim.py            # 只验格子(几秒)
    python tools/run_sim.py --video    # 加上整帧像素验证(约 5 分钟)

顺序很重要:
  1. build_rom.py 先生成 rtl/gen/*.hex(界面/字库变了必须先跑)
  2. yosys 读这些 hex 跑仿真(改了 RTL 也要重跑)
  3. 比对仿真结果和 Python 参考渲染器

少跑任何一步都可能得出"假一致"的结论(比如 VCD 是旧 ROM 跑出来的)。
"""
import os, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
PY = sys.executable

# yosys 的位置: 优先环境变量, 否则用本机装好的 yowasp-yosys
YOSYS = os.environ.get("YOSYS",
    r"C:\Users\Tab_E\.workbuddy\binaries\python\versions\3.13.12\Scripts\yowasp-yosys.exe")


def run(title, cmd):
    print("\n" + "=" * 68)
    print(title)
    print("=" * 68)
    r = subprocess.run(cmd, cwd=ROOT)
    return r.returncode == 0


def main():
    ok = True

    ok &= run("第 1 步: 生成字库 / 指令表 / 精灵表",
              [PY, os.path.join(HERE, "build_rom.py")])

    ok &= run("第 2 步: yosys 仿真(12000 周期, 导出 VCD)",
              [YOSYS, "-s", "sim/run_core.ys"])

    ok &= run("第 3 步: 从 VCD 重建三个界面",
              [PY, os.path.join(HERE, "vcd_screen.py"), "sim/core.vcd"])

    ok &= run("第 4 步: 与 Python 参考渲染器逐格比对",
              [PY, os.path.join(HERE, "check_sim.py")])

    # 可选: 跑完整视频通路(42.5 万周期, 4~5 分钟), 还原真实像素
    if "--video" in sys.argv:
        ok &= run("第 5 步: 跑完整视频通路(约 4~5 分钟)",
                  [YOSYS, "-s", "sim/run_video.ys"])
        ok &= run("第 6 步: 从 VCD 还原 640x480 画面",
                  [PY, os.path.join(HERE, "vcd_frame.py")])
        ok &= run("第 7 步: 与参考渲染器逐像素比对",
                  [PY, os.path.join(HERE, "frame_diff.py")])

    print("\n" + "=" * 68)
    print("总体:", "通过 ✓" if ok else "有失败 ✗")
    print("=" * 68)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
