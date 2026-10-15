# WinoCNN — a história das nossas mudanças

> Um relato literário de tudo o que mudou desde o commit original preservado
> (`4a62569`, então referenciado pela branch `baseline/winocnn`, que não existe
> mais). Não é um changelog: é a narrativa de por que
> cada linha foi escrita, onde ela mora e como se verifica. Onde houver código,
> o trecho aparece; onde houver número, ele foi medido — não estimado.

---

## Prólogo — o que havia antes de nós

O repositório é o WinoCNN original: um acelerador de convolução que combina
array sistólico com o algoritmo rápido de Winograd, publicado em 2021 pela
University of Illinois (Liu, Chen, Hao, Dhar, Chen). Ele é um projeto de HLS
C++ que vira Verilog pela mão do Vivado HLS e, em FPGA, vira bitstream.

O ponto de partida intacto está guardado no commit `4a62569`
("Update README.md") — na época, sob a branch `baseline/winocnn`, que não
existe mais. A partir dele, `master` já continha dois commits que não
são nossos, mas são o solo onde pisamos:

- `b837e5f` — os primeiros documentos (`docs/architecture.md`,
  `docs/address_generation.md`, `docs/configuration_exploration.md`), o
  `.gitignore` e o `run_hls.sh`;
- `4bb2ccb` — o conserto que tornou o caminho **F(2×2,3×3)** (domínio 4)
  realmente executável: `src/wino_cell.cpp` (chamada correta de
  `element_wise_mult_4x4_cell`), `src_gold/wino_gold.cpp` (`int` → `long int`)
  e `testbench/single_main.cpp` (religar o golden model).

É desse `master` que nasce a história que segue; para a contagem corrente de
commits, veja `git log origin/master..origin/iscas2027`. Na época, a branch de
trabalho era `experiment/winocnn-micro`, que não existe mais; a linha
experimental publicada hoje é `iscas2027`.

A pergunta que guia tudo é simples de enunciar e difícil de responder: *o
WinoCNN original, reduzido à menor configuração de hardware possível, ainda é
o WinoCNN?* Preservar o dataflow, o buffering e a geração de endereços — e
trocar apenas o paralelismo — é o que separa uma comparação honesta de um
número inventado.

---

## Capítulo 1 — Entender antes de tocar

Antes de qualquer edição, o código foi mapeado. A hierarquia começa em
`wino_systolic_top` (`src/wino.cpp`) e desce por `load_params`,
`wino_input_compute`, `wino_kernel_merge_row`, `wino_systolic_kernel_wrapper`,
`input_feed_underconstruction`, `input_transform`, `weight_feed_one_port` e as
células `winoPEB_*` até a multiplicação elementar, a acumulação e a
transformada de saída.

Dois documentos nasceram daí e nunca mais foram esquecidos:

- `docs/architecture.md` — a árvore de módulos confirmada no fonte;
- `docs/address_generation.md` — o caminho exato de cada acesso: para entrada
  (`load_input_rowtile_from_ddr`, `load_input_row_from_ddr`), para pesos
  (`weight_feed_one_port`, `load_weight_ddr_one_port`) e para saída
  (`write_output_to_DDR3`, `write_output_row`), com a distinção crucial entre o
  que a CPU calcula em `software/param.cpp` e o que o hardware de fato gera
  com contadores, somadores, comparadores, muxes e FSM.

Essa separação importa porque uma comparação justa de PPA não pode creditar ao
hardware o que o software pré-calculou.

---

## Capítulo 2 — O caminho F(2×2,3×3) que faltava

O domínio 4 (F(2×2,3×3)) estava incompleto no fonte publicado. Três correções
mínimas foram necessárias e estão registradas em
`docs/configuration_exploration.md`:

1. **Hardware** (`src/wino_cell.cpp`): duas chamadas usavam
   `element_wise_mult_4x4<0>(...)` — nome que não existe (o certo é
   `element_wise_mult_4x4_cell`) e layout errado. No domínio 4 há dois streams
   de peso, então a chamada virou duas:
   ```c
   element_wise_mult_4x4_cell<0>(UV_MUL_TILE[0], input_tile_reg, weight_tile_reg[0], ap_clk_div2);
   element_wise_mult_4x4_cell<0>(UV_MUL_TILE[1], input_tile_reg, weight_tile_reg[1], ap_clk_div2);
   ```
