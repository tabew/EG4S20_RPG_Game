# SD SPI fast-divider timing regression

Run from the repository root:

```powershell
python tools/verify_sd_spi_timing.py
python tools/verify_sd_rtl.py --spi --diag --display --out sim/sd/out/spi_fast_regression
```

The production `sd_spi` default is `FAST_DIV=1` at a 50 MHz system clock, producing 12.5 MHz SPI. `FAST_DIV=3` restores the 6.25 MHz baseline without changing ports. Initialization remains fixed at divider 63 (390.625 kHz). No SDRAM or media-controller changes are required by this driver change.

The engine samples MISO and advances MOSI on the **internal** falling phase. `sd_sclk` is a separate register that follows the old internal clock value, so the physical SCLK output changes **one 20 ns system clock later**. This existing pipeline must be included in timing calculations; adding a two-flop MISO synchronizer would change the sampled bit phase.

| Divider | Physical half period | Prior physical falling edge to MISO sample | MOSI change after physical rise | MOSI change before physical fall |
| --- | ---: | ---: | ---: | ---: |
| 3 | 80 ns | 140 ns | 60 ns | 20 ns |
| 1 | 40 ns | 60 ns | 20 ns | 20 ns |
| 0 | 20 ns | 20 ns | 0 ns | 20 ns |

These are RTL pin times before additional board skew. At divider 1, card clock-to-output 14 ns plus return-path delay 4 ns leaves 42 ns before the sample, or **41.5 ns margin** after reserving 0.5 ns sample setup. At divider 0 this MISO margin shrinks to 1.5 ns. More decisively, MOSI changes at the physical rising edge at divider 0, violating the modeled 5 ns command-input setup/hold requirement. Divider 0 is therefore an intentionally rejected test candidate; selecting it with this engine is not recommended.

The simulation-only bench uses the real `sd_spi` and a physical-wire card model. It drives command responses, tokens, payload, and two CRC bytes over MISO with 14 ns card output delay plus configurable return delay. Card-side command sampling checks MOSI setup and hold of at least 5 ns. The monitor observes the actual engine sample condition without driving or forcing DUT internals, and checks MISO setup of 0.5 ns and the full falling-edge-to-sample delay budget. The existing 20 ns output-register pipeline is already in the DUT; `CLOCK_BOARD_NS` adds independent board delay, not another copy of that pipeline.

The matrix covers the 6.25 MHz baseline, the 12.5 MHz production setting, 4 ns outbound clock skew with 6 ns return delay, 4 ns outbound MOSI skew with 6 ns return delay, and the expected 25 MHz timing rejection. Each passing case transfers 64 sectors for SDHC and 64 for SDSC (64 KiB combined), with exact 512-byte payload comparison, nonzero LBA verification, CMD16 verification for SDSC, request-address latching, reinitialization, and card-reported read-error recovery. Throughput excludes initialization and includes every sector's actual command, response, token, CRC, dummy clocks, FSM overhead, and request gap. The runner requires at least 1.7x speedup for both card types.

Results and simulator logs are written below `sim/sd/out/spi_timing`. The bench compiles under Icarus `-g2001`; it is not a synthesis source. These checks establish RTL behavior for the stated delays and do not establish routed FPGA I/O timing or board signal integrity. No hardware write is performed.
