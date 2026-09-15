# ---------------------------------------------------------------------------
# WinoCNN — Genus logical synthesis (ASIC flow), FastConv-comparable
#
# Uses the SAME methodology as the reference accelerator
# (FastConv_SystemVerilog/.../scripts/logical_synthesis_body.tcl):
#   - TSMC 28 nm, tcbn28hpcplusbwp30p140 (BWP30P140) via MMMC
#   - 3 corners: ssg0p81v125c / tt0p9v25c / ffg0p99vm40c
#   - 500 MHz (2 ns) clock, same driving cell / output load
#   - syn_generic / syn_map / syn_opt + area/timing/power reports
#
# Prerequisites (run on paxos, where Genus and the PDK live):
#   1. Vivado HLS:  vivado_hls -f asic_scripts/script_asic.tcl
#      (exports simple synchronous RAM ports via -DWINO_ASIC)
#   2. module load cadence/genus/211
#   3. genus -f asic_scripts/genus_core.tcl
#
# Memories: the HLS-inferred RAMs (input/weight/bias/output buffers and the
# parameter RAM) are deliberately black-boxed, so they are NOT synthesized as
# flip-flop banks.  This matches the reference accelerator flow, where the
# physical memories are external and only the logic (address generation,
# control, datapath, pipeline registers) is compared.  See the exclusion loop
# in section 4.
# ---------------------------------------------------------------------------

set CONFIG_ROOT [file normalize [file dirname [info script]]]
set GIT_ROOT    [file normalize [file join $CONFIG_ROOT ..]]
set HLS_RTL     [file join $GIT_ROOT HLS_asic solution_asic impl verilog]
set OUT_FILES   [file join $GIT_ROOT reports genus]
set TOP_MODULE  wino_systolic_top

# --- 1. Technology (TSMC 28 nm) --------------------------------------------
read_mmmc [file join $CONFIG_ROOT mmmc_tsmc_28_bv.tcl]

# --- 2. Genus configuration (mirrors the FastConv body) --------------------
# Use all local cores (the FastConv body uses -local_cpu 112; override with
# WINO_CPU when running elsewhere).
if {![info exists env(WINO_CPU)]} { set env(WINO_CPU) 14 }
set_multi_cpu_usage -local_cpu $env(WINO_CPU)
set_db lp_default_probability 0.5
set_db syn_global_effort high
set_db auto_ungroup none
set_db hdl_parameter_naming_style ""
set_db interconnect_mode ple
set_db hdl_error_on_latch true
# Unresolved (excluded) RAM modules become black boxes instead of an error.
set_db hdl_error_on_blackbox false

# --- 3. Control Clock Gating -----------------------------------------------
set_db lp_insert_clock_gating true

# --- 4. RTL (from Vivado HLS) ----------------------------------------------
if {![file isdirectory $HLS_RTL]} {
    error "HLS RTL not found at $HLS_RTL — run asic_scripts/script_asic.tcl first"
}

# Black-box the HLS-inferred RAMs: any generated file that declares a
# `ram_style` memory module (the parameterized wrapper plus its `_ram`
# primitive) is skipped, so Genus treats its instances as unresolved black
# boxes.  All other modules (control, address generation, datapath, pipeline
# registers) are read and synthesized normally.
set HDL_FILES  {}
set BB_MODULES {}
foreach f [lsort [glob -nocomplain [file join $HLS_RTL *.v]]] {
    set fh [open $f r]
    set body [read $fh]
    close $fh
    if {[string match {*ram_style*} $body]} {
        lappend BB_MODULES [file rootname [file tail $f]]
        continue
    }
    lappend HDL_FILES $f
}
puts "INFO: black-boxed inferred RAM modules: $BB_MODULES"
puts "INFO: reading [llength $HDL_FILES] HDL files"
read_hdl {*}$HDL_FILES

# --- 5. Elaboration ---------------------------------------------------------
elaborate $TOP_MODULE
init_design

# --- 6. Synthesis - mapping and optimization --------------------------------
syn_generic
syn_map
syn_opt

# --- 7. Reports -------------------------------------------------------------
file mkdir $OUT_FILES
file mkdir [file join $OUT_FILES gate_level]

report_clock_gating > [file join $OUT_FILES ${TOP_MODULE}_clock_gating.rpt]
report_ple          > [file join $OUT_FILES ${TOP_MODULE}_ple.rpt]
report_gates        > [file join $OUT_FILES ${TOP_MODULE}_gates.rpt]
report_area         > [file join $OUT_FILES ${TOP_MODULE}_area.rpt]
report_qor          > [file join $OUT_FILES ${TOP_MODULE}_qor.rpt]

foreach view {analysis_view_0p81v_125c_capwst_slowest \
              analysis_view_0p90v_25c_captyp_nominal \
              analysis_view_0p99v_m40c_capbst_fastest} {
    set_analysis_view -setup $view -hold $view
    report_timing > [file join $OUT_FILES ${TOP_MODULE}_timing_${view}.rpt]
    report_power -unit mW > [file join $OUT_FILES ${TOP_MODULE}_power_${view}.rpt]
}

# --- 8. Netlist for P&R / power --------------------------------------------
write_hdl > [file join $OUT_FILES gate_level ${TOP_MODULE}_logic_mapped.v]

foreach view {analysis_view_0p81v_125c_capwst_slowest \
              analysis_view_0p90v_25c_captyp_nominal \
              analysis_view_0p99v_m40c_capbst_fastest} {
    set_analysis_view -setup $view -hold $view
    write_sdf > [file join $OUT_FILES gate_level ${TOP_MODULE}_${view}.sdf]
}

set_analysis_view -setup analysis_view_0p90v_25c_captyp_nominal \
                  -hold analysis_view_0p90v_25c_captyp_nominal
write_db [file join $OUT_FILES gate_level ${TOP_MODULE}_logic_mapped.db]

exit
