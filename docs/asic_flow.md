# Fluxo ASIC — wrapper de memória síncrona e síntese

Objetivo: preparar o WinoCNN para a **comparação de PPA com o acelerador de
referência (FastConv)** usando a mesma metodologia ASIC — núcleo sintetizado no
Genus, com as **memórias externas black-box** (para comparar lógica com lógica).

Estado: **fluxo completo executado no paxos**. HLS ASIC gera o RTL e o Genus
21.1 fecha a síntese com as memórias black-box, produzindo
`reports/genus/dom<N>/*.rpt` (área, gates, timing, potência, clock gating), onde
`<N>` é o domínio de Winograd (4 = F(2×2,3×3), 6 = F(4×4,3×3)). Os números
da configuração micro (1 PE) estão na seção 5.

---

## 1. O que muda em relação ao fluxo FPGA

O datapath não muda. A única diferença é a **interface de memória externa**:

| fluxo | interface | macro | uso |
|---|---|---|---|
| FPGA / Zynq (padrão) | `m_axi` (AXI master, burst, offset slave) | `WINO_MEM_IF_AXI` | `run_hls.sh` / `hw_scripts/script.tcl` |
| **ASIC** (`-DWINO_ASIC`) | `ap_memory` (RAM síncrona simples) | `WINO_MEM_IF_AXI` / `WINO_MEM_IF_PORT` | `asic_scripts/script_asic.tcl` |

Com `ap_memory` o RTL exportado tem portas simples **address / data / ce / we**
(leitura síncrona, latência fixa), sem protocolo AXI — que é o que permite
black-boxar as RAMs e mapeá-las às macros do PDK no Genus.

## 2. Arquivos

| arquivo | papel |
|---|---|
| `src/wino_mem_if.h` | abstração da interface (`WINO_MEM_IF_AXI`, `WINO_MEM_IF_PORT`); `WINO_ASIC` escolhe AXI vs `ap_memory` |
| `src/wino.cpp` | top `wino_systolic_top`: pragmas dos ports via `WINO_MEM_IF_AXI` |
| `src/wino_buffer.cpp`, `src/wino_IO.cpp` | ports internos via `WINO_MEM_IF_PORT` |
| `asic_scripts/script_asic.tcl` | HLS com `-DWINO_ASIC`; exporta RTL Verilog |
| `asic_scripts/wino_sram_bb.v` | black-box da SRAM síncrona de 1 porta |
| `asic_scripts/genus_core.tcl` | esqueleto de síntese no Genus (área/FF/Fmax/potência) |

## 3. Portas de memória do topo

`wino_systolic_top` expõe (larguras/Profundidades):

| port | tipo | profundidade | conteúdo |
|---|---|---|---|
| `input_DDR0`, `input_DDR1` | `ap_uint<128>` | 524288 | feature map de entrada |
| `weight_DDR0` | `ap_uint<128>` | 1179648 | pesos + bias |
| `output_DDR0`, `output_DDR1` | `ap_uint<ODDR_WIDTH*BATCH_SIZE*OUT_PORT_BATCH_NUM>` | 524288 | feature map de saída |
| `mem_params` | `ap_int<32>` | 65535 | descritor de convolução |