2. **Golden model** (`src_gold/wino_gold.cpp`): quatro chamadas de template
   instanciavam `int` sobre arrays `long int`; o caminho F(4,3) equivalente usa
   `<long int>`. A correção é a troca do tipo.
3. **Síntese HLS** (`src/wino_cell.cpp`): oito `#pragma HLS dependence
   variable=out_buffer_4/5` não estavam sob `#if WINO_DOMAIN_SIZE == 6`. O g++
   ignora pragmas, mas o Vivado HLS os lê e falha com "use of undeclared
   identifier 'out_buffer_4'". A correção é envolvê-los no `#if`.

Com isso o F(2,3) funciona em `M=4, N=2, Q=4, B=2` — a configuração dos
autores. É o nosso chão firme.

---

## Capítulo 3 — A jornada micro

A meta era `M=1, N=1, Q=1, B=1`. O caminho até lá foi uma sequência de
descobertas, cada uma registrada em `docs/micro_progress.md` e, para o caso
B=1, detalhada em `docs/b1_pack_unpack_detail.md`.

### 3.1 Q — o canal dentro do mini-tile

`Q = INDEPTH_MINITILE_SIZE` controla quantos canais de entrada são processados
por mini-tile. O código assumia `INDEPTH_MINITILE_SIZE/2` em toda parte
(pareamento de canais, `__builtin_mac16x2`, `counter_boundary`). A
generalização introduziu:

```c
#define UV_MUL_TILE_DIM CEIL_DIV(INDEPTH_MINITILE_SIZE, 2)
#define WEIGHT_ENTRIES_PER_WORD (WINO_DOMAIN_SIZE_SQUARE*INDEPTH_MINITILE_SIZE/4/UV_MUL_TILE_DIM)
```

O `CEIL_DIV` é o que permite Q ímpar. Mas três coisas ainda quebravam para
Q=1:

1. O datapath real é `element_wise_mult_block` (não o `_4x4_cell`, que é código
   morto): faltava o tratamento do canal ímpar, e `UV_MUL_TILE` ficava sem
   escrever. Corrigido com um ramo `#if (INDEPTH_MINITILE_SIZE % 2) == 1`.
2. `output_buffer0/1` só era limpo sob `DEBUG_FILE_PRINT`; com `clear_flag=0`
   (kernel 3×3) a acumulação começava sobre lixo. Passou a ser inicializado no
   topo.
3. **`ap_uint<0>` degenerado**: com `INDEPTH_MINITILE_SIZE_BITWIDTH = 0`, o
   contador `loop_indepth_minitile_idx` (em `wino_buffer.cpp`) e
   `buffer_address_mini_tile` (em `wino_IO.cpp`) incrementam *sem limite* em
   C-sim (1, 2, 3, …), então a comparação `== INDEPTH_MINITILE_SIZE-1` (== 0)
   nunca é verdadeira e a coluna nunca avança. A cura foi
   `INDEPTH_MINITILE_IDX_BITWIDTH = max(1, INDEPTH_MINITILE_SIZE_BITWIDTH)` com
   incremento e reset condicionais.

O resultado honesto: **Q=1 funciona para `h ≤ 8` e `w ≤ 8`**. Acima disso, o
ciclismo do input buffer quebra — um gap documentado, não escondido.

### 3.2 N — a largura do grid

Reduzir `N = WINO_WIDTH = 1` (e `W2 = 1`) exigiu generalizar as condições de
borda do codegen (`codegen/gen_systolic.py`): as chamadas a `winoPEB_EDG/BOT`
passaram a depender do número real de células, e um ramo `#if WINO_HEIGHT==1`
foi aberto nos macros.

### 3.3 H e M — onde a estrutura resiste

