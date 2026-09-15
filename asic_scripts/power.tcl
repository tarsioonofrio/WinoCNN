# ---------------------------------------------------------------------------
# WinoCNN — Genus power analysis from the RTL SHM.
#
# Mirrors the FastConv power body: recreate a single-corner (tt) MMMC, read the
# mapped DB, annotate activity from the Xcelium SHM (sim_asic/dut.shm, produced
# by asic_scripts/run_sim_asic.sh), and report power.
#
#   module load cadence/genus/211
#   genus -f asic_scripts/power.tcl
# ---------------------------------------------------------------------------

set POWER_ROOT [file normalize [file dirname [info script]]]
set GIT_ROOT   [file normalize [file join $POWER_ROOT ..]]
set CONSTRAINTS_PATH $POWER_ROOT
set DB_FILE [file join $GIT_ROOT reports genus gate_level wino_systolic_top_logic_mapped.db]
set SHM     [file join $GIT_ROOT sim_asic dut.shm]
set START_TIME 0ns

set LIB_PATH /pdk/tsmc/PDK28/PDK_TSMC28_bv/tcbn28hpcplusbwp30p140_190a/TSMCHOME/digital/Front_End
set TECH_PATH /pdk/tsmc/PDK28/PDK_TSMC28_bv/tcbn28hpcplusbwp30p140_190a/TSMCHOME/digital/Back_End

create_library_set -name libset_0p90v_25c \
    -timing "${LIB_PATH}/timing_power_noise/NLDM/tcbn28hpcplusbwp30p140_180a/tcbn28hpcplusbwp30p140tt0p9v25c.lib"
create_opcond -name opcond_0p90v_25c -voltage 0.90 -temperature 25.0
create_timing_condition -name timing_cond_0p90v_25c \
    -opcond opcond_0p90v_25c -library_sets { libset_0p90v_25c }
create_rc_corner -name rc_corner_25c_captyp \
    -temperature 25.0 \
    -qrc_tech "${TECH_PATH}/qrc/RC_QRC_crn28hpc+_1p09m+ut-alrdl_5x1y1z1u_typical/qrcTechFile"
create_delay_corner -name delay_corner_0p90v_25c_captyp \
    -timing_condition timing_cond_0p90v_25c \
    -rc_corner rc_corner_25c_captyp
create_constraint_mode -name constraints_default \
    -sdc_files [file join $CONSTRAINTS_PATH constraints.sdc]
create_analysis_view -name analysis_view_0p90v_25c_captyp_nominal \
    -constraint_mode constraints_default \
    -delay_corner delay_corner_0p90v_25c_captyp

set_analysis_view -setup analysis_view_0p90v_25c_captyp_nominal \
                  -hold  analysis_view_0p90v_25c_captyp_nominal

read_db $DB_FILE
set_db interconnect_mode ple
read_stimulus $SHM -dut_instance tb.dut -start $START_TIME
report_power -header -unit mW > [file join $POWER_ROOT power_evaluation.txt]
exit
