# Simulação RTL do WinoCNN (fluxo ASIC) e instrumentação

Objetivo: rodar o RTL gerado pelo HLS com as memórias externas modeladas,
contar ciclos e tráfego de memória, e gerar um **SHM** para a análise de
potência no Genus.

## 1. Arquivos

| arquivo | papel |
|---|---|
| `testbench/tb_wino_asic.v` | testbench RTL: modela as RAMs externas (input/weight/output/params), carrega o estímulo, conta ciclos/leituras/escritas e gera SHM+VCD |
| `hw_scripts/bin2hex.py` | converte `input.bin`/`weight.bin`/`param.bin` (dumps do C-sim) em `*.hex` para `$readmemh` |
| `hw_scripts/run_sim_asic.sh` | runner Xcelium (`xrun`) que monta `sim_asic/` e gera `dut.shm` |
| `hw_scripts/script_cosim.tcl` | C/RTL co-simulation do HLS (`cosim_design`) |
| `testbench/stim/*.hex` | estímulo determinístico (teste `random random center`, 8×8×8 conv 3×3) |

## 2. Como rodar

```
# no paxos
module load cadence/xcelium/2303
bash hw_scripts/run_sim_asic.sh      # -> sim_asic/dut.shm, output_rtl*.hex
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
| output writes | 102 |
| max endereço de entrada/peso | 63 / 63 (sem out-of-range) |
| max endereço de saída | 114 |
| SHM | `sim_asic/dut.shm` (~0.9 MB) |

## 4. Achado: o RTL do micro não é funcionalmente equivalente ao C

O C/RTL co-simulation do HLS **falha** (`C TB post check ... return value '3'`).
Além disso, o testbench RTL mostra que o hardware escreve **102** palavras de
saída (até o endereço 114), enquanto o modelo C produz **128** palavras (8×8×8,
4 canais por palavra de 32 bits). Em termos de valores não nulos, o RTL escreve
46 palavras contra 96 do modelo C.

Ou seja: a configuração micro (1 PE, Q=1, B=1) passa o **C-sim**, mas o **RTL
gerado pelo HLS não reproduz** o resultado — há escrita de saída incompleta.

> Isso não invalida o C-sim: são níveis diferentes. Mas **impede** usar a
> config micro para PPA enquanto o RTL não for corrigido, pois a atividade
> simulada (e portanto a potência/tráfego) não corresponde ao algoritmo.

### Próximos passos sugeridos

1. Depurar o RTL do micro contra o C: comparar o conteúdo dos `output_buffer`
   internos e o caminho de write-back (`write_output_row`), focando em
   `winoPEB_CORN` / pack-unpack B=1 (área já mexida no histórico micro).
2. Alternativa: validar a config **original** (M=4/N=2/Q=4/B=2) no cosim; se
   ela passar, usá-la como baseline RTL e derivar o micro a partir dela.
3. Só então rodar `read_stimulus` do SHM no Genus para potência.
