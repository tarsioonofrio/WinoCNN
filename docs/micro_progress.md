# WinoCNN-micro — progresso

Alvo: `M=WINO_HEIGHT=1, N=WINO_WIDTH=1, Q=INDEPTH_MINITILE_SIZE=1, B=BATCH_SIZE=1`, F(2×2,3×3) (`WINO_DOMAIN_SIZE=4`), `WINO_H2=WINO_W2=1` → 1 PE, ~16 multiplicadores (hadamard do domínio 4×4).

Base: F(2,3) funcional (M=4,N=2,Q=4,B=2), que por sua vez parte dos 3 fixes do caminho F(2,3) (ver `configuration_exploration.md`).

## Mudanças implementadas (genéricas, backward-compatible)

1. **`src/wino_macro.h`**
   - `UV_MUL_TILE_DIM = CEIL_DIV(INDEPTH_MINITILE_SIZE, 2)` — nº de slots de acumulação hadamard (com pareamento de 2 canais, mas `CEIL_DIV` para Q ímpar).
   - `WEIGHT_ENTRIES_PER_WORD = WINO_DOMAIN_SIZE_SQUARE*INDEPTH_MINITILE_SIZE/4/UV_MUL_TILE_DIM` — entradas de 4 pesos por palavra DDR.

2. **`src/wino_cell.cpp`**
   - Dims de `UV_MUL_TILE` e loops de acumulação: `INDEPTH_MINITILE_SIZE/2` → `UV_MUL_TILE_DIM`.
   - `element_wise_mult_4x4_cell`: adicionado tratamento do canal ímpar (`#if (INDEPTH_MINITILE_SIZE % 2) == 1`) para Q=1.

3. **`software/buffer.cpp`** (`weight_to_ddr`) e **`src/wino_buffer.cpp`** (`load_weight_ddr_one_port`): empacotamento de peso generalizado (`UV_MUL_TILE_DIM`, `WEIGHT_ENTRIES_PER_WORD`, `counter_boundary = UV_MUL_TILE_DIM-1`).

## Status funcional (C-sim, `compare`)

| Q | config | csim | observação |
|---|---|---|---|
| 4 | M=4 N=2 B=2 | ✅ MATCH | regressão preservada (4..16) |
| 2 | M=4 N=2 B=2 | ✅ MATCH | 16 `mac16x2` no hadamard |
| 1 | M=4 N=2 B=2 | 🟡 PARCIAL | MATCH p/ 4×4, 6×6, 8×8 (zero/center/kernel_order/random); falha p/ 10×10+ |

## Causa-raiz do Q=1 (encontrada e corrigida)

1. **Datapath real** (`element_wise_mult_block`, usado pelos `winoPEB_*`; o `element_wise_mult_4x4_cell` está em código morto): tinha o pareamento `INDEPTH_MINITILE_SIZE/2` sem tratamento do canal ímpar → Q=1 deixava `UV_MUL_TILE` sem escrever. Corrigido.
2. **`output_buffer0/1` não inicializado** no topo (clear só sob `DEBUG_FILE_PRINT`); com `clear_flag=0` (3×3) acumulava sobre lixo. Corrigido.
3. **`ap_uint<0>` degenerado**: `loop_indepth_minitile_idx` (`wino_buffer.cpp`) e `buffer_address_mini_tile` (`wino_IO.cpp`) têm largura `INDEPTH_MINITILE_SIZE_BITWIDTH = 0` para Q=1; em C-sim incrementam **sem limite** (1,2,3,…), então `==INDEPTH_MINITILE_SIZE-1` (==0) nunca é verdade e **a coluna nunca avança**. Corrigido com `INDEPTH_MINITILE_IDX_BITWIDTH = max(1, INDEPTH_MINITILE_SIZE_BITWIDTH)` + incremento com reset condicional.
4. **Concatenação `common`** no `input_feed` usava a largura do índice; ajustada para Q=1 (sem o bit do minitile).

## Pendência Q=1

Funcional apenas quando **h ≤ 8 e w ≤ 8** (um conjunto de linhas/banco do input buffer). Falha para `h > 8` **ou** `w > 8` (ciclismo do input buffer). Isolado: 8×8 ✅; 16×8 ❌; 8×16 ❌; 10×10+ ❌. Q=4 funciona em todos.

Hipótese: o endereçamento do input buffer (`load_input_row_from_ddr`) assume `INDEPTH_MINITILE_SIZE>=2`. Com Q=1 o `buffer_address_mini_tile` é sempre 0, então `buffer_address_mini_tile == INDEPTH_MINITILE_SIZE-1` (==0) é sempre verdadeira e `buffer_address_mid_offset += inwidth_ceildiv_inbufferwidth` dispara a cada ciclo — quebrando o endereçamento quando há ciclismo de banco/linha. Somado a isso, a fórmula de `buffer_address_mid_increment_step` para Q=1 (`7·ceildiv+1`) merece verificação.

## Próximos passos

1. Fechar o mismatch de largura > 8 para Q=1 (banking do input buffer / `buffer_address_mid_increment_step`).
2. Reduzir N=1 (`WINO_WIDTH=1, WINO_W2=1`) — grid codegen.
3. Reduzir M=1 (`WINO_HEIGHT=1, WINO_H2=1`) — macros `WEIGHT_PORT_NUM`/`OUT_PORT_BATCH_NUM`.
4. Reduzir B=1 (`BATCH_SIZE=1`) — empacotamento de batch.
5. Wrapper de memória síncrona (substituir AXI) + black-box das memórias.
6. Síntese ASIC (Genus) core-only e system-level.

## Alternativa pragmática

Q=2 mantém o pareamento (`mac16x2`) e já é funcional: o hadamard 4×4 fica com **16 unidades `mac16x2`** (≈16 MACs físicos, comparável ao TC), sem rework do weight path. Se a comparação de área aceitar `mac16x2` como multiplicador, Q=2 é um micro válido com muito menos risco.
