# WinoCNN — Address Generation

Separação explícita entre **endereços/parâmetros calculados em software** (`software/param.cpp`, antes da execução) e a **lógica de endereçamento em hardware** (counters/adders/comparators/muxes sintetizados).

Regra de leitura deste documento: cada caminho segue o formato

```
Memory
  ↓
address calculation (quem calcula: SW/HW, quais operadores)
  ↓
buffer address
  ↓
datapath
```

---

## 1. Input read path

```
DDR (input_DDR0/1, m_axi 128-bit)
  ↓
load_input_rowtile_from_ddr  (src/wino_IO.cpp:761)
  → load_input_row_from_ddr<0/1>  (src/wino_IO.cpp:230)
  ↓
input_buffer[INBUFFER_HEIGHT][INBUFFER_WIDTH][INPUT_BUFFER_DEPTH]  (BRAM)
  ↓
input_feed_underconstruction  (src/wino_buffer.cpp:15)  → input_tile_stream
```

### DDR address

```
ddr_address_offset = row_idx * group_indepth_x_inwidth_align8_by8
                   + group_indepth_offset_x_inwidth_align8_by8
DDR_offset = DDR_port + ddr_address_offset
DDR_data   = DDR_offset[cycle]         // burst sequencial
```

- `group_indepth_x_inwidth_align8_by8`, `group_indepth_offset_x_inwidth_align8_by8` — **software** (`process_element6x6_soft`).
- `row_idx`, `cycle` — **hardware** (loop counter, `input_load_burst_length` vem de software).
- Lê 128 bits/ciclo → divide em 8×16 bits (`DDR_data_divided[0..7]`), cada 16-bit = par `(batch1, batch0)` de int8.

### Input buffer address

```
buffer_addr = ( row_pingpong_bit , buffer_address_mid , buffer_address_mini_tile )
```

- `row_pingpong_bit1 = row_idx[INBUFFER_HEIGHT_BITWIDTH]` (1 bit) ou
  `row_pingpong_bit2 = row_idx.range(INBUFFER_HEIGHT_BITWIDTH+1, INBUFFER_HEIGHT_BITWIDTH)` (2 bits),
  selecionado por `row_address_bitnumber_flag` (software).
- `buffer_address_mid` — HW counter, incrementa:
  - `+ buffer_address_mid_increment_step` (software) ao fechar uma largura (`write_inwidth_counter == inwidth_align8`);
  - `+1` quando `write_inwidth_counter[2:0]==0` (passa um grupo de 8 colunas → bank).
- `buffer_address_mini_tile` — HW counter (0..INDEPTH_MINITILE_SIZE-1), índice dentro do minitile.
- `buffer_address_mid_offset` — HW register, `= buffer_address_mid` a cada 8 ciclos, ou `+ inwidth_ceildiv_inbufferwidth` ao completar minitile.
- `bank` (dimensão 0 de `input_buffer`) — `bank_split_idx` (HW) para `INBUFFER_WIDTH>8`.

### Operadores de hardware

counter (`read_inwidth_counter`, `write_inwidth_counter`, `buffer_address_mid`, `buffer_address_mini_tile`, `bank_split_idx`), adder, comparador (`==`), mux (`row_address_bitnumber_flag`, `row_pingpong_bit`), register (`register_matrix[8][8]` para transpor/reordenar), `left_down_flag` (direção do shift).

### Data reorganização

`register_matrix[8][8]` faz a transposição/deslize: cada palavra DDR de 128 bits contém 8 canais (depth) de 1 coluna; o hardware desliza para entregar 8 colunas × 8 canais alinhados à janela de leitura do buffer.

---

## 2. Weight read path

```
DDR (weight_DDR0..3, m_axi 128-bit)
  ↓
weight_feed_one_port<port>  (src/wino_buffer.cpp:985)
  → load_weight_ddr_one_port  (src/wino_buffer.cpp:571)
  ↓
weight_buff[WEIGHT_FEED_NUMBER_PER_PORT][..][WEIGHT_BUFFER_DEPTH]  (BRAM, ping-pong)
  ↓
weight_streamer  (src/wino_buffer.cpp:861)  → weight_stream  (FIFO → PEs)
```

### DDR address

```
DDR_offset (static) += weightDDR_port_burst_length     // a cada burst
DDR_offset = reset_DDR_offset                          // ao final do ciclo de bursts
offseted_weight_DDR = weight_DDR + ddr_address_offset
temp128 = offseted_weight_DDR[address]                 // burst sequencial
```

- `weightDDR_port_burst_length`, `weightDDR_buffer_burst_length`, `weightDDR_burst_number`, `reset_DDR_offset` — **software**.
- `DDR_offset`, `DDR_load_cnt` — **hardware** (`static` registers persistindo entre chamadas).

### Weight buffer address

```
buffer_address = ( pingpong , buffer_address_offset_x2[WEIGHT_BUFFER_DEPTH_BITWIDTH-1:1] )
```

