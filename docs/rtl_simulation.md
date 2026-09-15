# Simulação RTL do WinoCNN (fluxo ASIC) e instrumentação

Objetivo: rodar o RTL gerado pelo HLS com as memórias externas modeladas,
contar ciclos e tráfego de memória, e gerar um **SHM** para a análise de
potência no Genus.

## 1. Arquivos

| arquivo | papel |
|---|---|
| `testbench/tb_wino_asic.v` | testbench RTL: modela as RAMs externas (input/weight/output/params), carrega o estímulo, conta ciclos/leituras/escritas e gera SHM+VCD |
| `asic_scripts/bin2hex.py` | converte `input.bin`/`weight.bin`/`param.bin` (dumps do C-sim) em `*.hex` para `$readmemh` |
| `asic_scripts/run_sim_asic.sh` | runner Xcelium (`xrun`) que monta `sim_asic/` e gera `dut.shm` |
| `asic_scripts/script_cosim.tcl` | C/RTL co-simulation do HLS (`cosim_design`) |
| `testbench/stim/*.hex` | estímulo determinístico (teste `random random center`, 8×8×8 conv 3×3) |

## 2. Como rodar

```
# no paxos
module load cadence/xcelium/2303
bash asic_scripts/run_sim_asic.sh      # -> sim_asic/dut.shm, output_rtl*.hex
```

O runner copia também os `*_ram.dat` gerados pelo HLS: as RAMs internas
inferidas (`weight_feed_one_pg8j`, `wino_input_computqcK`) fazem
`$readmemh("./*_ram.dat")`; sem esses arquivos no CWD o RTL simula com memória
não inicializada e produz saída errada.

Latências do modelo de RAM externa (escalonadas pelo HLS, verificadas contra o
modelo `AESL_automem_*` do cosim):

| porta | latência |
|---|---|
| `input_DDR*` | 3 ciclos |
| `weight_DDR0` | 3 ciclos |
| `mem_params` | 1 ciclo |

## 3. Resultado (micro, 1 PE)

| métrica | valor |
|---|---|
| ciclos (`ap_start`→`ap_done`) | 34 122 |
| input reads | 88 |
| weight reads | 339 |
| param reads | 129 |
| output writes | 128 |
| max endereço de entrada/peso | 63 / 63 (sem out-of-range) |
| max endereço de saída | 127 |
| SHM | `sim_asic/dut.shm` (~0.9 MB) |

## 4. Validação funcional e potência

### 4.1 O RTL é funcionalmente correto

O testbench RTL reproduz o modelo C **exatamente** (128/128 palavras de saída,
comparando a união dos bancos ping-pong `output_DDR0`+`output_DDR1` com o
`autotvout_output_DDR0` do cosim). Duas ressalvas de infraestrutura, já
resolvidas no testbench:

- **`*_ram.dat`**: as RAMs internas fazem `$readmemh("./*_ram.dat")`; sem esses
  arquivos no CWD do sim o RTL parte de memória não inicializada e a saída fica
  errada. O runner agora os copia.
- **Espera pós-`ap_done`**: o write-back para a DDR **continua depois** de
  `ap_done`; parar cedo perde as últimas palavras. O testbench espera 200 ns
  após `ap_done` antes de encerrar (foi isso que gerou a falsa impressão de
  "escrita incompleta": 102 vs 128 palavras).

O C/RTL co-simulation do HLS **falha**, mas por um artefato conhecido: o
testbench C aponta `output_DDR0` e `output_DDR1` para o **mesmo buffer**,
enquanto o cosim os modela como memórias separadas. O testbench RTL usa
memórias separadas e valida o resultado.

### 4.2 Potência com atividade real (SHM)

`asic_scripts/power.tcl` lê o DB mapeado e anota a atividade do `sim_asic/dut.shm`
(anotação 100% em flops e portas primárias). Resultado (tt0p9v25c):

| categoria | mW |
|---|---:|
| register | 7.881 |
| logic | 0.184 |
| clock | 0.392 |
| memory / bbox | 0.000 |
| **total** | **8.457** |

Comparação: com `lp_default_probability 0.5` (sem estímulo) o relatório de
síntese dava 27.5 mW em tt — o número com SHM é o realista. Relatório em
`reports/genus/wino_systolic_top_power_shm_tt.rpt`.
