##############################################################
## Logical / Physical synthesis constraints ##
##############################################################

### CONFIGS
set sdc_version 1.5
set_load_unit -femtofarads
set_time_unit -nanoseconds

### Creating the clock of 500 MHz
set period_clock 2;
create_clock -name {clk} -period $period_clock [get_ports {clk}]

### Ignoring the time analysis for the Reset
set_false_path -from [get_ports {reset}]

### INPUTS
set_driving_cell -lib_cell GINVD1BWP30P140 [all_inputs]

### OUTPUTS
set_load [load_of [get_lib_pins GINVMCOD8BWP30P140/I]] [all_outputs]

# Dando meio periodo para o ambiente
set_input_delay -clock clk [expr ${period_clock}/2] [all_inputs]
set_output_delay -clock clk [expr ${period_clock}/2] [all_outputs]
