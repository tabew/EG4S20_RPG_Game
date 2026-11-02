"""Verify full640x480 RGB888 double buffering with real SDRAM controller.

Runs the actual service, actual media_sdram_ctrl, and command/timing/storage
SDRAM model at50MHz/40MHz; compares every requested pixel through full frames.
Also checks the public Gray-pointer FIFO independently with asynchronous stalls.
This verifies functional timing/bandwidth, not physical FPGA timing signoff.
"""
from pathlib import Path
import argparse
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SIM = ROOT / "sim/sdram"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--staged", action="store_true", help="use staged service and controller")
    parser.add_argument("--fifo-only", action="store_true")
    parser.add_argument("--timeout", type=int, default=900)
    args = parser.parse_args()
    common = ROOT / "rtl/common/key_debounce.v"
    contents = common.read_text(encoding="utf-8")
    sources = []
    if not args.staged and "module media_framebuffer (" in contents and "module media_sdram_ctrl" in contents:
        sources.append(common)
    else:
        sources.extend([SIM / "media_framebuffer.stage.v.txt", SIM / "media_sdram_ctrl.stage.v.txt"])
    local = ROOT / "tools/iverilog/bin"
    iverilog = str(local / "iverilog.exe") if (local / "iverilog.exe").exists() else shutil.which("iverilog")
    vvp = str(local / "vvp.exe") if (local / "vvp.exe").exists() else shutil.which("vvp")
    if not iverilog or not vvp:
        raise SystemExit("Icarus Verilog required in tools/iverilog/bin or PATH")
    tests = ["tb_framebuffer_fifo"]
    if not args.fifo_only:
        tests.append("tb_framebuffer")
    with tempfile.TemporaryDirectory(prefix="media_framebuffer_") as temporary:
        for test in tests:
            binary = Path(temporary) / (test + ".vvp")
            bench = SIM / (test + ".v")
            if test == "tb_framebuffer" and not args.staged:
                original = bench.read_text(encoding="utf-8")
                declarations = "wire cache_mode,swap_only;wire [1:0] swap_bank,s_front_bank,view_mode,view_active;\n"
                instance = "media_framebuffer dut(.*);"
                assert original.count(instance) == 1
                original = original.replace(instance, declarations + "media_framebuffer dut(.write_bank(2'bzz),.*);")
                bench = Path(temporary) / "tb_framebuffer_ports.v"
                bench.write_text(original, encoding="utf-8")
            subprocess.run([iverilog, "-g2012", "-Wall", "-s", test, "-o", str(binary),
                            *map(str, sources), str(SIM / "eg_sdram_model.v"),
                            str(bench)], cwd=ROOT, check=True)
            subprocess.run([vvp, str(binary)], cwd=ROOT, check=True, timeout=args.timeout)
    print("PASS framebuffer FIFO" if args.fifo_only else "PASS framebuffer complete-frame integration and asynchronous FIFO")


if __name__ == "__main__":
    main()
