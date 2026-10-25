create_clock -name clk50 -period 20.000 -waveform {0 10.000} [get_ports {clk50}]

create_clock -name clk_pix -period 40.000 [get_nets {clk_pix}]
create_clock -name clk_p5x -period 8.000 [get_nets {clk_p5x}]

set_false_path -from [get_clocks clk_pix] -to [get_clocks clk_p5x]
set_false_path -from [get_clocks clk_p5x] -to [get_clocks clk_pix]

set_false_path -from [get_ports {key_n[*]}]
set_false_path -from [get_ports {key_row[*]}]
set_false_path -from [get_ports {rst_key_n}]
