The parent authorized this isolated setup-margin candidate after examining the screen photo. It is a physical interface timing improvement; the photo does not prove a manufacturer command-sequencing defect or establish that this change removes the streaks.

Candidate: [media_sdram_ctrl_negedge.stage.v](media_sdram_ctrl_negedge.stage.v). Every memory-facing signal is registered together on the falling system-clock edge: RAS/CAS/WE/CS, CKE, address, bank, DQM, write data and DQ drive enable. Asynchronous reset selects CKE0, DQM1111, deselect/NOP, and undriven DQ. No PLL phase, CAS latency, MRS value, public interface or buffer geometry changed.

With system rising edges SYS_k at20k ns and PHY_k at20k+5ns, decode from SYS0 reaches the output registers at10ns and SDRAM atPHY1=25ns. This gives15ns nominal output launch-to-PHY interval instead of5ns. The FPGA path into the falling-edge registers now has a10ns half-cycle budget, which requires routed STA. Nominal command/data setup budget after the manufacturer's1.5ns requirement becomes13.5ns before routing/clock uncertainty.

All READ and STOP commands shift by one PHY cycle. The source counter STOP condition remains age=N-1, while read capture changes from age>=2,<N+2 to age>=3,<N+3; the last capture is age=N+2. PRE follows capture through the same output register stage.

For a segment ofN words launched at SYS0:

| Read event | Original controller | Falling-edge candidate |
| --- | --- | --- |
| READ sampled | PHY0=5ns | PHY1=25ns |
| First output (CL3) | PHY3+tAC | PHY4+tAC |
| First capture | SYS4=80ns | SYS5=100ns |
| STOP sampled | PHY_N=20N+5ns | PHY_(N+1)=20N+25ns |
| Last output | PHY_(N+2)+tAC | PHY_(N+3)+tAC |
| Last capture | SYS_(N+3)=20N+60ns | SYS_(N+4)=20N+80ns |
| PRE sampled | PHY_(N+3)=20N+65ns | PHY_(N+5)=20N+105ns |

The last data is sampled15ns after its producing PHY edge; with tAC<=5.4ns the nominal data setup budget remains9.6ns before routing. N=1 andN=128 both retain exactlyN words. PRE is25ns after the last candidate capture, and occurs one PHY cycle after STOP has drained the CAS pipeline.

For anN-word write launched at SYS0: WRITE PHY1=25ns; last data PHY_N=20N+5ns; STOP PHY_(N+1)=20N+25ns; PRE PHY_(N+4)=20N+85ns; wr_done SYS_(N+7)=20N+140ns. Last data to PRE is80ns (manufacturer tWR minimum40ns), and PRE to actual wr_done registering edge is55ns (tRP minimum21ns). All command-to-command delays remain unchanged because the output register delay is common; read PRE alone moves an additional system cycle with the read-capture adjustment.

Reproduction: run `python sim/sdram/audit/verify_negedge_stage.py` from the workspace root. This uses unchanged existing testbenches via isolated wrappers plus the independent pipeline boundary test and [staged_pin_monitor.v](staged_pin_monitor.v). The wrappers assert public reset explicitly at1ns, then the original bench releases it normally. This is required because the original bench's declaration initializer rst_n=0 does not cause an assertion edge in Icarus before PHY15ns, and the first falling SYS edge is20ns. It does not force DUT internals or alter production reset logic; actual board reset is held low by the PLL-lock/reset logic.

| Configuration | Result |
| --- | --- |
| Independent boundary/strobe model tAC5.4ns | PASS49,536 read words; lengths1..128, page/bank splits, first/last, exact physical counts, per-word strobes0..15, producer gaps |
| Independent boundary/strobe model tAC9ns stress | PASS another49,536 read words |
| Existing controller suite + independent model6ns | PASS |
| Existing controller suite + original model6ns | PASS |
| Existing controller suite + original model9ns | PASS |
| Physical pin timing monitor, every configuration | PASS: changes only at falling SYS, minimum launch-to-PHY15ns, safe power-up, wr_done55ns after last PRE |
| Existing-suite bandwidth/refresh | 32,768 bytes/184,900ns =177.22MB/s; maximum observed refresh gap363clocks=7.26us |

Full-frame compatibility PASS with `python sim/sdram/audit/verify_negedge_framebuffer.py`: unchanged framebuffer source was copied into the audit directory, linked against the candidate and the independent memory model, and exercised by the existing complete-frame bench. Compared2,457,600 first-image pixels and307,200 second-image pixels (2,764,800 total), with21,600 read bursts and38,406 write bursts. No underrun; minimum observed video FIFO level2, maximum source queue128, accelerated producer backpressure0. Concurrent upload, active-command abort drain, short-frame rejection, source overflow, reversed row order and repeated blank-epoch FIFO clears all passed.

After the parent authorized production application, the controller module alone was updated inside its marker block. Exact equality to the validated stage was asserted; controller block SHA256: `56fb73c1ad3b55aa49794fc546d3cdcebcb5eb6a9c1e0157a90c8ecb41f1ee67`. The parent also approved the same explicit asynchronous assertion in the public testbench reset stimulus; original release times53ns/73ns, all data expectations and all timing limits remain unchanged. Stock tools/verify_sdram.py PASS against actual production RTL at6ns and9ns, with identical32768bytes/184900ns and maximum refresh gap363clocks. Stock tools/verify_framebuffer.py also PASS against actual production RTL: asynchronous FIFO tests and2,764,800 compared full-frame pixels;21,600 read bursts/38,406 write bursts, no underflow, minimum video FIFO2, maximum source128, accelerated producer backpressure0. Concurrent upload, abort drain, short-frame rejection, overflow, reversed rows and coordinated blank-epoch clears passed. Native implementation timing and board comparison remain the parent's next verification steps.
