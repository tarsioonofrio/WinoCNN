# WinoCNN — Architecture

Hierarquia sintetizável confirmada diretamente no source (`src/wino.cpp`, `src/wino_*.cpp`, `src/wino_systolic_kernel.cpp` gerado por `codegen/gen_systolic.py`).

## Top-level (confirmado no código)

```
wino_systolic_top                                    src/wino.cpp
│
├── load_params                                       src/wino.cpp          (AXI read dos 128 params → ConvDesc_t)
├── load_bias_value                                   src/wino_IO.cpp       (bias → bias_buffer0/1)
│
├── loop (compute_start_row += out_rowstep):
│   │
│   ├── write_output_to_DDR3                          src/wino_IO.cpp       (ping-pong write-back, uma row-step atrás)
│   │   └── write_output_row<0/1>                     src/wino_IO.cpp       (out_buffer → DDR, scale_oback + saturate)
│   │
│   └── wino_input_compute                            src/wino.cpp
│       │
│       ├── load_input_rowtile_from_ddr               src/wino_IO.cpp       (DDR → input_buffer, ping-pong linhas)
│       │   └── load_input_row_from_ddr<0/1>          src/wino_IO.cpp       (burst 128-bit → 8×16-bit → banks)
│       │
│       └── wino_kernel_merge_row                     src/wino.cpp          (merge de kernel por col-offset)
│           └── loop col_offset += merge_kernel_step:
│               └── wino_systolic_kernel_wrapper      src/wino_systolic_kernel.cpp (GERADO)
│                   └── wino_systolic_kernel          src/wino_systolic_kernel.cpp (GERADO)
│                       │
│                       ├── input_feed_underconstruction   src/wino_buffer.cpp  (input_buffer → input_tile_stream)
│                       ├── input_transform ×WINO_WIDTH    src/wino_buffer.cpp  (transformada de entrada B^T·d·B)
│                       ├── weight_feed_one_port ×WEIGHT_PORT_NUM  src/wino_buffer.cpp
│                       │   ├── load_weight_ddr_one_port     src/wino_buffer.cpp  (weight DDR → weight_buff, transform G on-the-fly)
│                       │   └── weight_streamer              src/wino_buffer.cpp  (weight_buff → weight_stream)
│                       └── winoPEB_*  (grid WINO_HEIGHT/WINO_H2 × WINO_WIDTH/WINO_W2)  src/wino_cell.cpp
│                           ├── element-wise multiplication (hadamard)
│                           ├── accumulation (soma sobre minitiles de input depth)
│                           └── output transform (A^T·V·A)
│
└── write_output_to_DDR3 (flush final)                src/wino_IO.cpp
```

## Notas de confirmação vs. hipótese inicial

1. `wino_flatten_kernel` existe em `src/wino.cpp` mas **não é chamado** (código morto/versão antiga). O caminho real usa o `wino_systolic_kernel_wrapper` gerado por `codegen/gen_systolic.py` (incluído via `#include "wino_systolic_kernel.cpp"` em `src/wino.cpp:225`).

2. O grid de PEs é `WINO_HEIGHT/WINO_H2 × WINO_WIDTH/WINO_W2`. Na config original (`WINO_HEIGHT=4, WINO_WIDTH=2, WINO_H2=2, WINO_W2=2`) o grid é **2×2**, com 4 variantes de célula (`winoPEB_CENT`, `winoPEB_EDG`, `winoPEB_BOT`, `winoPEB_CORN`) para bordas/cantos.

3. O `wino_input_compute` **recalcula** os acessos de entrada por row-step (não há estado persistente entre chamadas exceto `static input_buffer` e o `static` de ping-pong).

## Paralelismo original (`src/wino_hw_config.h`)

