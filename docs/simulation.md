# Simulação — C-sim, RTL e potência

Objetivo: validar funcionalmente o WinoCNN (C-sim) e medir **ciclos, tráfego de
memória e potência com atividade real** (RTL sim → SHM → Genus power).

Dois níveis:

| nível | o que valida | onde roda |
|---|---|---|
| **C-sim** | hardware (C) vs golden | local |
| **RTL sim** | RTL do HLS vs modelo C + SHM para potência | paxos (Xcelium) |

Documento irmão: **[`synthesis.md`](synthesis.md)** (HLS, Genus, black-box).
O relato das mudanças está em **[`history.md`](history.md)**.

---

## 1. Escolher o domínio

Vem de `WINO_DOMAIN_SIZE` em `src/wino_hw_config.h` (ver
[`synthesis.md`](synthesis.md) §1). Config micro validada:
`M=2, N=1, H2=2, W2=1, Q=1, B=1`.

```bash
python3 asic_scripts/setcfg.py 4 2 1 2 1 0 1   # dom4 = F(2x2,3x3)
python3 asic_scripts/setcfg.py 6 2 1 2 1 0 1   # dom6 = F(4x4,3x3)
python3 codegen/gen_systolic.py
```

Os artefatos são separados por domínio: `testbench/stim/dom<N>/`,
`sim_asic/dom<N>/`, `reports/genus/dom<N>/`. O RTL (HLS) é específico do
domínio — **re-rode o HLS** ao trocar (ver `synthesis.md` §3).

---

## 2. C-sim (validação funcional, local)

O C-sim compara o hardware (C) com o golden model. O modo `compare` imprime
`Not different!` e retorna 0 quando coincidem, ou 3 quando divergem.

```bash
make clean && make single_csim.out CFLAG="-fPIC -O1 -fsigned-char -fsanitize=address"

# protocolo (4 testes determinísticos)
for t in "one center" "one kernel_order" "order center" "random center"; do
  set -- $t
  ./single_csim.out 8 8 8 8 8 8 3 3 1 1 1 0 128 $1 random $2 compare . 3 || echo "FAIL $t"
done
```

Argumentos: `ih iw id  oh ow od  kh kw  stride  padh padw  relu  scale  input_gold  output_gold  weight_gold  dump_method  folder  use_kernel_size`.

O modo ASIC (`-DWINO_ASIC`) troca só os pragmas de memória; o C-sim ignora.

> **Nota de escopo.** O C-sim de `single_main` usa `scale_oback_int` fixo (não
> calculado); ele valida o datapath, não é um teste de acurácia para dados
> aleatórios de grande magnitude. O micro é funcional para `h/w` até 64×64
> (com **depth múltiplo de 8**; ver `micro_progress.md`).

---

## 3. Estímulo

O C-sim escreve os buffers DDR em `input.bin`, `weight.bin`, `param.bin`
(little-endian). O RTL os carrega via `$readmemh`, então
`asic_scripts/bin2hex.py` os converte:

```bash
python3 asic_scripts/bin2hex.py <dir>   # <dir>/*.bin -> <dir>/*.hex
```

Os `.hex` versionados ficam em `testbench/stim/dom<N>/` (teste
`random random center`, conv 8×8×8, kernel 3×3). Tamanhos: `input.hex` e
`weight.hex` = 64 × 128 bits; `param.hex` = 128 × 32 bits.

### 3.1 Dataset externo (lib `fast-convolution-rtl`)

O dataset pode vir da lib de referência em `../fast-convolution-rtl`. O `sim`
(2-D) dela passou a exportar, sob `<sim>/winocnn/`:

| arquivo | conteúdo |
|---|---|
| `feature.bin` | int8, `Cin*H*W`, layout `c*H*W + h*W + w` |
| `weight.bin` | int8, `Cout*Cin*kh*kw`, layout `(od*Cin+id)*kh*kw + ks` |
| `params.json` | descritor (dims, stride, pad, scale) |
| `README.md` | layout e como alimentar o WinoCNN |

Esses layouts são os do `software/buffer.cpp` do WinoCNN, então o
`single_main` carrega direto via o modo `file:`:

```bash
# 1) empacotar + validar contra o golden do WinoCNN
./single_csim.out <H> <W> <Cin> <Oh> <Ow> <Cout> 3 3 1 0 0 0 128 \
    file:<sim>/winocnn/feature.bin random file:<sim>/winocnn/weight.bin compare . 3
# 2) gerar o estímulo RTL (empacota o DDR e converte)
python3 asic_scripts/bin2hex.py .
```

Ressalvas:
- o `single_main` usa `scale_oback_int` fixo; pesos/entradas de magnitude alta
  saturam (a lib gera `sim int -r` com pesos em `0..Cout*Cin*9`, que estouram
  int8). Use magnitudes pequenas ou o fluxo completo com fatores de escala.
