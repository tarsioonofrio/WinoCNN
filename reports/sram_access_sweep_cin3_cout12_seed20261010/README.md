# WinoCNN SRAM access-count sweep

RTL-only access-count test for square input images with `Cin=3`, `Cout=12`,
`3x3` kernel, stride 1, and padding 0. The parameter descriptor comes from the
WinoCNN C-sim `dump_param` path. Input and weight external memories contain
deterministic random 128-bit words; outputs are discarded. There is no golden
comparison and no claim of numerical validation.

The simulation used Xcelium 23.03 on the isolated HLS RTL copy. It is RTL
simulation without SDF; the external memories are behavioral arrays in the
testbench, not synthesized memory macros. Top-level read/write transactions
are counted per external SRAM port. HLS-inferred internal RAM models are
instrumented separately; per-instance counts are in each `*/sram_access_counts.json`
and per-module totals are in `*/internal_sram_totals.json`.
The TB also checked maximum read addresses: input accesses stayed within the
randomized input file (the last word was reached for every image size), and
weight accesses stayed at or below word 127 of the 4,096 randomized words. No
randomized input/weight read was out of bounds.
The parameter SRAM reports 129 reads: it contains the 128-word descriptor and
one additional read at address 128. That unprovided location was zero-filled,
matching the existing ASIC testbench's initialization behavior.

| Image | Status | Cycles | Input DDR0 reads | Input DDR1 reads | Weight DDR0 reads | Param reads | Output DDR0 writes | Output DDR1 writes |
|---:|:---|---:|---:|---:|---:|---:|---:|---:|
| 32x32 | PASS | 50,293 | 560 | 560 | 2,101 | 129 | 1,792 | 1,792 |
| 64x64 | PASS | 100,245 | 2,144 | 2,144 | 4,197 | 129 | 7,680 | 7,680 |
| 128x128 | PASS | 298,453 | 8,384 | 8,384 | 8,389 | 129 | 31,744 | 31,744 |
| 256x256 | PASS | 1,088,085 | 33,152 | 33,152 | 16,773 | 129 | 129,024 | 129,024 |
| 512x512 | Unsupported by current descriptor generation | — | — | — | — | — | — | — |

`512x512` aborts in `software/param.cpp:343` while generating the descriptor:
`maximum_row_step >= conv_desc.wino_output_tile_size` is false for this
configuration. Therefore there is no RTL access count for that case; it was not
silently extrapolated or forced through with a modified descriptor.

## Files

- `summary.csv`: external-port counts and cycles for the sweep.
- `<size>x<size>/sram_access_counts.tsv`: raw external and internal SRAM counts.
- `<size>x<size>/sram_access_counts.json`: normalized per-port/per-instance counts.
- `<size>x<size>/internal_sram_totals.json`: internal RAM totals grouped by module.
- `<size>x<size>/stimulus.json`, `input.hex`, `weight.hex`, `param.hex`: reproducible stimulus and exact descriptor.
- `<size>x<size>/xrun.log`: simulator output.
- `512x512/stimulus_generation.log`: failure evidence from descriptor generation.

To rerun on a host with the same HLS RTL and Xcelium installation, run
`bash asic_scripts/run_sram_access_sweep.sh` from the repository. No output
golden file is required.
