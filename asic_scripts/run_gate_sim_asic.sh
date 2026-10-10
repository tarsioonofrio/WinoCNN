#!/usr/bin/env bash
# Gate-level simulation of the Genus mapped netlist with nominal-view SDF.
# Reuses the RTL testbench's external synchronous RAM models and C-golden check.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WINO_DOM=$(grep -oP '#define\s+WINO_DOMAIN_SIZE\s+\K[0-9]+' "$ROOT/src/wino_hw_config.h")
TAG="dom${WINO_DOM}"
SIM="$ROOT/sim_asic/$TAG/gate"
STIM="$ROOT/testbench/stim/$TAG"
GATE="$ROOT/reports/genus/$TAG/gate_level"
RTL="$ROOT/HLS_asic/solution_asic/impl/verilog"
TOP="wino_systolic_top"
INTERNAL_RAM_TCO_NS="${WINO_INTERNAL_RAM_TCO_NS:-0.03}"
NETLIST="$GATE/${TOP}_logic_mapped.v"
SDF="$GATE/${TOP}_analysis_view_0p90v_25c_captyp_nominal.sdf"
GOLDEN_CHECK="$SIM/rtl_golden_check.json"

CELL_MODELS="${WINO_CELL_MODELS:-/pdk/tsmc/PDK28/PDK_TSMC28_bv/tcbn28hpcplusbwp30p140_190a/TSMCHOME/digital/Front_End/verilog/tcbn28hpcplusbwp30p140_110a/tcbn28hpcplusbwp30p140.v}"

for tool in xrun python3; do
    command -v "$tool" >/dev/null || { echo "Missing required tool: $tool" >&2; exit 2; }
done
[[ -s "$NETLIST" ]] || { echo "Mapped netlist missing: $NETLIST (run Genus synthesis first)" >&2; exit 2; }
[[ -s "$SDF" ]] || { echo "Nominal SDF missing: $SDF (run Genus synthesis first)" >&2; exit 2; }
[[ -s "$CELL_MODELS" ]] || { echo "TSMC standard-cell Verilog models missing: $CELL_MODELS; set WINO_CELL_MODELS" >&2; exit 2; }
[[ -s "$STIM/output_golden.bin" ]] || { echo "Golden DDR missing; run prepare_asic_stimulus.sh first" >&2; exit 2; }
[[ -s "$ROOT/asic_scripts/tb_wino_asic.v" ]] || { echo "ASIC testbench missing" >&2; exit 2; }
[[ -d "$RTL" ]] || { echo "HLS RTL directory missing: $RTL (run HLS first)" >&2; exit 2; }

# Genus deliberately leaves HLS-inferred buffer RAM modules unresolved. For
# functional gate-level simulation, compile staged behavioral HLS models with
# simulation-only transaction counters; external memories are in the testbench.
mapfile -t RAM_RTLS < <(grep -l 'ram_style' "$RTL"/*.v 2>/dev/null || true)
[[ ${#RAM_RTLS[@]} -gt 0 ]] || { echo "No HLS behavioral RAM models found under $RTL" >&2; exit 2; }

# The generated HLS RAMs are ideal zero-tCO models. When combined with SDF
# clock-to-Q and setup/hold checks, same-edge ideal reads can create artificial
# violations. Stage copies and add an explicit read tCO only to their outputs;
# never modify the generated HLS RTL. These are simulation assumptions, not
# characterized SRAM timing values or synthesized logic.
RAM_MODEL_DIR="$SIM/ram_models"
python3 "$ROOT/asic_scripts/instrument_sram_models.py" \
    "$RTL" "$RAM_MODEL_DIR" --read-tco-ns "$INTERNAL_RAM_TCO_NS"

mkdir -p "$SIM"
rm -f "$GOLDEN_CHECK"
cp -f "$ROOT/asic_scripts/tb_wino_asic.v" "$SIM/"
cp -f "$STIM/input.hex" "$STIM/weight.hex" "$STIM/param.hex" "$STIM/output_golden.bin" "$SIM/"
# The mapped netlist has black-boxed HLS RAM instances. Their functional
# models use these initialization files from the simulation working directory.
cp -f "$RTL"/*.dat "$SIM/"
echo "Behavioral RAM timing assumptions: external tCO=0.20 ns; internal HLS RAM tCO=${INTERNAL_RAM_TCO_NS} ns (6 read outputs)."
cat > "$SIM/args.txt" <<'EOF'
-smartorder -work work -top tb -access +rw -timescale 1ns/1ps
EOF
cat > "$SIM/sdf_cmd.cmd" <<EOF
SDF_FILE = "$SDF",
LOG_FILE = "$SIM/sdf_log.log",
SCOPE = tb.dut;
MTM_CONTROL = "MAXIMUM",
SCALE_FACTORS = "1.0:1.0:1.0",
SCALE_TYPE = "FROM_MAXIMUM";
EOF

cd "$SIM"
rm -rf dut.shm xcelium.d
rm -f out_writes.txt output_rtl.hex output_rtl1.hex rtl_golden_check.json \
    sdf_log.log xrun.log sram_access_counts.tsv sram_access_counts.json
xrun -f args.txt -sdf_cmd_file sdf_cmd.cmd -maxdelays \
    -define XRUN -define GATE_SIM \
    "$CELL_MODELS" "$RAM_MODEL_DIR"/*.v "$NETLIST" tb_wino_asic.v -run -exit 2>&1 | tee xrun.log

if ! grep -q 'WINO_SIM_DONE' xrun.log || grep -q 'WINO_SIM_TIMEOUT' xrun.log; then
    echo "Gate-level simulation did not complete normally; power flow is blocked." >&2
    exit 4
fi
[[ -s sdf_log.log ]] || { echo "SDF annotation log missing or empty; power flow is blocked." >&2; exit 5; }
if ! grep -Eq 'Compiled SDF file:.*\.sdf\.X' sdf_log.log ||
   ! grep -Eq 'Backannotation scope:[[:space:]]*tb\.dut' sdf_log.log; then
    echo "SDF log does not confirm compiled SDF and tb.dut scope; power flow is blocked." >&2
    exit 5
fi
if grep -Eiq 'SDF.*(error|failed|no instance matched)|annotation.*(failed|0 instances)' sdf_log.log; then
    echo "SDF annotation reported a failure; inspect $SIM/sdf_log.log" >&2
    exit 5
fi
if grep -q 'Warning!  Timing violation' xrun.log; then
    echo "Gate-level SDF simulation reported timing violations; power flow is blocked." >&2
    exit 5
fi
[[ -d dut.shm ]] || { echo "Gate-level SHM missing; power flow is blocked." >&2; exit 6; }
python3 "$ROOT/asic_scripts/compare_rtl_output.py" \
    output_golden.bin out_writes.txt --json rtl_golden_check.json
python3 "$ROOT/asic_scripts/summarize_sram_counters.py" \
    sram_access_counts.tsv --output-trace out_writes.txt --json sram_access_counts.json
# The checker already writes directly to $GOLDEN_CHECK (same as SIM cwd).
echo "Gate-level output matches the C-model golden; SDF activity is ready for power analysis."
