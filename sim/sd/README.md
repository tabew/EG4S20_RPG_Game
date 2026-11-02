# Actual SD RTL regressions

Run from the repository root:

```powershell
python tools/verify_sd_rtl.py --spi --diag --display
```

The complete suite runs 39 regressions when `tools/out/sd_test.bmp` exists: 36 image cases plus SPI, diagnostics and RAM/display integration. Without that optional BMP it runs 38. The suite compiles real design RTL with Icarus Verilog and runs actual clocked Verilog testbenches. It does not import `tools/verify_sd.py`, mirror the DUT state machine in Python, or use forces on any DUT signal. All `.v` files here are simulation-only and must not be added as synthesis design sources.

Icarus is discovered on PATH or under `tools/iverilog/bin`. Explicit paths are also accepted:

```powershell
python tools/verify_sd_rtl.py --iverilog C:/iverilog/bin/iverilog.exe --vvp C:/iverilog/bin/vvp.exe --spi --diag --display
```

The local test environment uses the existing Icarus v12 installation under `tools/iverilog`. No simulator binary is required in source control. Compile and simulation outputs stay below `sim/sd/out`; existing PNG/BMP outputs are never rewritten.

## Block-interface image tests

`tb_sd_img.v` instantiates the actual `sd_img` and drives its public `init_done`, byte stream and block-completion inputs. Every requested LBA must exist in the generated sparse FAT32 image; unanticipated reads fail. Bytes include regular stalls and block completion follows the final byte. Initialization takes 200 system clocks, with an assertion against repeated initialization requests. The bench uses 16-bit thumbnail addresses and checks that all 49,152 destination addresses in the 256x192 image were written and have the expected final 4-bit palette index. Repeated writes to the same destination bin are intentional during downsampling. Unexpected validity, format errors, out-of-range writes and timeouts fail. Sparse fixtures are checked against the bench's 4,096-sector capacity.

The independent Python oracle reads the BMP's row format and directly computes the final source pixel for destination bin `(x,y)` with integer inverse-bin coordinates. It does not model counters, accumulators, the FAT parser or RTL state transitions. For the specified overwrite-downsampling convention, the selected source column is `ceil((x+1)*W/256)-1`; the storage-row calculation uses `ceil((bin_y+1)*H/192)-1`, with `bin_y=191-y` for bottom-up BMPs and `bin_y=y` for top-down BMPs. It then applies the shared 4096-entry palette ROM, which specifies the output color mapping.

Cases cover MBR and superfloppy FAT32 with sectors-per-cluster 1, 2, 4, 8, 16, 32, 64 and 128; default 257x193 padded rows; 513x385 images crossing 128-sector cluster boundaries; exact 256x192 and 640x480; top-down BMPs; fragmented FAT chains; start cluster 65543; reserved FAT high bits; a root directory cluster chain; first matching BMP selection; compression, planes, signature, offset, DIB and bpp errors; truncated headers/pixels and premature FAT chain end. The minimum accepted BMP dimensions are 256x192: explicit 128x96, width 255 and height 191 cases must reject with format error 3. When `tools/out/sd_test.bmp` exists, a separate case reads it unchanged and compares all pixels from the actual file.

## Serial SPI tests

`tb_sd_spi.v` implements a mode-0 behavioral card on the physical CS/SCLK/MOSI/MISO wires. It verifies six-byte command frames, CMD0/CMD8 arguments and CRCs, CMD55 before ACMD41, three ACMD41 polling iterations, delayed R1 responses, CMD58 CCS detection, SDSC CMD16 and SDHC/SDSC CMD17 addressing. It sends real serialized tokens, 512 payload bytes and CRC bytes. Every byte and block length is checked.

Both SDHC and SDSC run repeated nonzero reads with the request address deliberately changed immediately after the one-cycle request. Reinitialization after fast reads checks the measured physical SCLK period is slow again. An injected R1 read error must invalidate readiness; initialization and another full transfer must then recover. Eight successful data blocks and ten CMD17 commands are expected across the two card types. There are no accelerated delays or DUT forces.

## Diagnostic output test

With `--diag`, `tb_sd_diag.v` checks the public `gal_layer` RGB output for all eight bit positions, both diagnostic rows and the spaces between blocks. Its thumbnail address connection is 16 bits.

## Real RAM and display integration

With `--display`, `tb_sd_display.v` connects the real `tf_ram` and `gal_layer` through public ports with independent write/read clocks. It writes all 49,152 RAM locations before checking every location, checks synchronous read behavior and gives addresses 255, 256, 32767, 32768 and 49151 distinct values to expose row and high-address boundary aliasing.

For each of the 49,152 source pixels, the bench checks the first and last display pixels in its 2x2 block, for 98,304 address/RGB comparisons. It independently expects address `row*256+column`, equivalent to `{ay[8:1],ax[8:1]}` in the 512x384 picture window, and compares RGB from the actual RAM through the gallery palette at full fade. Stage-3 coordinates are clocked from stage 2 to exercise synchronous RAM alignment. The checks vary all four gallery pages and also verify that addresses clamp to zero outside the picture window.

## Focused runs and result files

```powershell
python tools/verify_sd_rtl.py --list
python tools/verify_sd_rtl.py --case topdown --case high_cluster
python tools/verify_sd_rtl.py --rtl path/to/snapshot.v --out sim/sd/out/snapshot_results --case mbr_spc4
```

`results.json` records each pass/fail and log path. Each image case has its own input sector/LBA hex files, expected pixels and `simulation.log`; additional logs are `spi.log`, `diag.log` and `display.log`.

Historical sensitivity checks for the earlier 128x96 implementation remain under `out/mutation_sampling` and `out/mutation_address`. They are not validation results for the current 256x192 implementation, and the temporary `out/baseline.v` was captured after concurrent fixes, so its passing results are not pre-fix evidence.

The suite covers module behavior in simulation; it does not validate board signal integrity, encrypted vendor IP, timing closure or FPGA memory fit. The thumbnail now consumes 196,608 RAM bits (24 KiB). Board synthesis and place-and-route are required to establish the actual BRAM packing and remaining capacity on the EG4S20 device.
