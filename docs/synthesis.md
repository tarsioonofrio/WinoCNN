# Síntese ASIC — HLS → Genus

Objetivo: preparar o WinoCNN para **comparação de PPA com o acelerador de
referência (FastConv)** usando a mesma metodologia ASIC — o núcleo sintetizado
no Genus, com as **memórias externas black-box** (comparar lógica com lógica).

Fluxo:

```
src/wino_hw_config.h  →  codegen/gen_systolic.py  →  wino_systolic_kernel.cpp
        │
        ▼
   Vivado HLS (script_asic.tcl, -DWINO_ASIC)  →  HLS_asic/.../verilog/*.v
        │
        ▼
   Genus (genus_core.tcl, TSMC28 BWP30P140, 2 ns)  →  reports/genus/dom<N>/
```

Documento irmão: **[`simulation.md`](simulation.md)** (C-sim, RTL sim, SHM,
potência). O relato de todas as mudanças está em
**[`history.md`](history.md)**.

---

## 1. Escolher o domínio

Toda a configuração vem de **um macro**. O domínio de Winograd é
`WINO_DOMAIN_SIZE`:

| `WINO_DOMAIN_SIZE` | tile | saída | multiplicadores (domínio²) |
|---|---|---|---|
| 4 | F(2×2,3×3) | 2×2 | 16 |
| 6 | F(4×4,3×3) | 4×4 | 36 |

Config micro validada (1 PE): `M=2, N=1, H2=2, W2=1, Q=1, B=1`.

```bash
# helper do repo (args: DOMAIN M N H2 W2 QBIT B)
python3 asic_scripts/setcfg.py 4 2 1 2 1 0 1   # dom4 = F(2x2,3x3)
python3 asic_scripts/setcfg.py 6 2 1 2 1 0 1   # dom6 = F(4x4,3x3)

# equivalente manual: editar src/wino_hw_config.h (WINO_DOMAIN_SIZE) e
# src/wino_macro.h (BATCH_SIZE)

# SEMPRE regenerar o kernel:
python3 codegen/gen_systolic.py
```

> O HLS precisa ser **re-rodado** ao trocar de domínio — o RTL gerado é
> específico do domínio. Os scripts derivam `<N>` de `src/wino_hw_config.h`
> automaticamente, então dom4 e dom6 nunca se sobrescrevem.

---

## 2. Interface de memória ASIC (`-DWINO_ASIC`)

O datapath não muda; só a interface de memória externa:

| fluxo | interface | macro | uso |
|---|---|---|---|
| FPGA / Zynq (padrão) | `m_axi` (AXI master) | `WINO_MEM_IF_AXI` | `run_hls.sh` / `hw_scripts/script.tcl` |
| **ASIC** (`-DWINO_ASIC`) | `ap_memory` (RAM síncrona) | `WINO_MEM_IF_AXI` / `WINO_MEM_IF_PORT` | `asic_scripts/script_asic.tcl` |

Com `ap_memory` o RTL tem portas simples **address / data / ce / we** (leitura
síncrona, latência fixa), sem protocolo AXI — que é o que permite black-boxar
as RAMs no Genus.

Arquivos: `src/wino_mem_if.h` (abstração), `src/wino.cpp` (top),
`src/wino_buffer.cpp` / `src/wino_IO.cpp` (portas internas),
`asic_scripts/wino_sram_bb.v` (stub de SRAM).

### Portas do topo `wino_systolic_top`

| port | tipo | profundidade | conteúdo |
|---|---|---|---|
| `input_DDR0`, `input_DDR1` | `ap_uint<128>` | 524 288 | feature map de entrada |
| `weight_DDR0` | `ap_uint<128>` | 1 179 648 | pesos + bias |
| `output_DDR0`, `output_DDR1` | 32 bits | 524 288 | feature map de saída |
| `mem_params` | `ap_int<32>` | 65 535 | descritor de convolução |

No micro (`WINO_WIDTH=1`) o macro `WEIGHT_PORTS_DECLARE` colapsa para uma única
porta `weight_DDR0`. O `s_axilite register port=return` é removido no ASIC.

---

## 3. HLS

`asic_scripts/script_asic.tcl`:

```
vivado_hls -f asic_scripts/script_asic.tcl
# gera HLS_asic/solution_asic/impl/verilog/*.v (top wino_systolic_top.v)
```

O `export_design -rtl verilog` é suficiente (o `csynth_design` já escreve o
RTL); o empacotamento `ip_catalog` foi removido por falhar no HLS 2019.2 com o
bug `core_revision`.

---

## 4. Genus

`asic_scripts/genus_core.tcl` segue o template do FastConv
(`logical_synthesis_body.tcl`):

- `read_mmmc asic_scripts/mmmc_tsmc_28_bv.tcl` — TSMC 28 nm
  `tcbn28hpcplusbwp30p140`, 3 corners (`ssg0p81v125c` setup, `tt0p9v25c`,
  `ffg0p99vm40c` hold);
- `set_multi_cpu_usage -local_cpu $env(WINO_CPU)` (default 14);
- `syn_generic` → `syn_map` → `syn_opt`;
- relatórios por view (área, gates, timing, potência) + `write_hdl`/`write_sdf`/`write_db`.

### Black-box das memórias (obrigatório)