| Parâmetro | Valor | Significado |
|---|---|---|
| `WINO_DOMAIN_SIZE` | 6 | F(4×4, 3×3): domínio 6×6, saída 4×4 |
| `WINO_HEIGHT` | 4 | linhas do array sistólico (output-channels por minitile) |
| `WINO_WIDTH` | 2 | colunas do array sistólico (tiles espaciais em paralelo) |
| `WINO_H2` / `WINO_W2` | 2 / 2 | dobra do PE grid (2×2 PEs físicos) |
| `INDEPTH_MINITILE_SIZE` | 4 | canais de entrada acumulados por minitile |
| `BATCH_SIZE` | 2 | 2 feature maps interleaved (2 imagens/2 streams) |
| `INPUT_BUFFER_DEPTH` | 4096 | profundidade do input buffer |
| `OUTPUT_BUFFER_DEPTH` | 1024 | profundidade do output buffer |
| `WEIGHT_BUFFER_DEPTH` | 1024 | profundidade do weight buffer |
| `WEIGHT_PORT_NUM` | 4 | portas AXI de peso |

## Buffering (ping-pong)

- **Input buffer** (`input_buffer[INBUFFER_HEIGHT=8][INBUFFER_WIDTH=8][4096]`): BRAM, ping-pong de linhas via bit `row_idx[INBUFFER_HEIGHT_BITWIDTH]` (ou 2 bits conforme `row_address_bitnumber_flag`).
- **Output buffer** (`output_buffer0/1[6][2][1][2][2][6][1024]`): BRAM duplo (ping-pong explícito em `wino_systolic_top`), alternado por `pingpong` a cada row-step.
- **Weight buffer** (`weight_buff[2][..][1024]`): BRAM, ping-pong via bit `pingpong` em `weight_feed_one_port`.

## Dataflow (dentro de `wino_systolic_kernel`)

`#pragma HLS dataflow` conecta, via `hls::stream`:
`input_feed_underconstruction → input_transform → [winoPEB grid] ← weight_feed_one_port/weight_streamer`

Os PEs se comunicam por streams de peso (`weight_stream`) e de tile transformado (`input_tile_transformed_stream`), além de `out_buffer` compartilhado (acumulação).

## Interfaces externas (top)

- `m_axi input_DDR0/1` (2 portas, `ap_uint<128>`)
- `m_axi weight_DDR0..3` (4 portas, `ap_uint<128>`)
- `m_axi output_DDR0/1` (2 portas, `ap_uint<ODDR_WIDTH*BATCH_SIZE*OUT_PORT_BATCH_NUM>` = 144 bits)
- `m_axi mem_params` (`ap_int<32>`, 128 palavras = `ConvDesc_t`)
- `s_axilite` (return/controle)

## Precisão (datapath)

| Largura | Bits | Uso |
|---|---|---|
| `IN_WIDTH` | 8 | entrada / saída quantizada (int8) |
| `G_WIDTH` | 7 | peso 3×3 quantizado |
| `W_WIDTH` | 13 | peso transformado (G·g·G^T) |
| `DB_WIDTH` | 12 | após transformada de entrada (linha) |
| `BTB_WIDTH` | 8 | após transformada de entrada (coluna) |
| `UV_WIDTH` | 24 | produto hadamard acumulado (por minitile) |
| `UVA_WIDTH` | 28 | após A^T parcial |
| `ATA_WIDTH` | 18 | após output transform |
| `OUT_WIDTH` | 9 | acumulador final (com sinal) |
| `OUT_SAT` | 9 | saída saturada [-256, 255] |

Transformadas e bitwidths detalhados em `src/wino_macro.h` (macros de quantização `DB_QUANT_BIT`, `BTB_QUANT_BIT`, `UV_QUANT_BIT`, `UVA_QUANT_BIT`, `ATA_QUANT_BIT`, `OBACK_QUANT_BIT`) e `src/wino_transform.cpp` (macros `DB6x6_1`, `BTB6x6_1`, `gGT3to6`, `GgG3to6`, `UVA_row`, `ATA_col`).