`H = WINO_HEIGHT = 1` compila (o `Config_t` do codegen, os macros e as
condições de porta de peso foram ajustados), mas `M=1` **não passa**: o C-sim
aborta no ASan dentro de `winoPEB_CORN`, ao copiar `weight_tile[1]` para
`weight_tile_reg[1]`, embora a primeira dimensão de `weight_tile` seja
`WINO_H2 = 1`. O mesmo PE ainda acessa `out_buffer_*[1]`. Ou seja, o PE assume
duas linhas de peso e duas de saída mesmo com uma só.

Esse é um **bloqueio estrutural**, não de configuração: exigiria parametrizar
em conjunto o PE, o feed de pesos e o write-back. O fallback escolhido foi
`M=2, H2=2, N=1, W2=1, Q=1, B=1` — um único PE no grid (`M/H2 = N/W2 = 1`) e
o hadamard de F(2×2,3×3) com **32 multiplicadores escalares** (duas linhas de
saída × 16 pontos × um batch). O alvo de 16 fica explicitamente pendente.

### 3.4 B — o empacotamento de saída

`B = BATCH_SIZE = 1` foi o último a ceder, e o mais instrutivo. As variantes
ativas de `winoPEB_*` desempacotavam cada palavra de saída sempre como
`(batch1, batch0)`, escrevendo `out_value[..][1]` mesmo com um único batch — e
o ASan confirmou um *stack-buffer-overflow* nessa escrita.

A solução foi criar, em `src/wino_macro.h`, dois macros cientes do batch:

```c
#if BATCH_SIZE > 1
#define WINO_BATCH_UNPACK(dst, data) ((dst)[1], (dst)[0]) = (data)
#define WINO_BATCH_PACK(src) ((src)[1], (src)[0])
#else
#define WINO_BATCH_UNPACK(dst, data) (dst)[0] = (data)
#define WINO_BATCH_PACK(src) (src)[0]
#endif
```

O `(a, b) = data` funciona porque `ap_int` devolve um `ap_concat_ref` — é a
mesma idiomática que o código original usava, agora parametrizada. O commit
`7a410b5` reduziu o escopo da mudança a `winoPEB_CORN`, porque o grid 1×1 só
instancia essa variante; `CENT/BOT/EDG` e `wino_stream_block(2)` são código
morto nessa configuração (o único chamador, `wino_flatten_kernel`, está
comentado em `src/wino.cpp`). O commit `2db3347` havia aplicado a correção de
forma ampla; `7a410b5` a limitou, deixando o diff em 42 linhas cirúrgicas.

Regressão B=2: os quatro testes de protocolo continuaram passando.

### 3.5 O que "passar" significa aqui

O critério de validação é o C-sim em modo `compare`:
`one/center`, `one/kernel_order`, `order/center`, `random/center`. Quando o
hardware e o golden divergem, o programa retorna 3; quando coincidem, imprime
`Not different!`. Todos os passos acima foram medidos assim, com ASan ligado.

---

## Capítulo 4 — A interface de memória que o ASIC exige

O topo original fala AXI: `m_axi input_DDR*`, `weight_DDR*`, `output_DDR*`,
`mem_params` e um `s_axilite`. Para comparar lógica com lógica em ASIC, os
controladores AXI são ruído. A resposta foi um switch de compilação,
`WINO_ASIC`, em `src/wino_mem_if.h`:

- no fluxo FPGA, `WINO_MEM_IF_AXI` mantém o AXI;
- no fluxo ASIC, os ports viram `ap_memory` — RAM síncrona simples com
  `address / ce / we / d / q`.

O algoritmo de endereços não mudou uma vírgula; só o protocolo externo.

Duas armadilhas apareceram aqui, ambas registradas:

1. `_Pragma` não aceita concatenação de literais. O macro passou a montar o
   texto do pragma com `WINO_STR_`/`WINO_XSTR_`, e os parâmetros do macro não
   podem se chamar `port`, `bundle` ou `depth` — senão os próprios tokens
   `port=`/`bundle=`/`depth=` são substituídos. Renomeados para `p`/`b`/`d`.
2. `ap_memory` precisa de tamanho em tempo de compilação. Por isso, no modo
   ASIC, os buffers do topo viram **arrays** (`INPUT_PORTS_DECLARE`,
   `WEIGHT_PORTS_DECLARE`, saída e params). Em C++ eles decaem para ponteiro,
   então o resto do design e o testbench não mudam.

