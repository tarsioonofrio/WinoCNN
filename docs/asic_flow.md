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

### 4.3 Genus (onde houver Genus + PDK)

Preencher os caminhos das bibliotecas em `hw_scripts/genus_core.tcl` e rodar:

```
genus -f hw_scripts/genus_core.tcl
# reports/area.rpt, timing.rpt, power.rpt, qor.rpt
```

## 5. Hipóteses e o que falta

- **PDK**: os caminhos das libs (std cell, IO, SRAM) são placeholders.
- **Macros de memória**: `wino_sram_bb.v` é um stub vazio; deve ser substituído
  pela macro SRAM do PDK com o mesmo port list (ou fazer bind via biblioteca).
- **Constantes de timing**: os delays de I/O e a incerteza de clock precisam ser
  ajustados ao PDK.
- **Instrumentação de tráfego**: contadores de leitura/escrita por porta ainda
  não foram adicionados (útil para validar o modelo de memória e a banda).
- **Síntese real**: não executada aqui (sem ferramentas).

## 6. Definição de pronto para a comparação

- [ ] HLS ASIC roda e exporta RTL sem erros.
- [ ] Genus sintetiza o core com as memórias black-box.
- [ ] Relatórios de área/FF/Fmax/potência gerados.
- [ ] Mesma metodologia aplicada ao FastConv (mesma lib, mesmo clock, mesmo
      critério de black-box) para uma comparação justa.
