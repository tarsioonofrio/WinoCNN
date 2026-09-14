# ---------------------------------------------------------------------------
# WinoCNN — Genus logical synthesis (ASIC flow), FastConv-comparable
#
# Uses the SAME methodology as the reference accelerator
# (FastConv_SystemVerilog/synthesis/_template_sys):
#   - TSMC 28 nm, tcbn28hpcplusbwp30p140 (BWP30P140) via MMMC
#   - 3 corners: ssg0p81v125c / tt0p9v25c / ffg0p99vm40c
#   - 500 MHz (2 ns) clock, same driving cell / output load
#   - syn_generic / syn_map / syn_opt + area/timing/power reports
#
# Prerequisites (run on paxos, where Genus and the PDK live):
#   1. Vivado HLS:  vivado_hls -f hw_scripts/script_asic.tcl
#      (exports simple synchronous RAM ports via -DWINO_ASIC)
#   2. module load genus
#   3. genus -f hw_scripts/genus_core.tcl
#
# This file was NOT executed in the authoring environment (no Genus/PDK
# there); paths below must match the paxos install.
# ---------------------------------------------------------------------------

set CONFIG_ROOT [file normalize [file dirname [info script]]]
set GIT_ROOT    [file normalize [file join $CONFIG_ROOT ..]]
set HLS_RTL     [file join $GIT_ROOT HLS_asic solution_asic impl verilog]
set OUT_FILES   [file join $GIT_ROOT reports genus]

# --- 1. Technology (TSMC 28 nm) --------------------------------------------
read_mmmc [file join $CONFIG_ROOT mmmc_tsmc_28_bv.tcl]

# --- 2. Genus configuration (mirrors the FastConv body) --------------------
set_db lp_default_probability 0.5
set_db syn_global_effort high
set_db auto_ungroup none
set_db hdl_parameter_naming_style ""
set_db interconnect_mode ple
set_db hdl_error_on_latch true
set_db lp_insert_clock_gating true

# --- 3. RTL (from Vivado HLS) ----------------------------------------------
# HLS emits one Verilog file per module plus the top.
if {![file isdirectory $HLS_RTL]} {
    error "HLS RTL not found at $HLS_RTL — run hw_scripts/script_asic.tcl first"
}
read_hdl [glob -nocomplain [file join $HLS_RTL *.v]]

elaborate wino_systolic_top
init_design

# --- 4. Memories ------------------------------------------------------------
# The external buffers (input/weight/output/params) are ports of
# wino_systolic_top on the ASIC flow (ap_memory), so they are outside the
# core and are not synthesized here.
#
# Internal RAMs inferred by HLS (input_buffer, out_buffer, weight_buff) are
# implemented as flops/registers by default.  To compare logic-vs-logic,
# black-box them instead and bind the PDK SRAM macros:
#   set_db [get_cells -hier -filter "is_memory == true"] .black_box true
# or map them explicitly, e.g.:
#   # set_db hls_memory_impl_type bram
# Enable the line below once the SRAM library is loaded in the MMMC file.
# set_dont_touch [get_cells -hier -filter "is_memory == true"]

# --- 5. Synthesis -----------------------------------------------------------
syn_generic
syn_map
syn_opt

# --- 6. Reports -------------------------------------------------------------
file mkdir [file join $OUT_FILES reports]

report_clock_gating > [file join $OUT_FILES reports wino_clock_gating.rpt]
report_ple          > [file join $OUT_FILES reports wino_ple.rpt]
report_gates        > [file join $OUT_FILES reports wino_gates.rpt]
report_area         > [file join $OUT_FILES reports wino_area.rpt]
report_qor          > [file join $OUT_FILES reports wino_qor.rpt]

foreach view {analysis_view_0p81v_125c_capwst_slowest \
              analysis_view_0p90v_25c_captyp_nominal \
              analysis_view_0p99v_m40c_capbst_fastest} {
    set_analysis_view -setup $view -hold $view
    report_timing > [file join $OUT_FILES reports wino_timing_${view}.rpt]
    report_power -unit mW > [file join $OUT_FILES reports wino_power_${view}.rpt]
}

# Netlist for P&R / power:
# write_hdl -mapped > [file join $OUT_FILES wino_systolic_top.v]
