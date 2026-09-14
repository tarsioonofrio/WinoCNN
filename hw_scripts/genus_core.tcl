# ---------------------------------------------------------------------------
# WinoCNN — Genus synthesis skeleton (core-only, ASIC flow)
#
# Prerequisites:
#   1. Run Vivado HLS with hw_scripts/script_asic.tcl (-DWINO_ASIC).
#      That exports simple synchronous RAM ports (ap_memory) instead of AXI.
#   2. Provide the technology libraries and the SRAM macro library below.
#
# This script is a SKELETON.  Paths and library names must be filled in for
# the target PDK.  It is intentionally not runnable as-is.
#
# Goal: area / FF / Fmax / power for the WinoCNN core, with the external
# memories black-boxed (so the comparison is logic-vs-logic against the
# reference accelerator).
# ---------------------------------------------------------------------------

# --- 1. Libraries -----------------------------------------------------------
set_db init_lib_search_path {./libs ./libs/sram}
# Standard-cell / IO libraries of the target technology:
# read_libs {<stdcell>.lib <io>.lib}
# SRAM macro library (timing/power views of the memory macros):
# read_libs {<sram>_tt_1v0_25c.lib}

# --- 2. RTL -----------------------------------------------------------------
# Produced by:  vivado_hls -f hw_scripts/script_asic.tcl
set HLS_RTL "HLS_asic/solution_asic/impl/verilog"
read_hdl [glob ${HLS_RTL}/*.v]
read_hdl hw_scripts/wino_sram_bb.v

elaborate wino_systolic_top
set_top wino_systolic_top

# --- 3. Constraints ---------------------------------------------------------
# Target clock (match the HLS create_clock period, 2 ns):
create_clock -name clk -period 2.0 [get_ports clk]
# Input/output delays around the memory ports:
# set_input_delay  -clock clk 0.2 [all_inputs]
# set_output_delay -clock clk 0.2 [all_outputs]

# --- 4. Black-box the memories ---------------------------------------------
# The ap_memory ports of wino_systolic_top are external; keep them as
# black-boxes so Genus does not try to implement them as flops.
# set_dont_touch [get_ports {input_DDR0* input_DDR1* weight_DDR0* weight_DDR1* \
#                            weight_DDR2* weight_DDR3* output_DDR0* output_DDR1* \
#                            mem_params*}]
# For memories inferred inside the core, mark them as black-boxes:
# set_dont_touch [get_cells -hier -filter "is_memory == true"]

# --- 5. Synthesis -----------------------------------------------------------
syn_generic
syn_map
syn_opt

# --- 6. Reports -------------------------------------------------------------
report_area    > reports/area.rpt
report_gates   > reports/gates.rpt
report_timing  > reports/timing.rpt
report_power   > reports/power.rpt
report_qor     > reports/qor.rpt

# Write the netlist for place & route / power analysis:
# write_hdl -mapped > netlist/wino_systolic_top.v
# write_sdc          > netlist/wino_systolic_top.sdc
