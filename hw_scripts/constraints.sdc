##############################################################
## Logical / Physical synthesis constraints ##
##############################################################

### CONFIGS
set sdc_version 1.5
set_load_unit -femtofarads
set_time_unit -nanoseconds

### Creating the clock of 500 MHz
### WinoCNN top (Vivado HLS) uses ap_clk / ap_rst.
set period_clock 2;
create_clock -name {ap_clk} -period $period_clock [get_ports {ap_clk}]

### Ignoring the time analysis for the Reset
set_false_path -from [get_ports {ap_rst}]

### INPUTS
set_driving_cell -lib_cell GINVD1BWP30P140 [all_inputs]

### OUTPUTS
set_load [load_of [get_lib_pins GINVMCOD8BWP30P140/I]] [all_outputs]

# Dando meio periodo para o ambiente
# The HLS control handshake ports (ap_start/ap_done/ap_idle/ap_ready) are not
# part of the datapath; applying half-period I/O delays to them would create a
# spurious ap_start -> ap_idle "critical path".  They are excluded from the
# external delay constraints, which are applied to the memory data ports only.
set data_inputs  [remove_from_collection [all_inputs]  [get_ports {ap_clk ap_rst ap_start}]]
set data_outputs [remove_from_collection [all_outputs] [get_ports {ap_done ap_idle ap_ready}]]
set_input_delay  -clock ap_clk [expr ${period_clock}/2] $data_inputs
set_output_delay -clock ap_clk [expr ${period_clock}/2] $data_outputs