As portas concretas dependem da configuração: no micro (`WINO_WIDTH=1`) o macro
`WEIGHT_PORTS_DECLARE` resolve para uma **única** porta `weight_DDR0` (as
versões com 2/4 portas ficam ativas em configurações maiores). No fluxo ASIC
todas viram RAMs síncronas (`ap_memory`). O `s_axilite register port=return` é
removido (não existe em ASIC).

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
vivado_hls -f asic_scripts/script_asic.tcl
# gera HLS_asic/solution_asic/impl/verilog/*.v
```

### 4.3 Genus — mesma metodologia do FastConv

O host com Genus é o **paxos** (`paxos.inf.pucrs.br`, porta 8888), onde o
FastConv foi sintetizado. O WinoCNN reusa **exatamente** o mesmo cenário:

- PDK **TSMC 28 nm** `tcbn28hpcplusbwp30p140` (BWP30P140), via MMMC
  (`asic_scripts/mmmc_tsmc_28_bv.tcl`, copiado do template do FastConv);
- 3 corners: `ssg0p81v125c` (setup) / `tt0p9v25c` / `ffg0p99vm40c` (hold);
- clock **500 MHz (2 ns)** e as mesmas restrições de driving cell / load
  (`asic_scripts/constraints.sdc`);
- `syn_generic` → `syn_map` → `syn_opt` + relatórios de área/timing/potência.

No paxos:

```
module load vivado_hls && bash asic_scripts/run_asic_flow.sh hls
module load genus      && bash asic_scripts/run_asic_flow.sh genus
# ou, em uma sessão com ambos: bash asic_scripts/run_asic_flow.sh all
```

Saída: `reports/genus/dom<N>/wino_systolic_top_*.rpt` (área, timing, potência,
gates, qor), com `<N>` = domínio de Winograd.

## 5. Black-box das memórias e constraints

O HLS infere as RAMs internas como módulos Verilog próprios. O `genus_core.tcl`
**não lê** os arquivos que declaram memória (`ram_style`), de modo que essas
instâncias ficam como *black boxes* (com `hdl_error_on_blackbox false`) e não
são sintetizadas como bancos de flip-flops. Na config micro são 5 módulos:

| módulo HLS | conteúdo | instâncias | tamanho |
|---|---|---|---|
| `wino_systolic_topbwn` | output buffers (ping-pong) | 64 | 1024 × 9 |
| `wino_systolic_topcyx` | bias buffers | 16 | 1024 × 16 |
| `wino_input_computqcK` | input buffer | — | 4096 × 16 |
| `weight_feed_one_pg8j` | weight buffer | — | 1024 × 44 |
| `load_params_parambkb` | RAM de parâmetros | — | 128 × 32 |

Isso satisfaz o requisito "memórias não sintetizadas": apenas lógica (AddrGen,
controle, datapath, pipeline) entra na área. Os relatórios de potência confirmam
`memory = 0` e `bbox = 0`.

`constraints.sdc` foi adaptado ao topo HLS:

- clock `ap_clk` a **2 ns** e `ap_rst` como `false_path` (o topo HLS usa
  `ap_clk`/`ap_rst`, não `clk`/`reset`);
- `set_input_delay`/`set_output_delay` aplicados **somente às portas de memória**;
  as portas de handshake `ap_start`/`ap_done`/`ap_idle`/`ap_ready` ficam de fora.
  Caso contrário cria-se um caminho espúrio `ap_start → ap_idle` (datapath de
  16 ps) que mascara o caminho crítico real.

## 6. Resultado da síntese (micro, 1 PE)

Config: `WINO_DOMAIN_SIZE=4`, `WINO_HEIGHT=2`, `WINO_WIDTH=1`, `WINO_H2=2`,
`WINO_W2=1`, `Q=1`, `BATCH_SIZE=1` → 1 PE.

Ferramentas: Vivado HLS 2019.2 (RTL, 46 `.v`) → Genus 21.12 no paxos,
TSMC 28 nm BWP30P140, corner lento `ssg0p81v125c`, 2 ns.

| métrica | valor |
|---|---|
| cell area | 64 812.9 µm² |
| net area | 22 219.1 µm² |
| total area | 87 032.0 µm² |
| sequential instances | 19 250 |
| flip-flops | 19 070 (88.8 % com clock gating) |
| combinational instances | 31 138 |
| leaf instances | 50 388 |
| slack (setup, 2 ns) | **+39 ps** (MET) |
| Fmax estimado | ≈ 510 MHz |
| potência (slow / typ / fast) | 27.28 / 27.47 / 33.30 mW |
| runtime Genus | ≈ 879 s |

Caminho crítico real: multiplicador `wino_systolic_topeOg_MulnS_0` em
`input_feed_undercons` (datapath 1939 ps), não o datapath do PE. A área é
dominada por `wino_input_compute` (~48.7k µm², 75 %), majoritariamente
AddrGen/controle e registradores de pipeline — reflexo do estilo HLS.

Relatórios completos em `reports/genus/dom<N>/*.rpt`. Os artefatos grandes
(`dom<N>/gate_level/`: netlist `.v`, `.db`, `.sdf`) não são versionados.

> Nota: os 27 mW acima usam `lp_default_probability 0.5` e **sem estímulo**.
> Com o SHM da simulação RTL a potência real é **8.46 mW** em tt0p9v25c — ver
> `docs/rtl_simulation.md` e
> `reports/genus/dom4/wino_systolic_top_power_shm_tt.rpt`.

## 7. O que falta

- **Instrumentação de tráfego**: os contadores já existem no testbench RTL
  (reads/writes/ciclos); falta levá-los para o fluxo oficial.
- **Macros SRAM do PDK**: hoje as memórias são black-box (área excluída). Para
  uma variante "com memória", mapear às macros do PDK.
- **Paridade com o FastConv**: aplicar exatamente a mesma metodologia (mesma
  lib, 2 ns, mesmo critério de black-box) e montar a tabela de PPA.

## 8. Definição de pronto para a comparação

- [x] HLS ASIC roda e exporta RTL sem erros.
- [x] Genus sintetiza o core com as memórias black-box.
- [x] Relatórios de área/FF/Fmax/potência gerados.
- [x] Testbench RTL + SHM; potência com atividade real (8.46 mW tt).
- [ ] Instrumentação de tráfego (reads/writes/cycles).
- [ ] Mesma metodologia aplicada ao FastConv (mesma lib, mesmo clock, mesmo
      critério de black-box) para uma comparação justa.
