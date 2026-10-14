# Artefatos fora do Git

Local persistente no Paxos:

`/sim/tarsio.onofrio/artifacts/wino-iscas2027-20261014-32x32-cin3-cout12/`

Esse diretório preserva logs completos, estímulos, C-model golden, RTL HLS, waveform SHM, netlist, DB e SDF usados. Dados e artefatos EDA ficam fora do Git; os reports e métricas compactos deste run são versionados.

## Dados do workload

| Arquivo | Formato | Tamanho | SHA-256 |
|---|---|---:|---|
| `dataset/feature.bin` | binário | 3072 B | `2de6bd2fac9e2d5dd300e039666ee5cc6940b57f36df6b11d17368f39e13c99b` |
| `dataset/weight.bin` | binário | 324 B | `c87241c192b738508b285f78d0ea067022afad7e2a2a14b8fc82471464e3423e` |
| `stimulus/output_golden.bin` | binário | 32768 B | `be657f8d2933da5fd05142c010640ce88987a382b989728e34fb0bef8b97b432` |
| `stimulus/input.hex` | ASCII hex | 33792 B | `f029ceb83413ffec707a41489203486f3be4f37ee23a0cb1fa6c637effea9f1fc` |
| `stimulus/weight.hex` | ASCII hex | 4224 B | `046253a559323fc5bbb7325270fea08c4bcf054230ee4dbac4bd630bb371ddbd` |
| `stimulus/param.hex` | ASCII hex | 1152 B | `5a3e27d6d79b5b5d97dfa60abe7fd2ddad00240819892d743ff8c2255f7d62b0` |

Os `.bin` são binários; os `.hex` são texto ASCII, mas também dados gerados, então nenhum deles foi incluído no Git.

## Gate-level e síntese

| Artefato | Tamanho | SHA-256 |
|---|---:|---|
| `gate/dut.shm/dut.dsn` | 2,332,544 B | `cbf96d6022d4486530e42ead4cc83c342c02edd1372eee4a72a328b28ca16daa` |
| `gate/dut.shm/dut.trn` | 51,865,448 B | `b44f9ede92cecef960546fb90410cd0d4dd40f733c5a44910e3db3927e9903b0` |
| `gate/wino_systolic_top_analysis_view_0p90v_25c_captyp_nominal.sdf` | 39,394,749 B | `037b43bc413c83f57d6a70af1f7f5ba15d51f3b4be7d3ecd6ff9d07dc3eca163` |
| `gate/wino_systolic_top_logic_mapped.v` | 8,902,608 B | `84a3accfd76858e84f40d3b50e23b702e7f0b2e81f732776a21d93a960f4e606` |
| `gate/wino_systolic_top_logic_mapped.db` | 2,219,316 B | `cc0bda39da3ebdad9630e8789481e67d4fa38d0fa095d41b0dfcebd624402b1f` |
| `gate/sdf_log.log` | 426 B | `98850694315bf540d42aca06050c170c5c9a3b8215e5fb04ae7be4ba8ba46b4f` |
| `gate/xrun.log` | 243433 B | `8a61be7fb9c8b70f5c7efe79c1e2efcc96ce9217926a462680e32fc2c2865c39` |

Full stage logs (HLS, RTL sim, Genus, gate sim, Joules) are under `logs/`; generated HLS modules are under `hls/verilog/`. The archival copy is outside the repository, while the checkout also retains ignored build output from this run.
