# WinoCNN modulo-generated dataset

Feature values use signed 5-bit modulo samples; weights use signed 4-bit modulo samples. See `provenance.json` for seed and exact ranges.

C-sim example (run from the WinoCNN repository root):

```bash
./single_csim.out 32 32 3 30 30 12 3 3 1 0 0 0 128 file:/home/tarsio/gaph/WinoCNN/reports/winocnn_modulo5_4_seed1_32x32_cin3_cout12/feature.bin random file:/home/tarsio/gaph/WinoCNN/reports/winocnn_modulo5_4_seed1_32x32_cin3_cout12/weight.bin compare . 3
```
