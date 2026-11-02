# Staged single-port RAM inference change

The first native spectrum build inferred capture as block RAM but duplicated the
FFT work memory into two distributed 256×36 RAMs. Native synthesis succeeded,
while physical implementation exceeded the mslice limit by 51 (4951/4900).

Evidence in `D:/jingsai/EG4_Runs/syn_1/run.log` at the time of inspection:

- Lines 471–472 and 856–857: two `u_audio_spectrum/ramread0_syn_291` and `_292`
  distributed memories, each 256×36.
- Line 1248: spectrum hierarchy 1559 LUT, 361 ripple, 537 sequential,
  one block RAM, one DSP.

The staged `audio_spectrum_fft_singleport_candidate.v` changes only the work RAM
interface expression. Combinational muxes select read address, write address,
write data, and write enable. The synchronous block contains exactly one read
`work_q <= work_mem[work_read_addr]` and one gated write. Capture, FFT arithmetic,
state transitions, publication, and cycle timing are unchanged. No device RAM
attribute is used. This candidate is not automatically included in the native
project and has the same module name as the production module; compile one source
or the other, never both together.

Validation commands:

```powershell
python sim/spectrum/run_ram_equivalence.py
python sim/spectrum/run_spectrum.py --rtl sim/spectrum/audio_spectrum_fft_singleport_candidate.v --out sim/spectrum/out_candidate
```

The equivalence bench compares `levels`, `frame_valid`, and `overflow` every
clock, including reset. It drives 17 consecutive valid-cadence frames covering
all eight tone bands, random PCM, positive DC and zero input, with 525- and
833-clock ticks. It additionally compares pathological-cadence overflow and
reset behavior. The DFT runner independently checks every positive-frequency
complex bin and the full 99-frame public-level regression. Results are written
separately from baseline evidence.

The side-by-side equivalence run passed all 2,553,399 clocks in 19.16 seconds.
See `out/ram_equivalence.log` for the exact transcript. The full candidate DFT
regression also passed all 99 frames / 14,042,269 clocks in 59.92 seconds, with
maximum real/imaginary component error 4.0831. Its `out_candidate/results.txt`
and `out_candidate/bins.txt` are byte-identical to the original baseline files:
all public levels, output clock cycles, overflow states, and all 127 positive
complex bins match for every frame. Candidate adoption is READY for the parent's
native mapping check; no production source was changed by this validation.

The parent agent owns production adoption and the next native synthesis/place
and route build. Inference into block RAM and actual physical resource savings
must be established by that build, not assumed from simulation.
