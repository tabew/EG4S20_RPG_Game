"""Four-bank actual-controller scanout checks, plus unconnected-port legacy mode.

Uses the independent EM638325 CAS pipeline/timing/storage model. Does not modify
RTL, existing benches, PHY, FIFO or controller. Legacy wildcard bench instances
need local declarations for newly added ports; leave cache_mode undriven (Z) to
exercise the documented backward-compatible sanitization.
"""
from pathlib import Path
import argparse
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
SIM = ROOT / "sim/sdram"
OUT = SIM / "audit/cache_results"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--case", action="append", choices=("control", "latency", "cache_cea", "cache40", "legacy40"))
    args = parser.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    local = ROOT / "tools/iverilog/bin"
    iv = str(local / "iverilog.exe") if (local / "iverilog.exe").exists() else shutil.which("iverilog")
    vvp = str(local / "vvp.exe") if (local / "vvp.exe").exists() else shutil.which("vvp")
    if not iv or not vvp:
        raise SystemExit("Icarus Verilog is required")
    for case in args.case or ("control", "latency", "cache_cea", "cache40", "legacy40"):
        bench = SIM / "tb_framebuffer_cache.v"
        top = "tb_framebuffer_cache"
        flags = []
        if case == "control":
            bench = SIM / "tb_framebuffer_cache_control.v"
            top = "tb_framebuffer_cache_control"
        elif case == "latency":
            bench = SIM / "tb_framebuffer_cache_latency.v"
            top = "tb_framebuffer_cache_latency"
        elif case == "cache40":
            flags = ["-Ptb_framebuffer_cache.PIXEL_HALF_NS=12.5", "-Ptb_framebuffer_cache.LEGACY_RASTER=1"]
        elif case == "legacy40":
            top = "tb_framebuffer"
            original = (SIM / "tb_framebuffer.v").read_text(encoding="utf-8")
            declarations = "wire cache_mode,swap_only;wire [1:0] swap_bank,s_front_bank;\n"
            # The old bench already has an integer `write_bank` scoreboard;
            # explicitly leave the new input open instead of binding that name.
            instance = "media_framebuffer dut(.*);"
            assert original.count(instance) == 1
            original = original.replace(instance, declarations + "media_framebuffer dut(.write_bank(2'bzz),.*);")
            bench = OUT / "tb_framebuffer_legacy_ports.v"
            bench.write_text(original, encoding="utf-8")
        # New zoom inputs remain unconnected in these legacy1x/cache checks.
        # Add only public-port declarations in a temporary bench copy.
        zoom_source = bench.read_text(encoding="utf-8")
        marker = "media_framebuffer dut("
        assert zoom_source.count(marker) == 1
        zoom_source = zoom_source.replace(marker, "wire [1:0] view_mode=2'bzz;wire [1:0] view_active;\n" + marker, 1)
        bench = OUT / (case + "_zoom_ports.v")
        bench.write_text(zoom_source, encoding="utf-8")
        binary = OUT / (case + ".vvp")
        command = [iv, "-g2012", "-Wall", "-s", top, *flags, "-o", str(binary),
                   str(ROOT / "rtl/common/key_debounce.v"),
                   str(SIM / "audit/em638325_pipeline_model.v"), str(bench)]
        with (OUT / (case + ".log")).open("w", encoding="utf-8") as log:
            subprocess.run(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, check=True)
            subprocess.run([vvp, str(binary)], cwd=ROOT, stdout=log, stderr=subprocess.STDOUT,
                           check=True, timeout=1200)
        print(f"PASS {case}: {OUT / (case + '.log')}", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
