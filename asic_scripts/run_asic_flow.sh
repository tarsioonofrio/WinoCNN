#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# WinoCNN — ASIC flow runner.
#
# Must run on a host with Vivado HLS, Genus and the TSMC 28 nm PDK
# (e.g. paxos.inf.pucrs.br).  On that host:
#
#   module load vivado_hls    # or: source /etc/profile.d/modules.sh; module use ...
#   bash asic_scripts/run_asic_flow.sh hls
#
#   module load genus
#   bash asic_scripts/run_asic_flow.sh genus
#
# Steps:
#   hls   : Vivado HLS -> Verilog RTL (HLS_asic/solution_asic/impl/verilog)
#   genus : Genus logical synthesis + area/timing reports + mapped netlist/SDF
#   sim   : RTL simulation + mandatory bit-exact output comparison to C-model
#   gate-sim : gate-level simulation with SDF + golden comparison
#   power : Genus activity-based power (requires passing gate-SDF/golden check)
#   all   : HLS, RTL check, Genus synthesis, gate-SDF sim/check, then power
# ---------------------------------------------------------------------------
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STEP="${1:-all}"

run_hls() {
    echo "== Vivado HLS (ASIC) =="
    cd "$ROOT"
    local dom
    dom=$(grep -oP '#define\s+WINO_DOMAIN_SIZE\s+\K[0-9]+' "$ROOT/src/wino_hw_config.h")
    rm -f "$ROOT/sim_asic/dom${dom}/rtl_golden_check.json" \
          "$ROOT/sim_asic/dom${dom}/gate/rtl_golden_check.json"
    vivado_hls -f asic_scripts/script_asic.tcl
}

run_genus() {
    echo "== Genus (TSMC 28 nm, 2 ns) =="
    cd "$ROOT"
    local dom check
    dom=$(grep -oP '#define\s+WINO_DOMAIN_SIZE\s+\K[0-9]+' "$ROOT/src/wino_hw_config.h")
    check="$ROOT/sim_asic/dom${dom}/rtl_golden_check.json"
    if [ ! -f "$check" ] || ! grep -q '"result": "PASS"' "$check"; then
        echo "RTL-vs-golden check missing or not PASS: $check" >&2
        echo "Run asic_scripts/run_sim_asic.sh first; synthesis/power is blocked." >&2
        exit 3
    fi
    rm -f "$ROOT/sim_asic/dom${dom}/gate/rtl_golden_check.json"
    genus -f asic_scripts/genus_core.tcl
}

run_sim() {
    echo "== RTL simulation and golden comparison =="
    cd "$ROOT"
    bash asic_scripts/run_sim_asic.sh
}

run_power() {
    echo "== Genus power (requires passing gate-SDF/golden comparison) =="
    cd "$ROOT"
    local dom check
    dom=$(grep -oP '#define\s+WINO_DOMAIN_SIZE\s+\K[0-9]+' "$ROOT/src/wino_hw_config.h")
    check="$ROOT/sim_asic/dom${dom}/gate/rtl_golden_check.json"
    if [ ! -f "$check" ] || ! grep -q '"result": "PASS"' "$check"; then
        echo "Gate-level SDF-vs-golden check missing or not PASS: $check" >&2
        echo "Run Genus synthesis and asic_scripts/run_gate_sim_asic.sh first; power is blocked." >&2
        exit 3
    fi
    genus -f asic_scripts/power.tcl
}

run_gate_sim() {
    echo "== Gate-level simulation with SDF and golden comparison =="
    cd "$ROOT"
    bash asic_scripts/run_gate_sim_asic.sh
}

case "$STEP" in
    hls)   run_hls ;;
    sim)   run_sim ;;
    genus) run_genus ;;
    gate-sim) run_gate_sim ;;
    power) run_power ;;
    all)   run_hls; run_sim; run_genus; run_gate_sim; run_power ;;
    *) echo "usage: $0 [hls|sim|genus|gate-sim|power|all]"; exit 1 ;;
esac

echo "== done: $STEP =="
