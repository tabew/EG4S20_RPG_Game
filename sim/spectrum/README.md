# Actual PCM audio spectrum

The production `audio_spectrum_fft` module is appended to `rtl/video/hdmi_tx.v`.
Its source is frozen after the 99-frame independent DFT regression. Everything
before the appended module was preserved byte for byte by this task; other agents
own concurrent changes to the existing HDMI transmitter and its tick output.

```verilog
audio_spectrum_fft u_spectrum (
    .clk(clk_pix), .rst_n(rst_pix_n),
    .sample_tick(audio_sample_tick),
    .pcm_sample(media_mute ? 16'sd0 : hdmi_pcm_sample),
    .levels(spectrum_levels), .frame_valid(spectrum_frame_valid),
    .overflow(spectrum_overflow)
);
```

Use the encoder's actual one-clock 48 kHz sample tick in the same pixel clock
domain. Input PCM is the actual signed 16-bit HDMI sample. The module never
backpressures or changes audio. `levels[8*b +: 8]` is band `b`, 0 through 120;
band zero is in the least significant byte. All eight bytes change together
with a one-clock `frame_valid`. Reset clears levels, valid, and sticky overflow.

The transform is a 256-point real-input radix-2 complex DIT FFT with bit-reversed
loading and a rectangular window. Each of eight stages divides by two: bins
therefore represent DFT/256. Working components are signed 18-bit; twiddles are
signed Q1.15. Complex multiplication schedules four products through one signed
18-by-16 multiplier expression. Products and butterfly sums/subtractions are
sign-extended before shifts and truncation. There is no generated clock or CDC.

At 48 kHz, blocks arrive at 187.5 Hz and bin spacing is 187.5 Hz. This is coarse
frequency analysis; the visualization does not claim continuous Hz precision.
A rectangular window can show leakage for tones between bin centers.

| Band | Positive bins | Bin center frequencies, Hz |
| --- | --- | --- |
| 0 | 1 | 187.5 |
| 1 | 2 | 375 |
| 2 | 3–4 | 562.5–750 |
| 3 | 5–8 | 937.5–1500 |
| 4 | 9–16 | 1687.5–3000 |
| 5 | 17–32 | 3187.5–6000 |
| 6 | 33–64 | 6187.5–12000 |
| 7 | 65–127 | 12187.5–23812.5 |

DC and Nyquist are excluded. Each band's maximum `abs(real)+abs(imag)` feeds a
monotone piecewise log2 compressor with eight steps per octave and a magnitude
floor below 8 to reject fixed-point roundoff. The level attacks immediately and
falls by at most two display units per complete block. A zero input therefore
clears any displayed level within 60 complete zero blocks (320 ms), plus block
alignment. There is no synthetic movement or note/pitch envelope input.

Capture uses one 512-by-16 array containing two banks. The previous bank is
copied in 512 clocks while the next bank continues recording. A separate
256-by-36 array holds real/imaginary working values. Both RAMs have registered
reads and no reset loops. The FFT itself takes 11,264 clocks, followed by 254
scan clocks and nine publication clocks. Total turnaround is about 12,040
clocks after the final captured sample, versus 134,400 clocks per 48 kHz block
at 25.2 MHz. The ping-pong capture does not depend on finishing the copy before
the next sample. An impossible tick cadence, capture-bank collision, or a new
complete block while computation is busy sets sticky `overflow`; samples still
are not stalled. Actual native mapping, device resource fit, and timing are
checked by the parent agent's integrated build; this task did not launch one.

Run the complete focused regression from the repository root:

```powershell
python sim/spectrum/run_spectrum.py
```

The runner compiles with `-g2001` using the bundled Icarus tools and requires only
Python's standard library. It generates inputs and compares all 127 positive
complex bins for every output frame against an independent floating-point DFT.
Hierarchical observations are used only by the bench; no debug ports were added
to production RTL. Public level checks independently validate band selection,
relative response, mute behavior, valid pulses, and atomic publication.

Coverage includes eight bin-centered sine tones (bins 1, 2, 3, 6, 12, 24, 48,
96), two mixtures, six amplitudes, full-scale positive/negative DC, silence,
impulse, seeded noise, signed 8-bit PSG gain with 32 kHz samples held onto a
48 kHz stream, consecutive blocks at 525 and 833 clocks per tick, 64 muted
blocks, and resume. A separate two-clock tick stress bench checks sticky
overflow and reset. Waveform dumps and full HDMI frame simulation are avoided.

The initial 99-frame run checked 14,042,269 pixel clocks and passed with maximum
real/imaginary component error 4.0831 normalized PCM units. Ascending amplitude
levels were 32, 40, 48, 56, 72, and 88. Reproducible detailed outputs are generated
under `sim/spectrum/out/`, including `report.json` and simulation logs.

Frozen module SHA256 (bytes from `module audio_spectrum_fft` to end of file):
`ba1f88eb3398660782a759c8b8a3612e88c080b1e07658129bdaa4efd4d3e07f`.

`append_spectrum.py` records the original append-only construction, including
twiddle generation; it refuses to append a duplicate module. Normal builds and
regressions do not run it and do not generate any external coefficient asset.