O topo `wino_systolic_top` passa a expor:

| porta | tipo | profundidade |
|---|---|---|
| `input_DDR0/1` | `ap_uint<128>` | 524 288 |
| `weight_DDR0` | `ap_uint<128>` | 1 179 648 |
| `output_DDR0/1` | 32 bits | 524 288 |
| `mem_params` | `ap_int<32>` | 65 535 |

(O `weight_DDR0..3` do fluxo FPGA colapsa para um único port quando
`WINO_WIDTH=1`, via o macro `WEIGHT_PORTS_DECLARE`.)

---

## Capítulo 5 — Genus: medir de verdade

O Genus é o instrumento que transforma intenção em área e tempo. A exigência
era usar **a mesma metodologia** do acelerador de referência (FastConv):
TSMC 28 nm `tcbn28hpcplusbwp30p140`, três corners
(`ssg0p81v125c` / `tt0p9v25c` / `ffg0p99vm40c`), clock de 2 ns (500 MHz), a
mesma célula de *driving* e a mesma carga de saída.

### 5.1 Alinhar ao template

`asic_scripts/genus_core.tcl` foi reescrito seguindo o
`logical_synthesis_body.tcl` do FastConv: `set_multi_cpu_usage` (com
`WINO_CPU`, default 14), `hdl_error_on_blackbox false`,
`syn_generic → syn_map → syn_opt`, relatórios por view, e no fim
`write_hdl`/`write_sdf`/`write_db` e `exit`.

### 5.2 O black-box das memórias

Este é o ponto que decide se o número significa algo. O HLS infere as RAMs
internas como módulos Verilog com `(* ram_style = "block" *)`. Se o Genus as
sintetiza, viram bancos de flip-flops: no micro, algo como 64×1024×9 bits de
buffer de saída, 16×1024×16 de bias, 4096×16 de entrada, 1024×44 de peso —
quase um milhão de bits de registrador. A área seria a memória, não a lógica.

A decisão foi **não ler** os arquivos que declaram memória. O script varre os
`.v` gerados, pula os que contêm `ram_style`, e deixa o Genus tratá-los como
referências não resolvidas — *black boxes*. Na config micro são cinco:

`load_params_parambkb`, `weight_feed_one_pg8j`, `wino_input_computqcK`,
`wino_systolic_topbwn` (64 instâncias), `wino_systolic_topcyx` (16).

O relatório de potência confirma o efeito: `memory = 0`, `bbox = 0`.

### 5.3 Dois consertos de constraint

O `constraints.sdc` herdado do FastConv falava `clk`/`reset`; o topo HLS fala
`ap_clk`/`ap_rst`. E aplicar meio-período de *input/output delay* às portas de
handshake `ap_start`/`ap_done`/`ap_idle`/`ap_ready` criava um caminho espúrio
`ap_start → ap_idle` (16 ps de datapath, −26 ps de slack) que **mascarava** o
caminho crítico real. A correção exclui as portas `ap_*` do delay e as deixa
só nas portas de memória.

### 5.4 O primeiro resultado

O micro de 1 PE (domínio 4) fechou:

| métrica | valor |
|---|---:|
| cell area | 64 812.9 µm² |
| flip-flops | 19 070 (88.8 % com clock gating) |
| combinational | 31 138 |
| slack (2 ns) | **+39 ps** (MET) |
| Fmax | ≈ 510 MHz |
| potência sem estímulo (slow/typ/fast) | 27.3 / 27.5 / 33.3 mW |
| runtime | ≈ 879 s |

O caminho crítico real não é o PE: é um multiplicador em
`input_feed_undercons` (`wino_systolic_topeOg_MulnS_0`). A área é 75 %
`wino_input_compute` — geração de endereços, controle e registradores de
pipeline, o preço do estilo HLS.

---

## Capítulo 6 — O testbench RTL e o SHM

Área e timing vêm da síntese; **potência com atividade real** exige simular. O
FastConv já tinha esse fluxo (Xcelium → SHM → Genus power). O WinoCNN não
tinha nem testbench RTL.

