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

## Status funcional (C-sim, `compare`, entrada de baixa magnitude)

| Q | config | csim | observação |
|---|---|---|---|
| 4 | M=4 N=2 B=2 | ✅ MATCH | regressão preservada |
| 2 | M=4 N=2 B=2 | ✅ MATCH | 16 `mac16x2` no hadamard |
| 1 | M=4 N=2 B=2 | 🟡 PARCIAL | MATCH p/ `zero`/`center`; mismatch em `kernel_order`/`random` (poucas bordas) |

## Causa-raiz do Q=1 (encontrada)

O datapath **real** dos PEs (`winoPEB_*`) usa `element_wise_mult_block` (não `element_wise_mult_4x4_cell`, que está em código morto). Essa função **também** tinha o pareamento `INDEPTH_MINITILE_SIZE/2` sem tratamento do canal ímpar, então para Q=1 o loop ficava vazio e `UV_MUL_TILE` não era escrito (lixo). Correção aplicada: mesmo tratamento ímpar do `_4x4_cell` em `element_wise_mult_block`.

Também foi descoberto que o `output_buffer0/1` do topo **não era inicializado** (o `clear_output_buffer_content` só rodava sob `DEBUG_FILE_PRINT`); com `clear_flag=0` (3×3) o PE acumulava sobre lixo. Adicionada limpeza incondicional em `wino_systolic_top`.

## Pendência Q=1

Restam mismatches em poucas posições de borda para `kernel_order` (peso todo-1) e `random`: o hardware produz `-1` onde o golden produz `0` (diferença pequena, não saturação). Investigado e descartado: padding de entrada (`0xCD`) e padding do weight DDR (`0xff`). Provável detalhe de arredondamento/mascaramento de borda no `input_feed` para Q=1.

## Próximos passos

1. Fechar o mismatch de borda do Q=1 (`input_feed_underconstruction`).
2. Reduzir N=1 (`WINO_WIDTH=1, WINO_W2=1`) — grid codegen.
3. Reduzir M=1 (`WINO_HEIGHT=1, WINO_H2=1`) — macros `WEIGHT_PORT_NUM`/`OUT_PORT_BATCH_NUM`.
4. Reduzir B=1 (`BATCH_SIZE=1`) — empacotamento de batch.
5. Wrapper de memória síncrona (substituir AXI) + black-box das memórias.
6. Síntese ASIC (Genus) core-only e system-level.

## Alternativa pragmática

Q=2 mantém o pareamento (`mac16x2`) e já é funcional: o hadamard 4×4 fica com **16 unidades `mac16x2`** (≈16 MACs físicos, comparável ao TC), sem rework do weight path. Se a comparação de área aceitar `mac16x2` como multiplicador, Q=2 é um micro válido com muito menos risco.
