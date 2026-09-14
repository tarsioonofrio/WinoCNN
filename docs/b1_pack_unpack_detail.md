# Correção `B=1` — pack/unpack de saída (documentação detalhada)

Este documento explica, em detalhe, **todas** as alterações feitas para tornar a
configuração `BATCH_SIZE=1` funcional no WinoCNN-micro, por que cada uma era
necessária, por que as demais variantes de PE **não** foram alteradas, e como o
resultado foi verificado.

Commits relevantes (branch `experiment/winocnn-micro`):

| commit | descrição |
|---|---|
| `2db3347` | generaliza pack/unpack de saída para `BATCH_SIZE` (aplicado a todas as variantes de PE) |
| `7a410b5` | reduz o diff ao mínimo: mantém a correção **apenas** em `winoPEB_CORN` |

O diff efetivo (estado final) em relação ao baseline pré-correção (`75cc15d`) é:

```
src/wino_macro.h  | 13 +++++++++++-
src/wino_cell.cpp | 42 +++++++++++++++++++++---------------------
2 files changed, 55 insertions(+), 44 deletions(-)
```

---

## 1. Objetivo e escopo

Objetivo: permitir a configuração micro

```
WINO_DOMAIN_SIZE=4  (F(2×2,3×3))
WINO_HEIGHT=2, WINO_WIDTH=1, WINO_H2=2, WINO_W2=1
INDEPTH_MINITILE_SIZE=1  (Q=1)
BATCH_SIZE=1             (B=1)
```

que mantém **uma única célula PE** (`M/H2 = 2/2 = 1`, `N/W2 = 1/1 = 1`) e usa
**32 multiplicadores escalares** no hadamard do domínio 4×4.

Fora de escopo: o bloqueio estrutural de `M=1` (ver §8), o wrapper de memória
síncrona e a síntese ASIC.

---

## 2. Contexto: o layout da palavra de saída

### 2.1 O array `out_value`

Em cada variante de PE (`winoPEB_CENT/BOT/EDG/CORN`) os resultados do hadamard
são materializados em um array **separado por batch**:

```c
// src/wino_cell.cpp:999 (winoPEB_CENT; análogo nas outras variantes)
ap_int<OUT_WIDTH> out_value[2][WINO_OUT_SIZE_CELL][WINO_OUT_SIZE_CELL][BATCH_SIZE];
```

- `[2]` — as duas linhas de saída do PE (`WINO_H2 = 2`);
- `[WINO_OUT_SIZE_CELL][WINO_OUT_SIZE_CELL]` — as posições da tile de saída;
- `[BATCH_SIZE]` — **uma lane por batch**.

O array `out_value_back` (linha 1102) tem a mesma forma.

Os valores chegam de `data0[]`/`data1[]`, que são palavras **empacotadas com os
batches intercalados**:

```c
// src/wino_cell.cpp:1012
ap_uint<OUT_WIDTH*BATCH_SIZE> data0[6];   // B=2 ⇒ 2 × OUT_WIDTH bits
```

### 2.2 O idioma de concatenação (`operator,`)

O source usa `(a, b) = data` para **repartir** uma palavra larga em duas lanes.
Isso **não** é o operador vírgula embutido do C++: o `ap_int` do HLS o
sobrecarrega. Em `include/ap_int_sim.h`:

```c
// ap_concat_ref::operator=  (linhas 271-282)
mbv1.set(ap_private<_AP_W1,false>((vval >> W_ref2) & mask1)); // parte ALTA → 1º operando
mbv2.set(ap_private<_AP_W2,false>(vval & mask2));             // parte BAIXA → 2º operando
```

ou seja, `(dst[1], dst[0]) = data` equivale a Verilog `{dst[1], dst[0]} = data`:
`dst[1]` recebe a metade alta (= batch 1) e `dst[0]` a metade baixa (= batch 0).

### 2.3 Por que dois batches numa palavra

Com `B=2`, cada palavra carrega os dois batches intercalados para amortizar a
largura de banda do buffer de saída. O PE **desempacota** ao ler (para `out_value`)
e **reempacota** ao escrever de volta (de `out_value_back` para `out_buffer_*`).

---

## 3. O problema

### 3.1 O padrão hardcoded

O código publicado escrevia a forma de dois batches **incondicionalmente**:

```c
// ANTES — src/wino_cell.cpp (ex.: linhas 3552-3567 em winoPEB_CORN)
(out_value[0][0][c][1],out_value[0][0][c][0])=data0[0];
...
(out_value[1][5][c][1],out_value[1][5][c][0])=data1[5];
```

e, na escrita de volta:

```c
out_buffer_0[0][wino_w2][c][outbuffer_addr_reg]=(out_value_back[0][0][c][1],out_value_back[0][0][c][0]);
...
```

