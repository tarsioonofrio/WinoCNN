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
#   genus : Genus logical synthesis + area/timing/power reports
#   all   : both
# ---------------------------------------------------------------------------
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STEP="${1:-all}"

run_hls() {
    echo "== Vivado HLS (ASIC) =="
    cd "$ROOT"
    vivado_hls -f asic_scripts/script_asic.tcl
}

run_genus() {
    echo "== Genus (TSMC 28 nm, 2 ns) =="
    cd "$ROOT"
    genus -f asic_scripts/genus_core.tcl
}

case "$STEP" in
    hls)   run_hls ;;
    genus) run_genus ;;
    all)   run_hls; run_genus ;;
    *) echo "usage: $0 [hls|genus|all]"; exit 1 ;;
esac

echo "== done: $STEP =="
