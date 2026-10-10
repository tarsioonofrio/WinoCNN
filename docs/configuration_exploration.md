# WinoCNN — Configuration Exploration

Exploração empírica das configurações suportadas pelo source original. Cada tentativa: editar `src/wino_hw_config.h`, regenerar `src/wino_systolic_kernel.cpp` com `python3 codegen/gen_systolic.py`, compilar (`make single_csim.out CFLAG="-fPIC -O2 -fsigned-char"`, g++ 8.5.0) e rodar C-sim (`single_csim.out ... compare`).

Legenda das colunas: **M** = `WINO_HEIGHT`, **N** = `WINO_WIDTH`, **Q** = `INDEPTH_MINITILE_SIZE`, **B** = `BATCH_SIZE`, **F(m,r)** = domínio de Winograd.

|  M |  N |  Q |  B | F(m,r)     | compila | csim | csynth | observação |
| -: | -: | -: | -: | ---------- | ------- | ---- | ------ | ---------- |
|  4 |  2 |  4 |  2 | F(4×4,3×3) | ✅      | ✅   | ✅     | baseline (DSP 2344, LUT 319738, FF 403746, BRAM 1082, 2 ns) |
|  4 |  2 |  4 |  2 | F(2×2,3×3) | ✅¹     | ✅   | 🟡²    | 2 fixes mínimos; funcional p/ 6×6 e 8×8 |
|  4 |  2 |  2 |  2 | F(2×2,3×3) | ✅      | ❌   | —      | `INDEPTH_MINITILE_SIZE=2` quebra correção |
|  2 |  2 |  4 |  2 | F(2×2,3×3) | ✅      | ❌   | —      | `WINO_HEIGHT=2` quebra correção |
|  2 |  2 |  2 |  2 | F(2×2,3×3) | ✅      | ❌   | —      | combinação também quebra |
|  2 |  1 |  1 |  2 | F(2×2,3×3) | ✅      | ✅   | —      | baseline funcional atual; 1 PE, Q=1 |
|  2 |  1 |  1 |  1 | F(2×2,3×3) | ✅      | ✅   | —      | B=1 após generalizar pack/unpack de saída; 1 PE, 32 mult escalares |
|  2 |  1 |  1 |  1 | F(4×4,3×3) | ✅      | ✅   | —      | **domínio 6 no modo micro**; 4/4 csim + ASan limpo (sem mudança de código) |
|  1 |  1 |  1 | 2 | F(2×2,3×3) | ✅      | ❌   | —      | `winoPEB_*` ainda assume duas linhas de peso/saída; ASan em `weight_tile[1]` |
|  1 |  1 |  1 | 1 | F(2×2,3×3) | ✅      | ❌   | —      | não testada após o bloqueio estrutural de M=1 |

¹ *após correção do caminho F(2,3) incompleto (ver abaixo).* ² *em execução.*

## Reprodução do codegen vs. commit

`python3 codegen/gen_systolic.py` **não** reproduz byte-a-byte o `src/wino_systolic_kernel.cpp` commitado. Diferenças no `diff`:

- o arquivo commitado tem 4 linhas `#pragma HLS interface m_axi port=weight_DDR0..3` **adicionadas à mão** dentro de `wino_systolic_kernel`;
- o arquivo commitado tem um `std::cout<<" wino_systolic_kernel_wrapper "<<std::endl;` (debug) **ausente** do gerado atual.

Consequência: ao regenerar para uma nova config, é preciso reaplicar essas edições manuais (os pragmas `m_axi` são funcionais para a síntese AXI).

## Correções mínimas para F(2×2,3×3) (WINO_DOMAIN_SIZE=4)

O caminho `WINO_DOMAIN_SIZE=4` está **incompleto** no source publicado. Duas correções mínimas são necessárias:

### 1. Hardware — `src/wino_cell.cpp` (2 call sites, linhas ~4161 e ~4969)

Chamava `element_wise_mult_4x4<0>(UV_MUL_TILE, input_tile_reg, weight_tile_reg, ap_clk_div2)`, mas:
- a função definida chama-se `element_wise_mult_4x4_cell` (typo no nome);
- o layout real é 2-way (`UV_MUL_TILE[2][..]`, `weight_tile_reg[2][..]`, pois no domínio 4 há 2 streams de peso).

Correção (segue a intenção do código comentado pelos autores):

```c
element_wise_mult_4x4_cell<0>(UV_MUL_TILE[0], input_tile_reg, weight_tile_reg[0], ap_clk_div2);
element_wise_mult_4x4_cell<0>(UV_MUL_TILE[1], input_tile_reg, weight_tile_reg[1], ap_clk_div2);
```

### 2. Golden model — `src_gold/wino_gold.cpp` (4 chamadas)

Chamava `input_right_mul_16<int>(...)`, `input_left_mul_16<int>(...)`, `output_right_mul_4to2<int>(...)`, `output_left_mul_4to2<int>(...)` sobre arrays `long int[..]`, mas instanciava o template com `int`. O caminho F(4,3) equivalente usa `<long int>`. Correção: `int` → `long int`.

### 3. Síntese HLS — `src/wino_cell.cpp` (8 `#pragma HLS dependence`)

