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
rm -f "$SIM/gate/rtl_golden_check.json"
echo "== Winograd domain $WINO_DOM (tag $TAG) =="

if [ ! -d "$RTL" ]; then
    echo "HLS RTL not found at $RTL -- run asic_scripts/script_asic.tcl first" >&2
    exit 2
fi
if [ ! -f "$STIM/output_golden.bin" ]; then
    echo "Golden DDR image missing: $STIM/output_golden.bin" >&2
    echo "Generate it with single_csim.out using dump_asic_golden before RTL/power." >&2
    exit 3
fi

mkdir -p "$SIM"
rm -f "$SIM/rtl_golden_check.json"
cp -f "$ROOT/asic_scripts/tb_wino_asic.v" "$SIM/"
cp -f "$STIM/input.hex" "$STIM/weight.hex" "$STIM/param.hex" "$STIM/output_golden.bin" "$SIM/"
# The HLS-inferred internal RAMs ($readmemh "./*_ram.dat") need their .dat
# initialization files in the simulation working directory.
cp -f "$RTL"/*.dat "$SIM/"

cat > "$SIM/args.txt" <<'EOF'
-smartorder -work work -top tb -access +rw -timescale 1ns/1ps
EOF

cd "$SIM"
rm -rf dut.shm xcelium.d
xrun -f args.txt -define XRUN "$RTL"/*.v tb_wino_asic.v -run -exit 2>&1 | tee xrun.log
if ! grep -q 'WINO_SIM_DONE' xrun.log || grep -q 'WINO_SIM_TIMEOUT' xrun.log; then
    echo "RTL simulation did not complete normally; power flow is blocked." >&2
    exit 4
fi
python3 "$ROOT/asic_scripts/compare_rtl_output.py" \
    output_golden.bin out_writes.txt --json rtl_golden_check.json
echo "RTL output matches the C-model golden DDR image; power analysis may proceed."
