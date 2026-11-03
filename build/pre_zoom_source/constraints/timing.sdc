# Raw reference feeds the PLL only. All SD/control logic uses its 50MHz C2 output.
create_clock -name clk_ref50 -period 20.000 -waveform {0 10.000} [get_ports {clk50}]
create_clock -name clk50 -period 20.000 -waveform {0 10.000} [get_nets {clk_mem50}]
# C3 is +90 degrees relative to C2: SDRAM rising edge is 5ns after controller edge.
create_clock -name clk_sdram50 -period 20.000 -waveform {5 15.000} [get_nets {clk_sdram50}]
# Standard CEA640x480p60 release: exact25.2MHz pixel,126MHz serial.
create_clock -name clk_pix -period 39.682540 [get_nets {clk_pix}]
create_clock -name clk_p5x -period 7.936508 [get_nets {clk_p5x}]
# The retained memory PLL uses its old40MHz output only as external feedback.
create_clock -name clk_memory_feedback40 -period 25.000 [get_nets {u_clk/legacy_pix}]

set_false_path -from [get_clocks clk_pix] -to [get_clocks clk_p5x]
set_false_path -from [get_clocks clk_p5x] -to [get_clocks clk_pix]

set_false_path -from [get_ports {key_n[*]}]
set_false_path -from [get_ports {key_row[*]}]
set_false_path -from [get_ports {rst_key_n}]

# media_cdc uses toggle/ack handshakes and two-stage control synchronizers.
# Only asynchronous control crossings are excluded; same-domain feedback remains timed.
set_false_path -from [get_clocks {clk_pix}] -through [get_nets {u_media_cdc/req_toggle}] -to [get_clocks {clk50}]
set_false_path -from [get_clocks {clk_pix}] -through [get_nets {u_media_cdc/status_ack}] -to [get_clocks {clk50}]
set_false_path -from [get_clocks {clk50}] -through [get_nets {u_media_cdc/req_ack}] -to [get_clocks {clk_pix}]
set_false_path -from [get_clocks {clk50}] -through [get_nets {u_media_cdc/status_toggle}] -to [get_clocks {clk_pix}]

# Payload is held until round-trip acknowledgement and captured only after control
# synchronization: at least40ns for requests,50ns for status. Bound actual routing
# to30ns instead of suppressing the multi-bit data paths.
set_max_delay -datapath_only -from [get_clocks {clk_pix}] -through [get_nets {u_media_cdc/req_payload*}] -to [get_clocks {clk50}] 30.000
set_min_delay -from [get_clocks {clk_pix}] -through [get_nets {u_media_cdc/req_payload*}] -to [get_clocks {clk50}] 0.000
set_max_delay -datapath_only -from [get_clocks {clk50}] -through [get_nets {u_media_cdc/status_payload*}] -to [get_clocks {clk_pix}] 30.000
set_min_delay -from [get_clocks {clk50}] -through [get_nets {u_media_cdc/status_payload*}] -to [get_clocks {clk_pix}] 0.000

# The video FIFO exports Gray pointers into only the opposite first sync stage.
# Bound every bit by the faster source period; keep sync stage1->stage2 timed.
set_max_delay -datapath_only -from [get_clocks {clk50}] -through [get_nets {u_framebuffer/video_fifo/wgray*}] -to [get_regs {u_framebuffer/video_fifo/wg_meta*}] 20.000
set_min_delay -from [get_clocks {clk50}] -through [get_nets {u_framebuffer/video_fifo/wgray*}] -to [get_regs {u_framebuffer/video_fifo/wg_meta*}] 0.000
set_max_delay -datapath_only -from [get_clocks {clk_pix}] -through [get_nets {u_framebuffer/video_fifo/rgray*}] -to [get_regs {u_framebuffer/video_fifo/rg_meta*}] 20.000
set_min_delay -from [get_clocks {clk_pix}] -through [get_nets {u_framebuffer/video_fifo/rgray*}] -to [get_regs {u_framebuffer/video_fifo/rg_meta*}] 0.000

# Coordinated epoch flush and front-valid control each enter a two-flop sync.
set_false_path -from [get_clocks {clk_pix}] -through [get_nets {u_framebuffer/p_epoch}] -to [get_regs {u_framebuffer/epoch_meta*}]
set_false_path -from [get_clocks {clk_pix}] -through [get_nets {u_framebuffer/p_return}] -to [get_regs {u_framebuffer/return_meta*}]
set_false_path -from [get_clocks {clk50}] -through [get_nets {u_framebuffer/s_ack}] -to [get_regs {u_framebuffer/ack_meta*}]
set_false_path -from [get_clocks {clk50}] -through [get_nets {u_framebuffer/front_live}] -to [get_regs {u_framebuffer/front_meta*}]
