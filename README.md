# WinoCNN

> **ISCAS 2027 paper experiments:** use the `iscas2027` branch of this
> repository. It is the paper-specific branch for the WinoCNN implementation,
> experiment configuration, and reproduction guidance below; `master` remains
> the upstream-integration line.

WinoCNN combines systolic array and fast Winograd algorithm for CNN acceleration. This system supports flexible convolution kernel sizes without sacrificing DSP efficiency through various algorithmic, architecture and on-chip memory subsystem designs and optimizations. Overall, our accelerator delivers high throughput and state-of-the-art DSP efficiency compared to previous accelerator implementations.

Copyright (c) <2021> 
  
  <University of Illinois at Urbana-Champaign>

  All rights reserved.

Developed by: 		

  <University of Illinois at Urbana-Champaign>

  <http://dchen.ece.illinois.edu/>

This open source project contains the source code for WinoCNN.

When referencing this application in a publication, please cite the following paper:
  
[1] X. Liu, Y. Chen, C. Hao, A. Dhar and D. Chen, "WinoCNN: Kernel Sharing Winograd Systolic Array for Efficient Convolutional Neural Network Acceleration on FPGAs", IEEE International Conference on Application-specific Systems, Architectures and Processors, 2021. 

## Experiments used in the ISCAS 2027 paper

This repository contains the WinoCNN implementation and its flow evidence; the
paper source and the script that imports WinoCNN's results live in the local
sibling checkout `../iscas2027`. For the paper's WinoCNN row, start with:

| What | Where |
|---|---|
| Paper table and its scope note | `../iscas2027/tab/asic-results.tex` |
| How the paper reads WinoCNN results and computes its row | `../iscas2027/scripts/access_model.py` and `../iscas2027/scripts/gen_tables.py` |
| Exact workload, dataset provenance, and C-sim result | [`reports/winocnn_modulo5_4_seed1_32x32_cin3_cout12/`](reports/winocnn_modulo5_4_seed1_32x32_cin3_cout12/), especially `README.md`, `provenance.json`, and `csim_validation.json` |
| Gate-SDF run, golden comparison, and activity-based power | [`gate_sdf_attempt_20261010/RESULTS.md`](reports/winocnn_modulo5_4_seed1_32x32_cin3_cout12/gate_sdf_attempt_20261010/RESULTS.md) and [`joules_gate_sdf_20261011/README.md`](reports/winocnn_modulo5_4_seed1_32x32_cin3_cout12/joules_gate_sdf_20261011/README.md) |
| Mapped cell area and synthesis provenance | [`power_flow_20261010/RESULTS.md`](reports/winocnn_modulo5_4_seed1_32x32_cin3_cout12/power_flow_20261010/RESULTS.md) |
| Validated 32×32 per-SRAM counts | [`SRAM_ACCESS_RESULTS.md`](reports/winocnn_modulo5_4_seed1_32x32_cin3_cout12/SRAM_ACCESS_RESULTS.md) |
| Larger image-size, access-count-only sweep (no output/golden validation) | [`reports/sram_access_sweep_cin3_cout12_seed20261010/`](reports/sram_access_sweep_cin3_cout12_seed20261010/) |

The paper workload is a `32×32` input, `Cin=3`, `Cout=12`, `3×3` kernel,
stride 1, no padding, scale 128, F(2×2,3×3), with 2 PEs / 32 scalar
multipliers. Its deterministic WinoCNN-style data uses seed 1, signed 5-bit
features (`[-16, 15]`) and signed 4-bit weights (`[-8, 7]`). Generate these
with the WinoCNN adapter below; do not substitute a dataset from the FastConv
library. The original C-sim/synthesis package records source revision
`146fa38d11fdf3860f854250f01f5f76ffaeb4a6` in `run_metadata.json` and includes
a SHA-256 source manifest. The gate-SDF validation and power are a later,
separately archived stage; the ISCAS table script explicitly reads their
results rather than treating the original RTL-activity power as gate-level
power.

To check the paper's access model against its archived WinoCNN RTL sweep and
re-evaluate its activity-based comparison, run from this repository root:

```bash
(cd ../iscas2027 && WINOCNN_DIR=../WinoCNN python3 scripts/access_model.py)
```

