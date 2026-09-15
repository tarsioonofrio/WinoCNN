#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# WinoCNN ASIC-flow RTL simulation (Xcelium).
#
# Runs the HLS-generated RTL with asic_scripts/tb_wino_asic.v, preloaded with the
# stimulus in testbench/stim/, and writes an SHM (dut.shm) used by Genus power
# analysis.  Must run on a host with Cadence Xcelium (paxos).
#
#   module load cadence/xcelium/2303
#   bash asic_scripts/run_sim_asic.sh
# ---------------------------------------------------------------------------
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RTL="$ROOT/HLS_asic/solution_asic/impl/verilog"

# Per-domain working directories (stimulus, sim, SHM) keyed by the Winograd
# domain read from the configuration header.
WINO_DOM=$(grep -oP '#define\s+WINO_DOMAIN_SIZE\s+\K[0-9]+' "$ROOT/src/wino_hw_config.h")
TAG="dom${WINO_DOM}"
SIM="$ROOT/sim_asic/$TAG"
STIM="$ROOT/testbench/stim/$TAG"
echo "== Winograd domain $WINO_DOM (tag $TAG) =="

if [ ! -d "$RTL" ]; then
    echo "HLS RTL not found at $RTL -- run asic_scripts/script_asic.tcl first" >&2
    exit 2
fi

mkdir -p "$SIM"
cp -f "$ROOT/asic_scripts/tb_wino_asic.v" "$SIM/"
cp -f "$STIM/input.hex" "$STIM/weight.hex" "$STIM/param.hex" "$SIM/"
# The HLS-inferred internal RAMs ($readmemh "./*_ram.dat") need their .dat
# initialization files in the simulation working directory.
cp -f "$RTL"/*.dat "$SIM/"

cat > "$SIM/args.txt" <<'EOF'
-smartorder -work work -top tb -access +rw -timescale 1ns/1ps
EOF

cd "$SIM"
rm -rf dut.shm xcelium.d
xrun -f args.txt -define XRUN "$RTL"/*.v tb_wino_asic.v -run -exit