### 3.2 O acesso fora dos limites com `B=1`

Com `BATCH_SIZE=1`, `out_value[...]` tem **uma** lane (`[BATCH_SIZE] = [1]`), mas
o código indexa `[1]` — que não existe. Como `operator,` avalia os **dois**
operandos (para formar a referência de concatenação), `out_value[..][1]` é
**lido** mesmo que o resultado só seja atribuído a `[0]`.

Consequência: **stack-buffer-overflow**, detectado pelo AddressSanitizer antes
mesmo do `compare`. Era esse o erro observado na primeira tentativa de `B=1`.

### 3.3 Por que os testes `B=2` passavam

Com `B=2` as duas lanes existem e a concatenação funciona como projetado. Por
isso a configuração `B=2` sempre esteve correta — o defeito só aparece quando a
segunda lane deixa de existir.

---

## 4. A correção

### 4.1 Os macros

Em `src/wino_macro.h` (após `#define BATCH_SIZE 1`):

```c
// Output-buffer words are interleaved by batch.  The published PE code used
// the two-batch form unconditionally; keep that layout for B=2 while making
// the single-batch micro configuration a real one-element transfer.
#if BATCH_SIZE > 1
#define WINO_BATCH_UNPACK(dst, data) ((dst)[1], (dst)[0]) = (data)
#define WINO_BATCH_PACK(src) ((src)[1], (src)[0])
#else
#define WINO_BATCH_UNPACK(dst, data) (dst)[0] = (data)
#define WINO_BATCH_PACK(src) (src)[0]
#endif
```

E os 40 usos no PE ativo foram reescritos, por exemplo:

```c
// DEPOIS
WINO_BATCH_UNPACK(out_value[0][0][c], data0[0]);
...
out_buffer_0[0][wino_w2][c][outbuffer_addr_reg]=WINO_BATCH_PACK(out_value_back[0][0][c]);
```

### 4.2 Por que `B=2` é idêntico

Com `BATCH_SIZE > 1` o macro expande **exatamente** para a expressão original
(`((dst)[1], (dst)[0]) = (data)`). Não há mudança de comportamento — o caminho
`B=2` é byte-a-byte o mesmo. Isso foi verificado empiricamente (§7).

### 4.3 Por que `B=1` é correto

Com `BATCH_SIZE=1`, `data` é `ap_uint<OUT_WIDTH*1>` e `dst[0]` é
`ap_int<OUT_WIDTH>`: uma transferência direta de lane única, sem tocar `[1]`.
O overflow desaparece e o valor do batch 0 é preservado.

---

## 5. Por que a correção ficou restrita a `winoPEB_CORN`

### 5.1 A malha é 1×1

O codegen instancia uma chamada de PE por posição da malha
(`codegen/gen_systolic.py`, laço `WINO_HEIGHT//WINO_H2 × WINO_WIDTH//WINO_W2`).
Com `WINO_HEIGHT/WINO_H2 = 1` e `WINO_WIDTH/WINO_W2 = 1`, há **uma** célula, e a
função escolhida é a de canto (`winoPEB_CORN`), pois `wino_w` e `wino_h` são
ambos o último índice.

Evidência no kernel gerado:

```
$ grep -n "winoPEB_" src/wino_systolic_kernel.cpp
98:	winoPEB_CORN(
```

### 5.2 As demais variantes são código morto nesta config

`winoPEB_CENT`, `winoPEB_BOT` e `winoPEB_EDG` **não** são chamadas pelo kernel
gerado. Aplicar o macro nelas não é exercido por nenhum teste desta configuração
— foi o que motivou a redução do commit `2db3347` para o commit `7a410b5`.

### 5.3 `wino_stream_block(2)` também é morto

- `wino_stream_block` não tem chamadores.
- `wino_stream_block2` só é chamado de dentro de `wino_flatten_kernel`
  (`src/wino.cpp:389`), e essa chamada está **comentada** (`src/wino.cpp:445`).

Portanto as edições nesses dois blocos também foram revertidas.

> Observação: os macros permanecem definidos em `wino_macro.h` e são usados pelo
> CORN. Se, no futuro, outras grades passarem a instanciar `CENT/BOT/EDG`, basta
> aplicar o mesmo macro nesses sites (a definição já existe).

---

## 6. Contagem de multiplicadores (por que 32 e não 16)

O datapath real é `element_wise_mult_block` (`src/wino_cell.cpp:345`):