This needs the sibling paper checkout and its versioned `data/` files. It
performs consistency checks, then rewrites
`../iscas2027/data/access-model.csv`. The paper-wide
`python3 scripts/gen_tables.py` command also regenerates several paper
tables/figures and depends on the FastConv and SAURIA checkouts; use it from
`../iscas2027` only when you intend to update those generated paper files.

### Reproduce the functional reference

Run in a clean checkout/worktree so generated HLS files, stimuli, and EDA
outputs do not overwrite another experiment. From the repository root:

```bash
RUN=/tmp/winocnn-iscas2027
python3 asic_scripts/generate_winocnn_modulo_dataset.py \
  --height 32 --width 32 --cin 3 --cout 12 \
  --feature-bits 5 --weight-bits 4 --seed 1 --out "$RUN/dataset"

# Paper configuration: dom4=F(2x2,3x3), M=2, N=1, H2=2, W2=1, Q=1, B=1.
python3 asic_scripts/setcfg.py 4 2 1 2 1 0 1
python3 codegen/gen_systolic.py
make single_csim.out CFLAG="-fPIC -O2 -fsigned-char"
./single_csim.out 32 32 3 30 30 12 3 3 1 0 0 0 128 \
  "file:$RUN/dataset/feature.bin" random \
  "file:$RUN/dataset/weight.bin" compare . 3
```

The C-sim is the first gate: it must print `Not different!`. The binary dataset
is generated locally rather than committed; compare the generated
`provenance.json` with the archived provenance and require `Not different!`.
`setcfg.py` changes tracked configuration files, so preserve or discard those
changes deliberately after the run.

### Reproduce ASIC, gate-SDF, and power evidence

These stages require the licensed Vivado HLS, Xcelium, Genus/Joules setup and
TSMC 28 nm libraries available on the project's EDA host (Paxos). Run the
dataset-generation step in the same checkout on that host, or copy the two
generated `.bin` files there and update `RUN` to their location. On a clean
checkout with the same configuration and dataset, stage the input and the
C-model's expected output, then run the ordered flow:

```bash
# On the EDA host, load the site's corresponding Vivado/Cadence modules first.
bash asic_scripts/prepare_asic_stimulus.sh \
  32 32 3 30 30 12 3 3 1 0 0 0 128 \
  "$RUN/dataset/feature.bin" "$RUN/dataset/weight.bin" \
  testbench/stim/dom4 3
bash asic_scripts/run_asic_flow.sh all
```

`all` runs HLS, RTL-vs-golden checking, Genus synthesis, gate-level simulation
with SDF and another golden comparison, then activity-based Genus/Joules power.
Power is intentionally blocked unless the gate-SDF check passes. Check the
stage logs and `sim_asic/dom4/gate/rtl_golden_check.json`; a prepared directory
or an old report alone is not proof of a successful rerun. For tool setup,
stage-by-stage commands, and measurement boundaries, see
[`docs/simulation.md`](docs/simulation.md) and
[`docs/synthesis.md`](docs/synthesis.md).

The paper's WinoCNN table row uses gate-SDF activity power (10.6353 mW),
the mapped cell area, and active `ap_start`→`ap_done` latency (50,295 cycles at
2 ns = 100.59 µs); its 1,070 nJ is power × active latency. The archived Joules
report also gives about 1,091.5 nJ over the longer complete SHM window, which
includes reset/drain time. These are distinct energy windows. External and
inferred RAMs remain black boxes/excluded from synthesized area and power; the
reported memory power is not physical SRAM energy.

Do not take the paper's power from `power_flow_20261010/RESULTS.md`: that
earlier report is RTL-activity-based (10.2384 mW). The paper's 10.6353 mW comes
from the later validated gate-SDF run above. The paper row combines that later
activity/latency with cell area from the mapped synthesis package.

### Reproduce the access-count-only sweep

The separate sweep runs RTL only with randomized external memory contents and
counts SRAM transactions; it does not compare convolution outputs to a golden.
On a host with the generated HLS RTL and Xcelium available, run:

```bash
bash asic_scripts/run_sram_access_sweep.sh
```

Results go to `reports/sram_access_sweep_cin3_cout12_seed20261010/`. The
32×32–256×256 cases completed; 512×512 is unsupported by the current parameter
descriptor generator (see that report's README), and must not be presented as a
measured count. The paper's modeled image-size access curve is described in
`iscas2027/scripts/access_model.py`; keep it distinct from this RTL sweep.



