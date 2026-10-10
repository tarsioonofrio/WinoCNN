#!/usr/bin/env bash
# Build the RTL stimulus and its bit-exact output-DDR golden from one C-sim run.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [ "$#" -ne 17 ]; then
    echo "usage: $0 H W CIN OH OW COUT KH KW STRIDE PAD_H PAD_W RELU SCALE FEATURE.bin WEIGHT.bin STIM_DIR KERNEL_MODE" >&2
    exit 2
fi

H=$1; W=$2; CIN=$3; OH=$4; OW=$5; COUT=$6
KH=$7; KW=$8; STRIDE=$9; PAD_H=${10}; PAD_W=${11}; RELU=${12}; SCALE=${13}
FEATURE="$(realpath "${14}")"
WEIGHT="$(realpath "${15}")"
STIM="$(realpath -m "${16}")"
KERNEL_MODE=${17}
WINO_DOM=$(grep -oP '#define\s+WINO_DOMAIN_SIZE\s+\K[0-9]+' "$ROOT/src/wino_hw_config.h")
# A new stimulus invalidates any prior gate-level/golden approval.
rm -f "$ROOT/sim_asic/dom${WINO_DOM}/gate/rtl_golden_check.json"

mkdir -p "$STIM"
make -C "$ROOT" single_csim.out CFLAG='-fPIC -O2 -fsigned-char'
WORK="$(mktemp -d "${TMPDIR:-/tmp}/winocnn-asic-golden.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

CSIM_ARGS=("$H" "$W" "$CIN" "$OH" "$OW" "$COUT" "$KH" "$KW"
           "$STRIDE" "$PAD_H" "$PAD_W" "$RELU" "$SCALE"
           "file:$FEATURE" random "file:$WEIGHT")
if ! (cd "$WORK" && "$ROOT/single_csim.out" "${CSIM_ARGS[@]}" compare . "$KERNEL_MODE") \
        >"$WORK/csim_compare.log" 2>&1 || ! grep -q 'Not different!' "$WORK/csim_compare.log"; then
    cat "$WORK/csim_compare.log" >&2
    echo "C-sim did not match the integer golden; refusing to prepare RTL/power stimulus." >&2
    exit 4
fi
echo "C-sim vs integer golden: PASS (Not different!)"

if ! (cd "$WORK" && "$ROOT/single_csim.out" "${CSIM_ARGS[@]}" \
        dump_asic_golden "$STIM" "$KERNEL_MODE") >"$WORK/csim_golden.log" 2>&1; then
    cat "$WORK/csim_golden.log" >&2
    echo "Could not generate the C-model DDR reference image." >&2
    exit 5
fi
python3 "$ROOT/asic_scripts/bin2hex.py" "$WORK"
cp "$WORK/input.hex" "$WORK/weight.hex" "$WORK/param.hex" "$STIM/"
echo "Prepared matched C-sim/RTL stimulus and output golden in: $STIM"
