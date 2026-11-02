# Independent monster sprite RGB verification

Run from the repository root:

```powershell
python tools/verify_monster_sprite.py
python tools/verify_monster_sprite.py --quick
python tools/verify_monster_sprite.py --demonstrate-regressions
```

The regression demonstrations use the user's existing original backup at
`build/pre_monster_transform_source/rtl/video/mon_layer.v`; use
`--legacy-source PATH` to select another original copy. Ordinary verification
needs no backup. Icarus is discovered in `tools/iverilog/bin` or `PATH`.
Compilation uses `-g2001 -Wall` and only the production monster layer, its actual
synchronous ROM module, and the standalone testbench. No other video layers,
raster timing, SD/SDRAM, audio, or top-level controls are instantiated.

The oracle independently reads the actual `rtl/gen/mon.hex` and
`rtl/gen/monpal.hex` into separate arrays. It walks each source pixel, unpacks
its high/low nibble using integer division/remainder, repeatedly applies a
**forward clockwise rotation**, then horizontally mirrors the resulting display
position. Expected colors use integer RGB565 channel multiplication/division
for fades 0, 4, and 8. Expected screen pixels use integer `/3`, not the DUT's
fixed-point scaler or inverse lookup equations. The oracle never reads the
DUT's palette, coordinates, nibble selector, or pixel data to determine RGB.
A separate monitor reads the DUT byte address solely to check range bounds.

Every configuration scans the entire 144x144 window, its complete one-pixel
border, and distant blanking coordinates including (4095,4095). `in_win` is
checked combinationally, and `valid`/RGB are checked at P3 for the pixel sampled
at P1, matching the renderer's three-register `de3` contract. This deliberately
does not reproduce the original layer's extra byte delay or extra valid stage.
Both even and odd source nibbles receive equal coverage. Black source palette
entries remain ordinary RGB565 black; validity still denotes the whole window.

Default coverage is 25 monsters x 8 transforms x 3 fade levels = 600 complete
rasters, followed by 16 X/Z-default cases, fully unconnected-equivalent Z
controls, and an asynchronous-reset raster: 618 configurations total. Coverage
assertions require exactly 12,814,848 inside RGB pixels, 6,407,424 of each nibble
parity, and 3,672 palette-15 pixels. Expected additional checks include 387,470
outside/settling clocks and 13,202,318 total clocks.

The regression demonstrations verify two independent pre-existing defects:

* The original backup produces exactly 666 mismatches for monster 0, rotation
  0, mirror off, fade 8 under the P3 timing/RGB contract.
* Reintroducing only the missing palette drain (stopping at `pcnt=15` instead
  of `pcnt=16`) produces exactly 153 undefined-color mismatches for monster 21:
  its 17 real palette-15 source pixels, each displayed nine times. The fixed
  module must pass those same points with zero mismatches.

Logs and a JSON report containing measured counts, elapsed times, and input
SHA256 hashes are saved under `sim/monster/out`, or the directory passed to
`--out`. The source images and generated ROM/palette files are never rewritten.

Callers must hold the rotation/mirror controls stable for a frame; the parent
integration commits controls on its frame tick. Rotation uses 0/1/2/3 clockwise
quarter-turns and mirroring acts horizontally on the final rotated display.
Any rotation containing X/Z defaults to zero; only exact mirror 1 enables it.
Palette ID/fade updates retain the original asynchronous palette-load behavior;
the bench allows 40 blanking clocks before demanding the new palette colors.
This is RTL functional verification, not an FPGA timing or hardware test.
