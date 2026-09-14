# Fluxo ASIC — wrapper de memória síncrona e síntese

Objetivo: preparar o WinoCNN para a **comparação de PPA com o acelerador de
referência (FastConv)** usando a mesma metodologia ASIC — núcleo sintetizado no
Genus, com as **memórias externas black-box** (para comparar lógica com lógica).

Estado: **preparação concluída e verificada em C-sim**. A síntese HLS/Genus em si
não foi executada neste ambiente (não há `vivado_hls`/`vitis_hls`/`genus`
instalados); os scripts estão prontos para rodar onde as ferramentas existirem.

---

## 1. O que muda em relação ao fluxo FPGA

O datapath não muda. A única diferença é a **interface de memória externa**:

| fluxo | interface | macro | uso |
|---|---|---|---|
| FPGA / Zynq (padrão) | `m_axi` (AXI master, burst, offset slave) | `WINO_MEM_IF_AXI` | `run_hls.sh` / `hw_scripts/script.tcl` |
| **ASIC** (`-DWINO_ASIC`) | `ap_memory` (RAM síncrona simples) | `WINO_MEM_IF_AXI` / `WINO_MEM_IF_PORT` | `hw_scripts/script_asic.tcl` |

Com `ap_memory` o RTL exportado tem portas simples **address / data / ce / we**
(leitura síncrona, latência fixa), sem protocolo AXI — que é o que permite
black-boxar as RAMs e mapeá-las às macros do PDK no Genus.

## 2. Arquivos

| arquivo | papel |
|---|---|
| `src/wino_mem_if.h` | abstração da interface (`WINO_MEM_IF_AXI`, `WINO_MEM_IF_PORT`); `WINO_ASIC` escolhe AXI vs `ap_memory` |
| `src/wino.cpp` | top `wino_systolic_top`: pragmas dos ports via `WINO_MEM_IF_AXI` |
| `src/wino_buffer.cpp`, `src/wino_IO.cpp` | ports internos via `WINO_MEM_IF_PORT` |
| `hw_scripts/script_asic.tcl` | HLS com `-DWINO_ASIC`; exporta RTL Verilog |
| `hw_scripts/wino_sram_bb.v` | black-box da SRAM síncrona de 1 porta |
| `hw_scripts/genus_core.tcl` | esqueleto de síntese no Genus (área/FF/Fmax/potência) |

## 3. Portas de memória do topo

`wino_systolic_top` expõe (larguras/Profundidades):

| port | tipo | profundidade | conteúdo |
|---|---|---|---|
| `input_DDR0`, `input_DDR1` | `ap_uint<128>` | 524288 | feature map de entrada |
| `weight_DDR0..3` | `ap_uint<128>` | 1179648 | pesos + bias |
| `output_DDR0`, `output_DDR1` | `ap_uint<ODDR_WIDTH*BATCH_SIZE*OUT_PORT_BATCH_NUM>` | 524288 | feature map de saída |
| `mem_params` | `ap_int<32>` | 65535 | descritor de convolução |

No fluxo ASIC todas viram RAMs síncronas (`ap_memory`). O `s_axilite register
port=return` é removido (não existe em ASIC).

## 4. Como rodar

### 4.1 Verificação em C-sim (este ambiente)

```
# modo AXI (padrão) — deve continuar passando
make clean && make single_csim.out CFLAG="-fPIC -O1 -fsigned-char"
./single_csim.out 8 8 8 8 8 8 3 3 1 1 1 0 128 one random center compare . 3

# modo ASIC (troca apenas os pragmas; C-sim ignora)
make clean && make single_csim.out CFLAG="-fPIC -O1 -fsigned-char -DWINO_ASIC"
./single_csim.out 8 8 8 8 8 8 3 3 1 1 1 0 128 one random center compare . 3
```

Ambos os modos compilam e passam os testes do protocolo.

### 4.2 HLS → RTL (onde houver Vivado HLS)

```
vivado_hls -f hw_scripts/script_asic.tcl
# gera HLS_asic/solution_asic/impl/verilog/*.v
```

### 4.3 Genus — mesma metodologia do FastConv

O host com Genus é o **paxos** (`paxos.inf.pucrs.br`, porta 8888), onde o
FastConv foi sintetizado. O WinoCNN reusa **exatamente** o mesmo cenário:

- PDK **TSMC 28 nm** `tcbn28hpcplusbwp30p140` (BWP30P140), via MMMC
  (`hw_scripts/mmmc_tsmc_28_bv.tcl`, copiado do template do FastConv);
- 3 corners: `ssg0p81v125c` (setup) / `tt0p9v25c` / `ffg0p99vm40c` (hold);
- clock **500 MHz (2 ns)** e as mesmas restrições de driving cell / load
  (`hw_scripts/constraints.sdc`);
- `syn_generic` → `syn_map` → `syn_opt` + relatórios de área/timing/potência.

No paxos:

```
module load vivado_hls && bash hw_scripts/run_asic_flow.sh hls
module load genus      && bash hw_scripts/run_asic_flow.sh genus
# ou, em uma sessão com ambos: bash hw_scripts/run_asic_flow.sh all
```

Saída: `reports/genus/wino_area.rpt`, `wino_timing_*.rpt`, `wino_power_*.rpt`,
`wino_qor.rpt`.

## 5. Hipóteses e o que falta

- **Ferramentas/PDK só no paxos**: este ambiente de autoria não tem
  `vivado_hls`/`vitis_hls`/`genus` nem `/pdk`. O acesso SSH não-interativo ao
  paxos foi negado (`Permission denied (publickey)`), então a síntese precisa
  ser disparada lá por quem tem credencial.
- **Macros de memória internas**: as RAMs inferidas pelo HLS
  (`input_buffer`, `out_buffer`, `weight_buff`) viram registradores por padrão.
  Para comparar lógica com lógica, black-boxá-las e mapear às macros SRAM do
  PDK (linha comentada em `genus_core.tcl`). `wino_sram_bb.v` é o stub.
- **Instrumentação de tráfego**: contadores de leitura/escrita por porta ainda
  não foram adicionados.
- **Síntese real**: não executada (sem ferramentas no ambiente de autoria).
- **Paridade com o FastConv**: usar a mesma lib, mesmo clock (2 ns) e mesmo
  critério de black-box — o script já foi montado assim.

## 6. Definição de pronto para a comparação

- [ ] HLS ASIC roda e exporta RTL sem erros.
- [ ] Genus sintetiza o core com as memórias black-box.
- [ ] Relatórios de área/FF/Fmax/potência gerados.
- [ ] Mesma metodologia aplicada ao FastConv (mesma lib, mesmo clock, mesmo
      critério de black-box) para uma comparação justa.