O HLS infere as RAMs internas como módulos com `(* ram_style = "block" *)`. Se
o Genus as sintetiza, viram bancos de flip-flops e a área passa a ser memória.
O script **não lê** os arquivos que contêm `ram_style`, deixando-os como
referências não resolvidas (`hdl_error_on_blackbox false`). Na config micro são
cinco: `load_params_parambkb`, `weight_feed_one_pg8j`,
`wino_input_computqcK`, `wino_systolic_topbwn` (64×), `wino_systolic_topcyx`
(16×). A potência confirma `memory = 0` e `bbox = 0`.

### Constraints

`asic_scripts/constraints.sdc`:

- clock `ap_clk` a **2 ns** (500 MHz) e `ap_rst` como `false_path` — o topo HLS
  usa `ap_clk`/`ap_rst`, não `clk`/`reset`;
- `set_input_delay`/`set_output_delay` **somente nas portas de memória**; as
  portas de handshake `ap_start`/`ap_done`/`ap_idle`/`ap_ready` ficam de fora,
  senão criam um caminho espúrio `ap_start → ap_idle` (16 ps) que mascara o
  caminho crítico real.

---

## 5. Como rodar (host paxos)

O host com Genus/PDK é o **paxos** (`paxos.inf.pucrs.br`, porta 8888). Sincronize
o repo local antes (não há FS compartilhado).

```bash
ssh -p 8888 -i ~/.ssh/gaph tarsio.onofrio@paxos.inf.pucrs.br
cd ~/gaph/WinoCNN
source /etc/profile.d/modules.sh && module use /soft64/modulefiles

module load xilinx/vivado/2019.2
vivado_hls -f asic_scripts/script_asic.tcl        # ou: bash asic_scripts/run_asic_flow.sh hls

module load cadence/genus/211
genus -f asic_scripts/genus_core.tcl              # ou: bash asic_scripts/run_asic_flow.sh genus
```

Saída em **`reports/genus/dom<N>/wino_systolic_top_*.rpt`** (área, gates,
timing, potência, qor, clock gating). Os artefatos grandes
(`dom<N>/gate_level/`: netlist `.v`, `.db`, `.sdf`) **não** são versionados.

---

## 6. Resultados (micro, 1 PE)

Ferramentas: Vivado HLS 2019.2 → Genus 21.12, TSMC 28 nm BWP30P140, 2 ns.

| métrica | dom4 (F(2×2,3×3)) | dom6 (F(4×4,3×3)) |
|---|---|---|
| cell area | 64 812.9 µm² | 147 680.1 µm² |
| net area | 22 219.1 µm² | 46 606.8 µm² |
| total area | 87 032.0 µm² | 194 286.8 µm² |
| flip-flops | 19 070 | 42 095 |
| combinational instances | 31 138 | 63 777 |
| leaf instances | 50 388 | 106 151 |
| slack (setup, 2 ns) | **+39 ps** (MET) | **+1 ps** (MET) |
| Fmax estimado | ≈ 510 MHz | ≈ 500 MHz |
| potência sem estímulo (slow/typ/fast) | 27.3 / 27.5 / 33.3 mW | 70.2 / 72.6 / 87.6 mW |
| runtime Genus | ≈ 879 s | ≈ 1550 s |

O caminho crítico real (dom4) não é o PE: é o multiplicador
`wino_systolic_topeOg_MulnS_0` em `input_feed_undercons` (datapath 1939 ps). A
área é dominada por `wino_input_compute` (~75 %), majoritariamente
AddrGen/controle e registradores de pipeline — reflexo do estilo HLS. O domínio
6 cresce ~2.3× e fica no limite de 2 ns.

> A potência **sem estímulo** usa `lp_default_probability 0.5`. Com atividade
> real (SHM) o dom4 mede 8.46 mW e o dom6 28.36 mW em tt0p9v25c — ver
> [`simulation.md`](simulation.md) §7.

---

## 7. Armadilhas

1. **`_Pragma` não aceita concatenação de literais** — o macro monta o texto com
   `WINO_STR_`/`WINO_XSTR_`, e os parâmetros do macro **não** podem se chamar
   `port`/`bundle`/`depth` (renomeados para `p`/`b`/`d`).
2. **`ap_memory` precisa de tamanho em tempo de compilação** — no ASIC os
   buffers do topo viram arrays (em C++ decaem para ponteiro; o testbench não muda).
3. **Genus lento** — sem `set_multi_cpu_usage` usa ~3 threads; sempre passe
   `WINO_CPU` (paxos: 14–28).
4. **Export de IP do HLS 2019.2** falha (`core_revision`); use só
   `export_design -rtl verilog`.
5. **`make clean` apaga `license.txt`** — restaure com
   `git checkout HEAD -- license.txt` antes de commitar.

---

## 8. O que falta

- **Macros SRAM do PDK**: hoje as memórias são black-box (área excluída). Para
  uma variante "com memória", mapear às macros do PDK.
- **Paridade com o FastConv**: aplicar exatamente a mesma metodologia (mesma
  lib, 2 ns, mesmo critério de black-box) e montar a tabela de PPA.

## 9. Definição de pronto

- [x] HLS ASIC roda e exporta RTL.
- [x] Genus sintetiza o core com as memórias black-box.
- [x] Relatórios de área/FF/Fmax/potência (dom4 e dom6).
- [x] Testbench RTL + SHM; potência com atividade real.
- [ ] Mesma metodologia aplicada ao FastConv + tabela de PPA.