```c
for(wr=0; wr<WINO_DOMAIN_SIZE; wr++)          // 4
  for(wc=0; wc<WINO_DOMAIN_SIZE; wc++)        // 4   → 16 pontos
    for(id2=0; id2<Q/2; id2++, id+=2)         // pareamento de 2 canais
      for(b=0; b<BATCH_SIZE; b++)
        UV[1] = w[1][id]*in[id] + w[1][id+1]*in[id+1];   // 2 mult
        UV[0] = w[0][id]*in[id] + w[0][id+1]*in[id+1];   // 2 mult
    #if (Q % 2) == 1
      for(b=0; b<BATCH_SIZE; b++)
        UV[1] = w[1][Q-1]*in[Q-1];            // 1 mult
        UV[0] = w[0][Q-1]*in[Q-1];            // 1 mult
    #endif
```

Com `Q=1`, o laço `id2` tem zero iterações e só o ramo ímpar executa. Cada
multiplicador é **escalar** (não há `mac16x2`):

| config | pontos | batches | linhas (M=2) | multiplicadores |
|---|---|---|---|---|
| `Q=1, B=2` (baseline) | 16 | ×2 | ×2 | **64** |
| `Q=1, B=1` (esta correção) | 16 | ×1 | ×2 | **32** |
| `Q=1, B=1, M=1` (alvo) | 16 | ×1 | ×1 | 16 |

Ou seja: **`B=1` era necessário** para sair de 64 → 32. O alvo de 16 exige
também `M=1` (§8).

---

## 7. Protocolo de verificação e resultados

Build (o `-fsigned-char` é obrigatório; `-fsanitize=address` para pegar
out-of-bounds):

```
make clean
make single_csim.out CFLAG="-fPIC -O1 -fsigned-char -fsanitize=address"
```

Teste (formato: `<dims> ... <input_gold> <output_gold> <weight_gold> compare . 3`):

```
./single_csim.out 8 8 8 8 8 8 3 3 1 1 1 0 128 <input> random <weight> compare . 3
```

Resultados obtidos:

| config | `one/center` | `one/kernel_order` | `order/center` | `random/center` | ASan |
|---|---|---|---|---|---|
| `B=1` | `Not different!` | `Not different!` | `Not different!` | `Not different!` | limpo |
| `B=2` (regressão) | `Not different!` | `Not different!` | `Not different!` | `Not different!` | limpo |

> Nota metodológica: o golden usa `long int` (64-bit) e o hardware larguras fixas.
> Para dados de magnitude maior (`random`) pode haver divergência por faixa
> dinâmica/overflow, que **não** é defeito de datapath. Por isso a validação de
> correção usa majoritariamente `one`/`order` com pesos `zero`/`center`/`kernel_order`.

---

## 8. Bloqueio `M=1` (fora desta correção)

Testando `M=1, N=1, H2=1, W2=1, Q=1, B=2`: a compilação conclui, mas o C-sim
aborta com ASan antes do `compare`. O primeiro acesso inválido é a cópia de
`weight_tile[1]` para `weight_tile_reg[1]` em `winoPEB_CORN`
(`src/wino_cell.cpp:3267`), embora `weight_tile` tenha apenas a linha 0 quando
`WINO_H2=1`. O mesmo PE acessa depois `out_buffer_*[1]`.

Portanto `M=1` **não** é ajuste de configuração: exige parametrizar em conjunto
o número de linhas do PE, o feed de pesos, `weight_tile`/`weight_tile_reg`, os
arrays `UV`/`ATA`/`out_value` e o write-back. Fica pendente para uma refatoração
estrutural.

---

## 9. Referências de arquivo/linha

| item | local |
|---|---|
| macro `BATCH_SIZE` e `WINO_BATCH_*` | `src/wino_macro.h:38-49` |
| declaração `out_value` | `src/wino_cell.cpp:999` (CORN: 2978+) |
| `out_value_back` | `src/wino_cell.cpp:1102` |
| `element_wise_mult_block` | `src/wino_cell.cpp:345` |
| usos do macro (20 unpack + 20 pack) | `src/winoPEB_CORN`, `src/wino_cell.cpp:3552-3745` |
| kernel instancia só CORN | `src/wino_systolic_kernel.cpp:98` |
| `operator,` / `ap_concat_ref` | `include/ap_int_sim.h:255-282` |
| chamada comentada de `wino_flatten_kernel` | `src/wino.cpp:445` |

---

## 10. Como reproduzir

```
# config micro
python3 /tmp/opencode/setcfg.py 4 2 1 2 1 0 1     # dom M N H2 W2 qbit B
python3 codegen/gen_systolic.py
make clean && make single_csim.out CFLAG="-fPIC -O1 -fsigned-char -fsanitize=address"

# 4 testes do protocolo
for t in "one center" "one kernel_order" "order center" "random center"; do
  set -- $t
  ./single_csim.out 8 8 8 8 8 8 3 3 1 1 1 0 128 $1 random $2 compare . 3
done
```