Nasceu `asic_scripts/tb_wino_asic.v`: ele modela as quatro RAMs externas com o
protocolo `ap_memory`, carrega o estímulo por `$readmemh`, pulsa `ap_start`,
espera `ap_done`, conta ciclos e acessos, e escreve um SHM para o Genus.

Três descobertas dolorosas, todas documentadas em `docs/simulation.md`:

1. **Latência da RAM.** O HLS escalona cada porta com uma latência própria. O
   modelo `AESL_automem_*` do cosim mostrou: entrada e peso com **3 ciclos**,
   params com **1**. Usar 1 ciclo para tudo lia dados velhos e produzia saída
   errada.
2. **Os `*_ram.dat`.** As RAMs internas fazem `$readmemh("./*_ram.dat")`. Sem
   esses arquivos no diretório de trabalho, elas ficam não inicializadas e a
   saída vira lixo. O runner passou a copiá-los.
3. **O write-back continua depois de `ap_done`.** Parar 20 ns após `ap_done`
   perdia as últimas palavras — foi isso que gerou a falsa impressão de
   "escrita incompleta" (102 vs 128). A espera passou a 200 ns (depois, 2000
   ns para o domínio 6).

O estímulo vem de `asic_scripts/bin2hex.py`, que converte os dumps do C-sim
(`input.bin`, `weight.bin`, `param.bin`) em hex little-endian para o
`$readmemh`. O teste é determinístico: `random()` do glibc sem `srandom`, o
padrão `random random center`, uma convolução 8×8×8 com kernel 3×3.

O runner é `asic_scripts/run_sim_asic.sh`. A validação de que o RTL é mesmo o
C: a união dos bancos ping-pong `output_DDR0`+`output_DDR1` bate com o modelo
C do cosim em **128/128 palavras**. (O cosim do HLS "falha" por um artefato
conhecido: o testbench C aponta as duas portas de saída para o mesmo buffer,
enquanto o cosim as modela separadas. O testbench RTL usa memórias separadas e
por isso é a referência válida.)

Com o SHM em mãos, `asic_scripts/power.tcl` recria um MMMC de canto `tt`, lê o
DB mapeado e anota a atividade via `read_stimulus -dut_instance tb.dut`. A
anotação cobre 100 % dos flops e portas primárias. O micro domínio 4 mede
**8.457 mW** — contra os 27.5 mW do número sem estímulo, que usava
`lp_default_probability 0.5`. A diferença é o preço da fantasia.

---

## Capítulo 7 — Organizar é parte de medir

Em algum momento o `hw_scripts/` — que guarda os scripts FPGA originais dos
autores (`script.tcl`, `script_ultra96.tcl`, `impl.tcl`, `impl_ultra96.tcl`)
— começou a misturar o nosso fluxo ASIC. A separação foi feita: tudo o que é
nosso (HLS ASIC, Genus, MMMC, constraints, power, cosim, runner de simulação,
conversão de estímulo, stub de SRAM, testbench) mudou para
**`asic_scripts/`** na raiz. Os scripts resolvem a raiz do repositório a
partir do próprio diretório, então só os caminhos de invocação mudaram.

E, quando os dois domínios entraram em cena, os artefatos passaram a ser
**por domínio**: `reports/genus/dom<N>/`, `sim_asic/dom<N>/`,
`testbench/stim/dom<N>/`, com `<N>` lido automaticamente de
`src/wino_hw_config.h`. Assim o F(2×2,3×3) e o F(4×4,3×3) nunca se
sobrescrevem.

---

## Capítulo 8 — Dois domínios

O WinoCNN sempre trabalha com tiles Winograd 3×3; kernels maiores são
decompostos em blocos 3×3. As opções efetivas são:

| `WINO_DOMAIN_SIZE` | tile | saída | multiplicadores (domínio²) |
|---|---|---|---|
| 4 | F(2×2,3×3) | 2×2 | 16 |
| 6 | F(4×4,3×3) | 4×4 | 36 |

**F(4×4,3×3) no modo micro** não precisou de código: `WINO_DOMAIN_SIZE=6` com
`M=2, N=1, Q=1, B=1` compila e passa 4/4 no C-sim (ASan limpo). A limitação de
tamanho é a mesma do micro domínio 4 (≤ 8×8, o ciclismo do input buffer).

