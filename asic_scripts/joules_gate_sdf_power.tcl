# Cadence Joules power analysis using the existing gate-level/SDF SHM.
# Required environment: WINO_JOULES_LIB, WINO_JOULES_NETLIST,
# WINO_JOULES_SDC, WINO_JOULES_SHM, WINO_JOULES_REPORT, WINO_JOULES_SDB.

foreach name {
    WINO_JOULES_LIB WINO_JOULES_NETLIST WINO_JOULES_SDC
    WINO_JOULES_SHM WINO_JOULES_REPORT WINO_JOULES_SDB
} {
    if {![info exists env($name)] || $env($name) eq ""} {
        error "Required environment variable $name is not set"
    }
}

set LIB      $env(WINO_JOULES_LIB)
set NETLIST  $env(WINO_JOULES_NETLIST)
set SDC      $env(WINO_JOULES_SDC)
set SHM      $env(WINO_JOULES_SHM)
set OUT      $env(WINO_JOULES_REPORT)
set SDB      $env(WINO_JOULES_SDB)

foreach path [list $LIB $NETLIST $SDC $SHM] {
    if {![file exists $path]} { error "Required Joules input is missing: $path" }
}
file mkdir [file dirname $OUT]
file mkdir [file dirname $SDB]

puts "INFO: Joules gate/SDF power analysis"
puts "INFO: netlist=$NETLIST"
puts "INFO: SHM=$SHM"
puts "INFO: library=$LIB"

read_libs -libs $LIB
read_netlist -top wino_systolic_top $NETLIST
read_sdc $SDC

# The SHM comes from an Xcelium gate-level run with nominal SDF annotated.
# Read its DUT scope directly; do not remap RTL activity onto the netlist.
read_stimulus -file $SHM -dut_instance tb.dut -format shm -start 0ns \
    -glitch_flow Both -report_missing_signals design
write_sdb -out $SDB
compute_power -mode average
report_power -out $OUT

puts "INFO: Joules power report written to $OUT"
puts "INFO: Joules activity database written to $SDB"
exit
