# WinoCNN modulo-generated dataset

Feature values use signed 5-bit modulo samples; weights use signed 4-bit modulo samples. See `provenance.json` for seed and exact ranges.

C-sim example (run from the WinoCNN repository root):

```bash
./single_csim.out 32 32 3 32 32 12 3 3 1 1 1 0 128 file:/sim/tarsio.onofrio/artifacts/wino-iscas2027-20261014-32x32-cin3-cout12/dataset/feature.bin random file:/sim/tarsio.onofrio/artifacts/wino-iscas2027-20261014-32x32-cin3-cout12/dataset/weight.bin compare . 3
```
