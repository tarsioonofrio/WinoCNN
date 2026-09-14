############################################################
## WinoCNN — HLS script for the ASIC flow
##
## Differs from script.tcl in one essential point: the top is
## compiled with -DWINO_ASIC, which switches the external-memory
## ports from AXI master (`m_axi`) to plain synchronous RAM
## (`ap_memory`).  The resulting RTL has simple address/data/we/ce
## ports that can be black-boxed and mapped to PDK SRAM macros in
## Genus (see genus_core.tcl).
##
## `set_part` is only used because Vivado HLS requires a target
## device to schedule; it does not affect the exported RTL, which
## is technology-independent.
############################################################
open_project HLS_asic
set_top wino_systolic_top

set ASIC_CFLAGS "-DWINO_ASIC -Wno-unknown-pragmas"

add_files src/wino_struct.h
add_files src/wino_macro.h
add_files src/wino_hw_config.h
add_files src/wino_mem_if.h
add_files src/wino.h
# wino.cpp includes wino_IO.cpp, wino_cell.cpp (which includes wino_buffer.cpp
# and wino_transform.cpp) and the generated wino_systolic_kernel.cpp, so the
# define covers the whole design.
add_files -cflags $ASIC_CFLAGS src/wino.cpp

add_files -tb software/buffer.cpp -cflags "-Wno-unknown-pragmas" -csimflags "-Wno-unknown-pragmas"
add_files -tb software/buffer.h -cflags "-Wno-unknown-pragmas" -csimflags "-Wno-unknown-pragmas"
add_files -tb software/matrix_utility.hpp -cflags "-Wno-unknown-pragmas" -csimflags "-Wno-unknown-pragmas"
add_files -tb software/param.cpp -cflags "-Wno-unknown-pragmas" -csimflags "-Wno-unknown-pragmas"
add_files -tb software/param.h -cflags "-Wno-unknown-pragmas" -csimflags "-Wno-unknown-pragmas"
add_files -tb testbench/single_main.cpp -cflags "-Wno-unknown-pragmas" -csimflags "-Wno-unknown-pragmas"
add_files -tb software/softlayer.hpp -cflags "-Wno-unknown-pragmas" -csimflags "-Wno-unknown-pragmas"
add_files -tb src/wino.h -cflags "-Wno-unknown-pragmas" -csimflags "-Wno-unknown-pragmas"
add_files -tb src_gold/wino_IO_gold.hpp -cflags "-Wno-unknown-pragmas" -csimflags "-Wno-unknown-pragmas"
add_files -tb src_gold/wino_cell_gold.hpp -cflags "-Wno-unknown-pragmas" -csimflags "-Wno-unknown-pragmas"
add_files -tb src_gold/wino_gold.cpp -cflags "-Wno-unknown-pragmas" -csimflags "-Wno-unknown-pragmas"
add_files -tb src_gold/wino_gold.h -cflags "-Wno-unknown-pragmas" -csimflags "-Wno-unknown-pragmas"
add_files -tb src/wino_hw_config.h -cflags "-Wno-unknown-pragmas" -csimflags "-Wno-unknown-pragmas"
add_files -tb src/wino_macro.h -cflags "-Wno-unknown-pragmas" -csimflags "-Wno-unknown-pragmas"
add_files -tb src/wino_mem_if.h -cflags "-Wno-unknown-pragmas" -csimflags "-Wno-unknown-pragmas"
add_files -tb src/wino_struct.h -cflags "-Wno-unknown-pragmas" -csimflags "-Wno-unknown-pragmas"

open_solution "solution_asic"
set_part {xczu9eg-ffvb1156-2-e}
create_clock -period 2 -name default
config_schedule -relax_ii_for_timing=0
config_sdx -target none
config_export -format ip_catalog -rtl verilog -vivado_optimization_level 2 -vivado_phys_opt place -vivado_report_level 0
set_clock_uncertainty 12.5%
csynth_design

# Export synthesizable RTL (Verilog) for Genus.
export_design -rtl verilog -format ip_catalog