- `pingpong` — HW bit.
- `buffer_address_offset_x2` — HW counter: `=0` ao fim de um buffer-burst (`port_load_cnt_x2/2 == weightDDR_buffer_burst_length`), senão `+=2` quando `counter_x2/2 == counter_boundary`.
- `buffer_idx` — HW, seleciona o banco (`WEIGHT_FEED_NUMBER_PER_PORT`).
- `counter_boundary = INDEPTH_MINITILE_SIZE/2 - 1`.

### Transform on-the-fly

`load_weight_ddr_one_port` **não** apenas copia: aplica a transformada de Winograd do peso (G·g·G^T) durante o load (`gGT3to6`/`GgG3to6` de `src/wino_transform.cpp`), quantizando para `W_WIDTH` bits. O peso sai do buffer **já transformado**.

### Operadores de hardware

counter (`counter_x2`, `port_load_cnt_x2`, `buffer_address_offset_x2`, `buffer_idx`, `DDR_load_cnt`), adder, comparador, mux (`wino3x3_flag`, `pingpong`, `skip_flag`), register (`trans_weight_reg`), multiplicadores/adders da transformada G (constantes hardcoded).

---

## 3. Output write path

```
out_buffer[6][2][1][2][2][6][1024]  (BRAM, ping-pong output_buffer0/1)
  ↓
write_output_to_DDR3  (src/wino_IO.cpp:2033)
  → write_output_row<0/1>  (src/wino_IO.cpp:997)
  ↓
DDR (output_DDR0/1, m_axi)
```

### DDR address

```
out_ddr_offset0 (static) = 0                       // first_flag
out_ddr_offset1 (static) = output_burst_length     // first_flag
out_ddr_offset0 += out_ddr_increment_step          // por row-step
out_ddr_offset1 += out_ddr_increment_step
write_output_row(out_DDR + out_ddr_offset, ...)    // burst sequencial dentro da row
```

- `output_burst_length`, `out_ddr_increment_step`, `wino_tile_number_in_outwidth`, `wino_output_tile_size` — **software**.
- `out_ddr_offset0/1` — **hardware** (`static` registers).
- `rowtile_baseaddr0` — HW register, `+= wino_tile_number_in_outwidth` ao fechar `wino_output_tile_size-2` linhas.
- `buffer_counter` — HW counter (0..wino_output_tile_size-2, passo 2).

### Output buffer address (leitura do out_buffer)

```
depth_address_lo = (o8 << 1) * outbuffer_omini_increment_step        // WINO_HEIGHT==4
depth_address_hi = depth_address_lo + outbuffer_omini_increment_step
buffer_address_lo = depth_address_lo + row_address + col_address
buffer_address_hi = depth_address_hi + row_address + col_address
```

- `outbuffer_omini_increment_step` — **software** (`= wino_tile_number_in_out_rowstep * wino_tile_number_in_outwidth`).
- `row_address = rowtile_baseaddr0`, `col_address`, `o8`, `wino_width_idx`, `wino_cell_inneridx` — **hardware** counters/registers derivados do loop de burst.

### Escala e saturação

Dentro de `write_output_row`:
```
outmem_data_scale[i][b] = ((outdata_vect[i][b] * scale_oback) >> OBACK_QUANT_BIT)
saturação para ODDR_WIDTH bits (judge_bits0 == 0 || -1, senão satura)
```
`scale_oback_int` vem de `conv_desc` (software).

### Operadores de hardware

counter (`buffer_counter`, `row_idx`, `out_address`), adder (`out_ddr_offset += step`, `rowtile_baseaddr += step`, `depth/row/col`), comparador, mux, register (`static out_ddr_offset0/1`), multiplicador + shift (scale_oback).

---

## Resumo: software × hardware

| Caminho | Calculado em **software** (param.cpp) | Calculado em **hardware** (counters/adders) |
|---|---|---|
| Input read | `group_indepth_x_inwidth_align8_by8`, `input_load_burst_length`, `buffer_address_mid_increment_step`, `inwidth_ceildiv_inbufferwidth`, `row_address_bitnumber_flag` | `row_idx`, `cycle`, `buffer_address_mid`, `buffer_address_mini_tile`, `buffer_address_mid_offset`, `bank_split_idx`, `row_pingpong_bit` |
| Weight read | `weightDDR_port/buffer_burst_length`, `weightDDR_burst_number`, `reset_DDR_offset`, `loop_*_reset_cycle`, `weightbuffer_outdepth_minitile_number` | `DDR_offset`, `DDR_load_cnt`, `buffer_address_offset_x2`, `buffer_idx`, `counter_x2`, `port_load_cnt_x2`, `pingpong` |
| Output write | `output_burst_length`, `out_ddr_increment_step`, `outbuffer_omini_increment_step`, `wino_tile_number_in_outwidth`, `scale_oback_int` | `out_ddr_offset0/1`, `rowtile_baseaddr0`, `buffer_counter`, `outrow_idx`, `o8`, `col_address` |

**Conclusão para comparação justa:** a CPU/software (`process_element6x6_soft`) calcula constantes de configuração e bounds de loop. Todo o endereçamento efetivo (contagem, incremento, reset, seleção de banco/ping-pong) é executado por counters/adders/comparators/muxes **sintetizados no hardware**. Nenhum cálculo de `software/param.cpp` é contabilizado como hardware.
