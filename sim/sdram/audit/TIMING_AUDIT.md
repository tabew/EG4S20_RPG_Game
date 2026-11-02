Initial read-only RTL audit, before the later output-register improvement: no confirmed discrepancy with manufacturer command timing was found, and shared RTL was unchanged during this audit. At that time the photo was not yet available. The later photo and parent-approved physical setup-margin candidate are documented in [NEGEDGE_STAGE.md](NEGEDGE_STAGE.md); the tables and baseline results below describe the original controller.

Manufacturer reference: [Etron EM638325 Industrial Rev3.2](../EM638325_Industrial_Rev3.2.pdf), August 2015. Figures 5 (p8), 10/11 (p10), 17/18 (p16), Table 5 (p13), Table 16 (p20) were checked against the controller; the timing figures and AC table were visually inspected in the PDF. The extracted text loses some table/diagram alignment, so the PDF is the authority.

- Table 5: MRS 0x037 means A6:A4=011 (CAS3), A3=0 (sequential), A2:A0=111 (full-page), A9=0 (burst writes). Reserved bits are zero.
- Figure 17: READ at T0, STOP at T4, CL3 outputs D0/T3, D1/T4, D2/T5, D3/T6, then Hi-Z at T7. Thus STOP at T_N admits exactly N words. The existing model's exclusive end at STOP+3 agrees with this manufacturer diagram.
- Figure 18: write data is sampled on the WRITE edge and each subsequent edge before STOP; STOP itself takes no write beat.
- Table 16: CL3 tAC and tHZ are at most 5.4ns for the slowest listed grades; input setup/hold are 1.5ns/1ns. Figure 5 text specifies a two-clock read DQM latency.

Let SYS0 launch READ, PHY0 sample it 5ns later, and SYS_k/PHY_k be subsequent 20ns cycles. For a segment of N words:

| Event | System or memory edge | Controller relationship |
| --- | --- | --- |
| READ command sampled | PHY0, +5ns | State S_READ |
| First read data begins | PHY3 + tAC, no later than +70.4ns | CL3 |
| First word captured | SYS4, +80ns | Old age=2 |
| STOP command sampled | PHY_N, +20N+5ns | Age=N-1 between SYS_N and SYS_(N+1) |
| Last data begins | PHY_(N+2) + tAC, no later than +20N+50.4ns | Word N-1 |
| Last word captured | SYS_(N+3), +20N+60ns | Old age=N+1; rd_last on final request segment |
| PRE command sampled; burst stops | PHY_(N+3), +20N+65ns | Last word was captured 5ns earlier |

For N=1, STOP precedes the first output by two memory edges, and the single pipeline word still reaches SYS4 correctly. For N=128, STOP is PHY128, D127 starts PHY130, SYS131 captures D127, and PRE is PHY131. The RTL condition age>=2 && age<N+2 yields exactly N captures. Nominal latest-data-to-sample interval is 15-5.4=9.6ns; routed timing and the actual PLL relationship still require implementation timing evidence.

The writer's synchronous lookahead gives buffer[offset] at the WRITE edge, buffer[offset+1] on the next edge, and buffer[offset+N-1] on the last data edge. Data and byte mask use the same address pipeline. No extra beat is driven on STOP. The independent strobe tests below cover every request length and page-split offsets.

Source buffering inspection found no common 128-word boundary discrepancy: BUILD_FETCH precedes BUILD_HAVE, and WRITE_FETCH precedes WRITE_SEND, providing the registered RAM read stage. The BMP raw address is 640*y+x, and 640 RGB888 pixels occupy 1920 bytes, already aligned to four bytes. The framebuffer issues 128-word reads and up-to-16-word writes. These observations do not certify routed RAM timing or identify the visible-line cause.

Independent validation lives in [em638325_pipeline_model.v](em638325_pipeline_model.v) and [tb_pipeline_boundaries.v](tb_pipeline_boundaries.v). This is a manufacturer-derived audit model, not a vendor model. It uses a three-stage CAS token pipeline, drains already-issued tokens after STOP, and masks output bytes using DQM sampled two memory edges earlier. It does not reuse the original model's read_start/read_end arithmetic. It checks tRCD/tRP/tRAS/tWR/tRFC/tMRD for the slowest listed grade, but is not a comprehensive electrical model.

| Run | Result |
| --- | --- |
| New boundary/strobe test, tAC=5.4ns | PASS; 49,536 read words; lengths1..128; aligned, page-split and bank-carry starts; exact physical word counts; first/last data and rd_last; rotating per-beat masks0..15; producer gaps |
| Same test, tAC=9ns stress beyond the specified maximum | PASS; another49,536 words |
| Existing controller suite against the new model, tAC=6ns | PASS; four banks, all lengths, row/bank carry, byte strobes, refresh during slow producers; 32,768 bytes/183,620ns; maximum observed refresh gap356 clocks |

PowerShell reproduction from the workspace root:

```powershell
& '.\tools\iverilog\bin\iverilog.exe' -g2012 -s tb_pipeline_boundaries -o 'sim\sdram\audit\pipeline_boundaries.vvp' 'rtl\common\key_debounce.v' 'sim\sdram\audit\em638325_pipeline_model.v' 'sim\sdram\audit\tb_pipeline_boundaries.v'
& '.\tools\iverilog\bin\vvp.exe' 'sim\sdram\audit\pipeline_boundaries.vvp'
# Add quoted '-Ptb_pipeline_boundaries.TEST_T_AC_NS=9.0' to compile the9ns stress corner.
& '.\tools\iverilog\bin\iverilog.exe' -g2012 -s tb_media_sdram '-Ptb_media_sdram.TEST_T_AC_NS=6' -o 'sim\sdram\audit\original_suite_pipeline.vvp' 'rtl\common\key_debounce.v' 'sim\sdram\audit\em638325_pipeline_model.v' 'sim\sdram\tb_media_sdram.v'
& '.\tools\iverilog\bin\vvp.exe' 'sim\sdram\audit\original_suite_pipeline.vvp'
```

Next useful evidence: an uncropped photo showing the complete active image and edges; whether the lines are vertical or horizontal; their width and approximate zero-based coordinates measured inside the640x480 image; whether they span the whole image; and whether the coordinates stay fixed across two different images. If vertical, inspect x=127/128,255/256,383/384,511/512 and the rightmost639 edge. Compare x=0,128,256,384,512 as well to distinguish first-word from last-word placement. This is a discriminating measurement, not a confirmed SDRAM diagnosis. Keep controller and PHY unchanged pending real evidence.
