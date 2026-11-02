# EG4S20 embedded SDRAM controller

`media_sdram_ctrl` is included by the vendor project through `rtl/common/key_debounce.v`. The staging copy is `media_sdram_ctrl.stage.v.txt`; it is not a second design source. `python tools/verify_sdram.py` tests the included RTL. `--staged` tests the staging copy.

## Hardware sources

- Anlogic **DS301 EG4S20 Datasheet**, revision 2.7.8, December 2025, section 4, pages 3–5: identifies the internal SDRAM die as **EM638325**, confirms its capacity of 2M × 32 bits and the `EG_PHY_SDRAM_2M_32` direct primitive, including `dm0` through `dm3`. [Official document](https://anlogic.oss-cn-shanghai.aliyuncs.com/web_doc/%E5%B7%A5%E5%85%B7%E4%B8%8E%E8%B5%84%E6%96%99%E4%B8%8B%E8%BD%BD/%E6%8A%80%E6%9C%AF%E6%96%87%E6%A1%A3/EG4/%E6%95%B0%E6%8D%AE%E6%89%8B%E5%86%8C/DS301_EG4S20_Datasheet.pdf). Local reference: `DS301_EG4S20_Datasheet.pdf`.
- Etron **EM638325 Industrial**, revision 3.2, August 2015: four banks, each 2048 rows × 256 columns × 32 bits; sequential full-page burst support; table 16 AC limits; note 11 power-up sequence. [Manufacturer document](https://etron.com/wp-content/uploads/2022/04/EM638325-Industrial_Rev-3.2.pdf). Local reference: `EM638325_Industrial_Rev3.2.pdf`; readable table extraction: `EM638325_raw.clean.txt`.
- Installed vendor primitive declaration: `D:/jingsai/sim_release/eg/eg_phy_sdram_2m_32.v`. It is an empty synthesis declaration, so it is deliberately **not used as the simulation memory**.
- Installed TangDynasty user guide: `D:/jingsai/doc/TD_User_Guide_V5.6.pdf`, section 3.9.2, pages 93–94, documents direct embedded SDRAM primitive use and a 90-degree clock phase recommendation. No external SDRAM package-pin constraints are added.

## Timing and clock contract

The controller runs at 50 MHz. `phy_clk` must be a continuous PLL-derived 50 MHz clock whose rising edge occurs **5 ns after** the controller `clk` rising edge. All memory-facing outputs are registered together on the falling controller-clock edge, **15 ns before** the following PHY rising edge. This delays physical commands and read captures by one clock compared with the original implementation. Read data still has 15 ns between its SDRAM producing edge and the following controller sampling edge. Check both the 10 ns internal path into the falling-edge registers and the generated-clock relationship in physical timing analysis. The [manufacturer audit and edge table](audit/NEGEDGE_STAGE.md) explain the change; it improves nominal output setup margin without establishing the cause of the photographed image streaks.

The manufacturer table gives, across the listed speed grades:

| Requirement | Worst listed limit | Controller default |
| --- | --- | --- |
| tRCD / tRP | 21 ns minimum | 2 clocks, plus FSM transition margin |
| tRFC | 63 ns minimum | 5 clocks, plus FSM transition margin |
| tRAS | 42 ns minimum | met by activation, CAS/write and recovery sequence |
| tWR | 2 clocks minimum | 2 clocks after write termination, plus transition margin |
| tMRD | 2 clocks minimum | 2 clocks, plus transition margin |
| CL3 tAC | 5.4 ns maximum | model checks 6 ns and 9 ns access delays |
| input setup / hold | 1.5 ns / 1 ns | phase-separated command/data launch |
| tREFI | 15.6 us maximum average | refresh due after 5 us, bounded deferral for a burst |
| power-up | 200 us, CKE low, DQM high | 10,000 system clocks, then precharge / 8 refreshes / MRS |

The behavioral model enforces a stricter 7.8 us refresh deadline. The functional tests do not replace FPGA routing timing analysis or an actual board test.

## Request interface

- One command at a time, accepted on `cmd_valid && cmd_ready`.
- `cmd_addr[20:0]` is a **32-bit word** address with mapping `{bank[1:0],row[10:0],column[7:0]}`. Legal requests have `cmd_len` from 1 through 128 and remain inside the 2M-word address space.
- `cmd_write=1`: send exactly `cmd_len` words on `wr_valid && wr_ready`. A one bit in `wr_strb` writes that byte. A private 128-word buffer permits arbitrary producer pauses while refresh continues. `wr_done` pulses after actual memory writes, write recovery and final precharge have completed.
- `cmd_write=0`: reserve room for the whole request before submitting it. Each `rd_valid` returns a word; `rd_last` accompanies the final word. Read data cannot be stalled.
- `busy` includes startup, buffered/in-progress commands and command recovery. A read's `rd_last` precedes final bank recovery; use `cmd_ready` for the next request.
- Requests crossing a column-page boundary are split into separately activated SDRAM bursts. Address carry into the next row or bank is tested.
- Mode register `0x037` selects CAS3, sequential full-page bursts and burst writes. BURST TERMINATE explicitly limits each physical burst.

## Verification

`eg_sdram_model.v` provides real 2M-word storage, 2048-row bank tracking, CAS3 output latency, delayed read termination, full-page wrapping and byte masks. It independently checks startup CKE/DQM, precharge, refresh, mode programming, ACTIVATE/READ/WRITE timing, write data setup and command setup. The testbench drives only public controller signals and does not force internal registers.

`tb_media_sdram.v` tests all 128 request lengths, unaligned row crossings, a bank boundary, all four banks and their highest rows, masked byte writes, refresh during a producer paused for 100 clocks per word, idle refresh, and continuous 128-word read requests. The two access-delay corners both passed after integration. Sustained reads transferred **32,768 bytes in 184,900 ns (177.22 MB/s)**, exceeding the 640×480×60×4 requirement of 73.728 MB/s. The latest test observed a maximum refresh gap of **363 clocks (7.26 us)**; this is an observation from these tests, not a formal maximum proof. The independent pipeline audit also passed 49,536 read words at each of 5.4 ns and 9 ns, with every request length, exact physical word counts and changing per-word byte strobes. Full-frame integration against that independent model compared 2,764,800 pixels without underflow.