O fluxo ASIC completo rodou para os dois domínios:

| | dom4 (F2,3) | dom6 (F4,3) |
|---|---:|---:|
| cell area | 64 812.9 µm² | 147 680.1 µm² |
| flip-flops | 19 070 | 42 095 |
| combinational | 31 138 | 63 777 |
| leaf | 50 388 | 106 151 |
| slack (2 ns) | +39 ps | **+1 ps** (MET) |
| Fmax | ≈ 510 MHz | ≈ 500 MHz |
| potência sem estímulo (slow/typ/fast) | 27.3 / 27.5 / 33.3 mW | 70.2 / 72.6 / 87.6 mW |
| potência com SHM (tt) | 8.46 mW | 28.36 mW |
| ciclos (8×8×8) | 34 122 | 75 419 |
| reads in/w/params | 88 / 339 / 129 | 88 / 516 / 129 |
| writes out | 128 | 128 |

O domínio 6 é ~2.3× maior em área e fica exatamente no limite de 2 ns. Seu RTL
foi validado contra o modelo C do cosim, também 128/128.

---

## Epílogo — onde as coisas moram

**Código-fonte** (mudanças de datapath/config):
`src/wino_macro.h` (macros de batch, larguras, dims), `src/wino_cell.cpp`
(element-wise, PE, transformada de saída), `src/wino_buffer.cpp` (input/weight
transform, load de peso), `src/wino_IO.cpp` e `src/wino.cpp` (endereçamento e
topo), `src/wino_mem_if.h` (novo; interface ASIC), `src/wino_hw_config.h`
(a config), `src/wino_systolic_kernel.cpp` (gerado por
`codegen/gen_systolic.py`), `software/buffer.cpp` e `software/param.cpp`
(empacotamento de peso e descritor), `src_gold/wino_gold.cpp` (golden),
`testbench/single_main.cpp` (testbench C).

**Fluxo ASIC** (`asic_scripts/`):
`script_asic.tcl` (HLS), `genus_core.tcl` (síntese), `mmmc_tsmc_28_bv.tcl` e
`constraints.sdc` (tecnologia), `power.tcl` (potência), `script_cosim.tcl`
(cosim), `run_asic_flow.sh` e `run_sim_asic.sh` (runners), `bin2hex.py`
(estímulo), `tb_wino_asic.v` (testbench RTL), `wino_sram_bb.v` (stub de SRAM).

**Documentação** (`docs/`):
`architecture.md`, `address_generation.md`, `configuration_exploration.md`,
`micro_progress.md`, `b1_pack_unpack_detail.md`, `synthesis.md`,
`simulation.md`, `agent_brief_16macs.md`, e este relato.

**Resultados**: `reports/genus/dom4/` e `reports/genus/dom6/` (relatórios texto;
os `.v`/`.db`/`.sdf` grandes ficam fora do versionamento).

**Commits**: `master` (`4bb2ccb`) traz 2 commits sobre o original preservado
(`4a62569`) e, na época, a branch `experiment/winocnn-micro` acumulava os
demais — a contagem corrente está em `git log origin/master..origin/iscas2027`.
Essa branch não existe mais; a linha experimental publicada hoje é `iscas2027`.

### O que ficou em aberto, dito sem rodeios

- **`M=1`**: bloqueio estrutural no PE (duas linhas de peso/saída hardcoded).
  O micro tem 32 multiplicadores, não os 16 do hadamard puro.
- **`h>8` ou `w>8` no micro Q=1**: o ciclismo do input buffer ainda não fecha.
- **F(3×3,3×3)** (domínio 5): não implementado. As matrizes Toom-Cook foram
  derivadas uma vez e removidas a pedido; o domínio 5 não está no repositório.
- **Comparação final**: falta aplicar exatamente esta metodologia ao FastConv e
  montar a tabela de PPA lado a lado.

A história, até aqui, é a de um baseline que deixou de ser uma caixa-preta: hoje
sabemos sintetizá-lo, simulá-lo, medir sua potência com atividade real e
distinguir o que é arquitetura do que é consequência da ferramenta.