- **depth 3** (RGB) ainda esbarra na limitação pré-existente de `depth` não
  múltiplo de 8; use depth múltiplo de 8 por enquanto.

---

## 4. Testbench RTL (`asic_scripts/tb_wino_asic.v`)

Modela as quatro RAMs externas com o protocolo `ap_memory`, carrega o
estímulo, pulsa `ap_start`, espera `ap_done`, conta ciclos/acessos e escreve
um SHM para o Genus.

**Latência do modelo de RAM** (escalonada pelo HLS; verificada contra o modelo
`AESL_automem_*` do cosim):

| porta | latência |
|---|---|
| `input_DDR*` | 3 ciclos |
| `weight_DDR0` | 3 ciclos |
| `mem_params` | 1 ciclo |

Contadores de simulação (não sintetizados): ciclos, reads de entrada/peso/params,
writes de saída, endereços máximos e out-of-range.

---

## 5. Como rodar (host paxos)

```bash
ssh -p 8888 -i ~/.ssh/gaph tarsio.onofrio@paxos.inf.pucrs.br
cd ~/gaph/WinoCNN
source /etc/profile.d/modules.sh && module use /soft64/modulefiles
module load cadence/xcelium/2303
bash asic_scripts/run_sim_asic.sh
# -> sim_asic/dom<N>/dut.shm, output_rtl*.hex, out_writes.txt, dump.vcd
```

O runner deriva `<N>` de `src/wino_hw_config.h`, copia o estímulo de
`testbench/stim/dom<N>/` e os **`*_ram.dat`** gerados pelo HLS (as RAMs internas
fazem `$readmemh("./*_ram.dat")`; sem eles o RTL simula com memória não
inicializada e a saída sai errada).

---

## 6. Validação (RTL vs modelo C)

A união dos bancos ping-pong `output_DDR0` + `output_DDR1` bate com o
`autotvout_output_DDR0` do cosim do HLS em **128/128 palavras** (dom4 e dom6).

O cosim do HLS em si **falha** (rc=3), mas por um artefato conhecido: o
testbench C aponta `output_DDR0` e `output_DDR1` para o **mesmo buffer**,
enquanto o cosim os modela como memórias separadas. O testbench RTL usa
memórias separadas e por isso é a referência válida.

---

## 7. SHM e potência

`asic_scripts/power.tcl` recria um MMMC de canto `tt`, lê o DB mapeado
(`reports/genus/dom<N>/gate_level/...`) e anota a atividade do SHM:

```bash
module load cadence/genus/211
genus -f asic_scripts/power.tcl
# -> reports/genus/dom<N>/wino_systolic_top_power_shm_tt.rpt
```

A anotação cobre ~100 % dos flops e portas primárias. Resultado (tt0p9v25c):

| categoria | dom4 | dom6 |
|---|---:|---:|
| register | 7.881 mW | ~27.2 mW |
| logic | 0.184 mW | ~0.41 mW |
| clock | 0.392 mW | — |
| memory / bbox | 0.000 mW | 0.000 mW |
| **total** | **8.457 mW** | **28.36 mW** |

Comparação: sem estímulo (`lp_default_probability 0.5`) o relatório de síntese
dava 27.5 mW (dom4) e 72.6 mW (dom6) em tt — o número com SHM é o realista.

---

## 8. Resultados (micro, 1 PE, conv 8×8×8)

| métrica | dom4 (F(2×2,3×3)) | dom6 (F(4×4,3×3)) |
|---|---:|---:|
| ciclos (`ap_start`→`ap_done`) | 34 122 | 75 419 |
| input reads | 88 | 88 |
| weight reads | 339 | 516 |
| param reads | 129 | 129 |
| output writes | 128 | 128 |
| potência com SHM (tt) | 8.46 mW | 28.36 mW |
| SHM | `sim_asic/dom4/dut.shm` | `sim_asic/dom6/dut.shm` |

---

## 9. Armadilhas

1. **`*_ram.dat` ausentes** → RAMs internas não inicializadas → saída errada. O
   runner os copia; não rode o `xrun` à mão sem eles.
2. **Latência de RAM errada** (usar 1 ciclo em tudo) → o DUT lê dados velhos.
   Entrada/peso = 3, params = 1.
3. **O write-back continua depois de `ap_done`.** Parar cedo perde as últimas
   palavras (a falsa "escrita incompleta", 102 vs 128). O testbench espera
   **2000 ns** após `ap_done` antes de encerrar (o domínio 6 precisou; o valor
   maior também cobre o dom4).
4. **Nunca confunda** `reports/genus/dom<N>/` (síntese) com `sim_asic/dom<N>/`
   (simulação) — são domínios diferentes de artefato.
5. **`make clean` apaga `license.txt`** — restaure antes de commitar.
