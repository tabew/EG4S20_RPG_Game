# HDMI 48 kHz logical audio validation

The open encoder uses the existing 40 MHz pixel / 200 MHz DDR serializer clocks and the supplied 800×600, 1056×628, positive HS/VS timing. It inserts four 32-pixel packets in the 256-pixel horizontal blank of every line, including vertical blank. AVI declares RGB full range, VIC 0 because this is a VESA timing. Display acceptance of audio at this non-CEA timing still requires a board/sink test.

With `AUDIO_DI_EN=1`, the wrapper connects the open encoder to three original protected `Serial_N_1_lvds_dat` data serializers and one `Serial_N_1_lvds` clock serializer. Their actual TD model ports are `DP_I[9:0]`, `PCLK`, `SCLK`, `DSP_O`; neither serializer has a reset input. The clock word is `10'b0000011111`, matching the original DVI model. The parent project probe records the verified connections in `sim/hardware_reference_probe/DVI_serializer_public_pins.txt`. The previous DVI transmitter remains the `AUDIO_DI_EN=0` fallback. FPGA-generated stereo 1 kHz sine is the audio source. `mute` replaces newly generated PCM samples with zero; buffered samples can take one horizontal line to drain. The legacy `aud_pkt`, `aud_req`, `aud_got` interface is retained for compatibility; the generated test tone does not consume it.

The open encoder delays RGB, HS, VS, and DE through ten lookahead registers and one registered channel encoder: eleven pixel edges from input sampling to parallel TMDS word. All three channels have equal latency. The existing vendor serializer contributes its existing physical latency. No external video timing is generated or changed.

| Pixel position | HDMI content |
| --- | --- |
| 0–799 on active rows | RGB video |
| 800–803 | Control |
| 804–811 | Data island preamble |
| 812–813 | Leading data island guard |
| 814–845 | Audio sample packet, up to four stereo frames |
| 846–877 | Audio clock regeneration packet |
| 878–909 | AVI InfoFrame |
| 910–941 | Audio InfoFrame |
| 942–943 | Trailing data island guard |
| 944–1045 | Control |
| 1046–1053 before active video | Video preamble |
| 1054–1055 before active video | Video guard |

A fractional accumulator adds 48,000 per pixel and subtracts 40,000,000 on a sample. Sample intervals are 833 or 834 pixel clocks, giving exactly 48 kHz average relative to the pixel clock. Forty-eight samples form one sine period. The audio clock packet uses N=6144 and CTS=40000: `40,000,000 × 6144 / (128 × 40000) = 48,000`. Samples are 24-bit LPCM with a 16-bit sine amplitude shifted left eight bits; IEC60958 status identifies 48 kHz, 24-bit consumer PCM and distinct left/right channel numbers. A sixteen-sample FIFO bridges sample cadence and packet placement. Overflow is sticky and tested.

Run from the project root:

```powershell
python tools/verify_hdmi_audio.py
```

An interface-only wrapper test checks RGB888/RGB565 selection, mute routing, channel/clock connections, and compatibility with old instances that omit the new inputs. Its serializer stubs validate connections only and do not model physical serialization. The packet testbench simulates two complete frames and the Python decoder reconstructs actual 10-bit parallel TMDS symbols. It checks TERC4 decoding; header and subpacket BCH; AVI and audio InfoFrame checksums and fields; ACR frequency; present bits and 192-frame IEC60958 blocks; sample parity; stereo values and the exact 48-sample sine sequence; sample intervals and average count; active-video decoding and pipeline coordinates; HS/VS/DE widths; eight-pixel preambles and two-pixel guards. The encrypted serializer is intentionally outside this logical simulation. TD synthesis/elaboration/timing and actual monitor/speaker audio are separate checks. A passing simulation does not establish board audio output.

Packet layouts, BCH recurrence, and the channel encoder are adapted from [hdl-util/hdmi](https://github.com/hdl-util/hdmi), commit `83b1c9543a91b776671a44e68e130f81cae437b7`, by Sameer Puri and contributors, under the MIT license. The full upstream MIT license is retained in [LICENSE-MIT](LICENSE-MIT). The scheduling, external-timing adapter, fractional sample source, FIFO, and independent decoder are project-specific.
