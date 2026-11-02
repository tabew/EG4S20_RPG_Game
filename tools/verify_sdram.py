"""Exercise the actual SDRAM controller with a storage-backed command model.

Covers every request length, row/bank boundaries, byte masks, CAS3, refresh,
slow write producers and sustained display bandwidth. The simulation model is
independent of the controller state machine and never forces DUT internals.
This is functional/protocol verification, not physical FPGA timing signoff.
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
    parser.add_argument("--staged", action="store_true", help="test the staged controller before integration")
    args = parser.parse_args()
    source = ROOT / "rtl/common/key_debounce.v"
    if args.staged or "module media_sdram_ctrl" not in source.read_text(encoding="utf-8"):
        source = SIM / "media_sdram_ctrl.stage.v.txt"
    local = ROOT / "tools/iverilog/bin"
    iverilog = str(local / "iverilog.exe") if (local / "iverilog.exe").exists() else shutil.which("iverilog")
    vvp = str(local / "vvp.exe") if (local / "vvp.exe").exists() else shutil.which("vvp")
    if not iverilog or not vvp:
        raise SystemExit("Icarus Verilog is required (bundled tools/iverilog/bin or PATH)")
    with tempfile.TemporaryDirectory(prefix="media_sdram_") as temporary:
        binary = Path(temporary) / "controller.vvp"
        for access_ns in (6, 9):
            print(f"Checking SDRAM data access delay {access_ns}ns", flush=True)
            subprocess.run([iverilog, "-g2012", "-s", "tb_media_sdram",
                            f"-Ptb_media_sdram.TEST_T_AC_NS={access_ns}",
                            "-o", str(binary), str(source),
                            str(SIM / "eg_sdram_model.v"),
                            str(SIM / "tb_media_sdram.v")], cwd=ROOT, check=True)
            subprocess.run([vvp, str(binary)], cwd=ROOT, check=True, timeout=60)
    print("PASS SDRAM controller protocol, storage and throughput verification")


if __name__ == "__main__":
    main()
