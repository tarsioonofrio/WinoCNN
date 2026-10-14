#!/usr/bin/env bash
# Access-count-only Xcelium RTL sweep for square images, Cin=3/Cout=12.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RTL="${WINOCNN_RTL_DIR:-$ROOT/HLS_asic/solution_asic/impl/verilog}"
CSIM="${WINOCNN_CSIM:-$ROOT/single_csim.out}"
REPORT="${WINOCNN_ACCESS_REPORT:-$ROOT/reports/sram_access_sweep_cin3_cout12_seed20261010}"
mkdir -p "$REPORT"
printf 'size,status,cycles,input_DDR0_reads,input_DDR1_reads,weight_DDR0_reads,mem_params_reads,output_DDR0_writes,output_DDR1_writes\n' > "$REPORT/summary.csv"

if [[ ! -d "$RTL" ]]; then
  echo "HLS RTL not found: $RTL" >&2
  exit 2
fi
for size in 32 64 128 256 512; do
  sim="$REPORT/${size}x${size}"
  mkdir -p "$sim"
  if [[ -f "$sim/param.hex" ]]; then
    echo "Using pre-generated $size x $size parameter/stimulus files" > "$sim/stimulus_generation.log"
  elif [[ -x "$CSIM" ]]; then
    if ! python3 "$ROOT/asic_scripts/prepare_sram_access_stimulus.py" \
        --csim "$CSIM" --size "$size" --seed 20261010 --out "$sim" \
        > "$sim/stimulus_generation.log" 2>&1; then
      printf '%s,UNSUPPORTED_DESCRIPTOR,,,,,,,\n' "$size" >> "$REPORT/summary.csv"
      echo "${size}x${size}: parameter descriptor generation failed (see $sim/stimulus_generation.log)" >&2
      continue
    fi
  elif [[ -f "$sim/stimulus_generation.log" ]]; then
    printf '%s,UNSUPPORTED_DESCRIPTOR,,,,,,,\n' "$size" >> "$REPORT/summary.csv"
    echo "${size}x${size}: parameter descriptor was previously marked unsupported (see $sim/stimulus_generation.log)" >&2
    continue
  elif [[ ! -f "$sim/param.hex" ]]; then
    echo "No prepared stimulus and C-sim binary unavailable: $CSIM" >&2
    exit 2
  fi

  cp -f "$ROOT/asic_scripts/tb_wino_access.v" "$sim/"
  cp -f "$RTL"/*.dat "$sim/"
  python3 "$ROOT/asic_scripts/instrument_sram_models.py" "$RTL" "$sim/ram_models" > "$sim/instrument.log" 2>&1 || exit 3
  mapfile -t HLS_RTLS < <(for f in "$RTL"/*.v; do
    if ! grep -q 'ram_style' "$f"; then printf '%s\n' "$f"; fi
  done)
  input_words=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["random_physical_memory_words"]["input"])' "$sim/stimulus.json")
  weight_words=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["random_physical_memory_words"]["weight"])' "$sim/stimulus.json")
  printf '%s\n' '-smartorder -work work -top tb -access +rw -timescale 1ns/1ps' > "$sim/args.txt"
  (
    cd "$sim" || exit 1
    rm -rf xcelium.d
    xrun -f args.txt -define XRUN "${HLS_RTLS[@]}" ram_models/*.v \
      tb_wino_access.v -run -exit +INPUT_WORDS="$input_words" \
      +WEIGHT_WORDS="$weight_words" > xrun.log 2>&1
  )
  rc=$?
  if [[ $rc -ne 0 ]] || ! grep -q 'WINO_ACCESS_DONE' "$sim/xrun.log" || \
      grep -q 'WINO_ACCESS_TIMEOUT\|WINO_ACCESS_OOB' "$sim/xrun.log"; then
    printf '%s,SIMULATION_FAILED,,,,,,,\n' "$size" >> "$REPORT/summary.csv"
    echo "${size}x${size}: simulation failed (exit $rc; see $sim/xrun.log)" >&2
    continue
  fi
  python3 "$ROOT/asic_scripts/summarize_sram_counters.py" \
    "$sim/sram_access_counts.tsv" --json "$sim/sram_access_counts.json" \
    > "$sim/counter_summary.log" 2>&1 || exit 4
  python3 - "$size" "$sim/xrun.log" "$sim/sram_access_counts.json" "$REPORT/summary.csv" <<'PY'
import csv, json, re, sys
size, log_path, json_path, csv_path = sys.argv[1:]
log = open(log_path).read()
m = re.search(r"WINO_ACCESS_DONE cycles=(\d+) input_DDR0_reads=(\d+) input_DDR1_reads=(\d+) weight_DDR0_reads=(\d+) mem_params_reads=(\d+) output_DDR0_writes=(\d+) output_DDR1_writes=(\d+)", log)
if not m:
    raise SystemExit("completed marker is missing access counts")
with open(csv_path, "a", newline="") as f:
    csv.writer(f).writerow([size, "PASS", *m.groups()])
data = json.load(open(json_path))
with open(log_path.rsplit("/", 1)[0] + "/internal_sram_totals.json", "w") as f:
    json.dump(data["internal_totals_by_module"], f, indent=2)
PY
  echo "${size}x${size}: access counting complete"
done

echo "Sweep summary: $REPORT/summary.csv"