Os `#pragma HLS dependence variable=out_buffer_4/5` (nas 4 funções `winoPEB_*`, blocos `inter` e `intra`) **não** estão sob `#if WINO_DOMAIN_SIZE == 6`. O C-sim (g++) ignora esses pragmas, mas o Vivado HLS os processa e falha com `use of undeclared identifier 'out_buffer_4'` para `WINO_DOMAIN_SIZE=4` (a declaração dos parâmetros `out_buffer_4/5` já é corretamente guardada; só os pragmas `dependence` não). Correção: envolver cada par `out_buffer_4`+`out_buffer_5` em `#if WINO_DOMAIN_SIZE == 6 ... #endif`.

---

## Configuração micro adotada e limite de redução

A configuração escolhida para a comparação controlada é `WINO_DOMAIN_SIZE=4`
(F(2×2,3×3), 1 PE), `M=2, N=1, Q=1, B=1`. Ela passa a regressão funcional
registrada em `micro_progress.md` e usa **32 multiplicadores escalares** no
hadamard (duas linhas de saída × 16 pontos do domínio × um batch). Esse é o
baseline micro; não o número nominal de 16, que pressuporia uma única linha de
saída.

## Bloqueios para reduzir paralelismo até M=N=Q=B=1

A configuração mais reduzida validada nesta exploração, sem uma refatoração
estrutural do PE para suportar uma única linha, é:

```
F(2×2,3×3): WINO_DOMAIN_SIZE=4, WINO_HEIGHT=2, WINO_WIDTH=1,
            INDEPTH_MINITILE_SIZE=1, BATCH_SIZE=1,
            WINO_H2=2, WINO_W2=1
```

Reduções adicionais **quebram a correção** (não são mudanças só de config):

| Redução | Bloqueio |
|---|---|
| `Q=2` (`INDEPTH_MINITILE_SIZE=2`) | código assume `INDEPTH_MINITILE_SIZE/2` (pareamento de canais, `__builtin_mac16x2`, `counter_boundary=INDEPTH/2-1`) |
| `B=1` (`BATCH_SIZE=1`) | empacotamento DDR 2-batch interleaved hardcoded; dims `[..][BATCH_SIZE]` e MAC pareado assumem 2 |
| `M=2` (`WINO_HEIGHT=2`) | `WEIGHT_PORT_NUM`/`OUT_PORT_BATCH_NUM` e branches `#if WINO_HEIGHT==2` têm assunções conflitantes |
| `N=1` / `M=1` | grid sistólico (`WINO_HEIGHT/WINO_H2 × WINO_WIDTH/WINO_W2`) e codegen não suportam 1×1 |

Todos exigem alteração estrutural (permitida apenas na versão `micro`, seção 9 do plano), não apenas edição de `wino_hw_config.h`.

Na execução do runbook, `B=1` foi fechado sem alterar a ordem do dataflow: o
problema era exclusivamente o desempacotamento de palavras de saída com duas
lanes hardcoded. A correção (`WINO_BATCH_UNPACK/WINO_BATCH_PACK`) foi aplicada
somente em `winoPEB_CORN`, a única variante instanciada pela malha 1×1. Já `M=1`
falha antes do compare porque o PE usa duas linhas de pesos e duas linhas de
write-back mesmo quando `WINO_H2=1`; isso requer uma refatoração conjunta do PE,
do feed de pesos e do codegen.

> Documentação detalhada da correção de `B=1`:
> [`b1_pack_unpack_detail.md`](b1_pack_unpack_detail.md).

## Contagem de multiplicadores (datapath element-wise)

`element_wise_mult` (hardware) calcula, por PE:

```
WINO_DOMAIN_SIZE² × (INDEPTH_MINITILE_SIZE/2) × BATCH_SIZE × 2
```

- **Configuração micro adotada** (M=2,N=1,Q=1,B=1, um PE): `4×4 × 1 × 1 × 2 = 32` multiplicadores escalares.
- **Alvo exploratório não adotado** (M=1,N=1,Q=1,B=1): seriam 16 multiplicadores, mas o source atual acessa uma segunda linha de pesos e de write-back em `winoPEB_CORN`; não é uma configuração funcional só por ajuste de parâmetros.

## Validação funcional (nota)

O golden (`wino_gold.cpp`) usa `long int` (64-bit) nos acumuladores; o hardware usa larguras fixas (`ap_int<UV_WIDTH>` etc.). Convergem para dados dentro da faixa dinâmica projetada (ex.: entrada `one`, peso `center`/`kernel_order`/`zero` → `Not different!`), mas divergem para dados aleatórios de maior magnitude (overflow/saturação das larguras fixas). A validação funcional desta exploração usou entradas de baixa magnitude para isolar correção do datapath do efeito de overflow. O fluxo completo do paper (`main.cpp` + `exec_plot` + `compute_scale_factors`) calcula fatores de escala que mantêm os dados dentro da faixa; o `single_main` standalone usa `scale_oback_int` fixo (não calculado), por isso não é um teste funcional válido para dados aleatórios.

---

## F(4×4,3×3) no modo micro (domínio 6)

Confirmado: `WINO_DOMAIN_SIZE=6` com `WINO_HEIGHT=2, WINO_WIDTH=1, WINO_H2=2,
WINO_W2=1, INDEPTH_MINITILE_SIZE_BITWIDTH=0 (Q=1), BATCH_SIZE=1` **compila e
passa 4/4** no C-sim (ASan limpo), sem nenhuma mudança de código — é só trocar
o `wino_hw_config.h`. Funcional para h/w até **64×64** (depth múltiplo de 8);
ver a nota de Q>8 em `micro_progress.md`.

Trocar o domínio é feito por `src/wino_hw_config.h` + `python3 codegen/gen_systolic.py`.

