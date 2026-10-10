# WinoCNN modulo-generated dataset

Feature values use the WinoCNN-style `random()%256` byte pattern, read as signed int8. Weights use `random()%128-64`, signed int7. See `provenance.json` for seed and layouts.

C-sim example (run from the WinoCNN repository root):

```bash
./single_csim.out 32 32 3 30 30 12 3 3 1 0 0 0 128 file:/home/tarsio/gaph/WinoCNN/reports/winocnn_modulo8_7_seed1_32x32_cin3_cout12/feature.bin random file:/home/tarsio/gaph/WinoCNN/reports/winocnn_modulo8_7_seed1_32x32_cin3_cout12/weight.bin compare . 3
```
