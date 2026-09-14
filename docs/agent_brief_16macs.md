# Brief para agente — reduzir o WinoCNN a 16 MACs

Este documento é um runbook. Siga na ordem. Não pule a verificação de regressão.

## 0. Objetivo e critério de sucesso

**Alvo:** `WINO_DOMAIN_SIZE=4` (F(2×2,3×3)), `WINO_HEIGHT=1` (M), `WINO_WIDTH=1` (N),
`INDEPTH_MINITILE_SIZE=1` (Q), `BATCH_SIZE=1` (B), `WINO_H2=1`, `WINO_W2=1`.
Isso dá **1 PE** e o hadamard do domínio 4×4 = **16 multiplicadores**.

**Sucesso:** o C-sim (`compare`) imprime `Not different!` para os testes de referência (§4)
com essa config, **sem regressão** do baseline (§2).

**Se 16 MACs não fechar em 2 h:** não force. Entregue o melhor estado funcional e documente
(ver §9). O valor da comparação de PPA não depende de chegar exatamente a 16.

## 1. Mapa do repositório

- Branch de trabalho: `experiment/winocnn-micro` (não trabalhe em `main`/`master`).
- Hardware gerado: `src/wino_systolic_kernel.cpp` (gerado; **não editar à mão**, exceto as
  edições manuais de §3.4).
- Config: `src/wino_hw_config.h` (dims) e `src/wino_macro.h` (derivados + `BATCH_SIZE`).
- Datapath/PE: `src/wino_cell.cpp` (~5.4k linhas).
- Buffers/weight feed: `src/wino_buffer.cpp`.
- Feed de input / endereçamento: `src/wino_IO.cpp`.
- Transformadas: `src/wino_transform.cpp`.
- Software (packing DDR, descritores): `software/buffer.cpp`, `software/param.cpp`, `software/exec.cpp`.
- Testbench: `testbench/single_main.cpp` (standalone `compare`) e `testbench/main.cpp` (fluxo completo).
- Docs existentes: `docs/micro_progress.md`, `docs/configuration_exploration.md`,
  `docs/architecture.md`, `docs/address_generation.md`. **Leia os dois primeiros antes de codar.**

## 2. Estado conhecido (ponto de partida)

| config (M,N,Q,B) | estado | observação |
|---|---|---|
| 4,2,4,2 (original) | ✅ MATCH | baseline do source |
| 4,2,2,2 | ✅ MATCH | Q=2, hadamard com 16 `mac16x2` |
| 2,1,1,2 | ✅ MATCH | **baseline funcional atual** (1 PE) |
| 1,1,1,2 | 🟡 | M=1: caminho de peso |
| 2,1,1,1 | 🟡 | B=1: zero/center OK, não-triviais falham |
| 1,1,1,1 | ❌ | **alvo** (16 MACs) |

Baseline seguro para regressão: **M=2/H2=2, N=1/W2=1, Q=1, B=2**.

## 3. Comandos canônicos

### 3.1 Configurar
```
python3 /tmp/opencode/setcfg.py <dom> <M> <N> <H2> <W2> <qbit> <B>
# Q = 1<<qbit  → qbit=0 ⇒ Q=1
# alvo:  4 1 1 1 1 0 1
# baseline: 4 2 1 2 1 0 2
```
`setcfg.py` escreve `src/wino_hw_config.h` e ajusta `BATCH_SIZE` em `src/wino_macro.h`.
Se o script não existir no ambiente, edite esses dois arquivos diretamente (mesmos campos).

### 3.2 Regenerar o kernel
```
python3 codegen/gen_systolic.py
```

### 3.3 Compilar
```
make clean
make single_csim.out CFLAG="-fPIC -O1 -fsigned-char"
```
Use `-O1` para build rápido durante depuração; `-O2` só para validação final.
`-fsigned-char` é obrigatório (o datapath assume `char` com sinal).

### 3.4 Reaplicar edições manuais (após cada codegen)
O `gen_systolic.py` **não** reproduz o `.cpp` commitado. Depois de gerar, reaplique:
- os 4 pragmas `#pragma HLS interface m_axi port=weight_DDR0..3` dentro de `wino_systolic_kernel`;
- (opcional) o `std::cout` de debug do wrapper.

Sem os pragmas `m_axi` a síntese AXI quebra (o C-sim ignora, então isso não afeta o `compare`).

### 3.5 Testar
```
./single_csim.out 8 8 8 8 8 8 3 3 1 1 1 0 128 <input> random <weight> compare . 3
```
- `<input>`: `one`, `order`, `random`
- `<weight>`: `zero`, `center`, `kernel_order`, `idepth_order`, `odepth_order`, `depth_order`
- o `compare` imprime `Not different!` (passa) ou `Different!` (falha).

## 4. Protocolo de verificação (obrigatório a cada mudança)

Rode sempre, nesta ordem, e trate qualquer falha antes de continuar:

1. **Baseline** (M=2/H2=2, N=1/W2=1, Q=1, B=2) — 4 testes:
   `one/center`, `one/kernel_order`, `order/center`, `random/center` → todos MATCH.
2. **Config em foco** (ex.: alvo) — os mesmos 4 testes.
3. Só considere "pronto" quando o alvo passar os 4 **e** o baseline continuar passando.

**Aviso sobre `random`:** o golden usa `long int` (64-bit) e o hardware larguras fixas; eles
divergem por overflow/saturação com dados de maior magnitude. O `single_main` usa
`scale_oback_int` fixo (não calculado), então `random` pode falhar por *faixa* e não por
correção de datapath. Para isolar bug de datapath, prefira `one`/`order` + pesos
`zero`/`center`/`kernel_order`. Não "conserte" overflow mudando o golden.

## 5. Os três bloqueios, com hipóteses e pontos de código

### 5.1 Q=1 com `h>8` ou `w>8` (ciclismo do input buffer)
- **Sintoma:** MATCH para 4×4/6×6/8×8; falha para 16×8, 8×16, 10×10+.
- **Onde:** `src/wino_IO.cpp` — `input_feed_underconstruction` e o loop de
  `load_input_row_from_ddr`; variáveis `buffer_address_mini_tile`,
  `buffer_address_mid_offset`, `buffer_address_mid_increment_step`
  (por volta das linhas 243–750).
- **Hipótese:** com Q=1, `buffer_address_mini_tile` é sempre 0, então o teste
  `buffer_address_mini_tile == INDEPTH_MINITILE_SIZE-1` (==0) é sempre verdadeiro e
  `buffer_address_mid_offset += inwidth_ceildiv_inbufferwidth` dispara cedo demais —
  quebrando o endereçamento quando há ciclismo de banco/linha. Verifique também a fórmula
  de `buffer_address_mid_increment_step` para Q=1 (o doc cita `7·ceildiv+1`).
- **Correção já feita (não desfazer):** `INDEPTH_MINITILE_IDX_BITWIDTH = max(1, ...)` em
  `wino_macro.h` evita `ap_uint<0>`. O que falta é o **endereçamento**, não a largura do índice.
- **Nota:** esse bloqueio **não** impede a contagem de 16 MACs (testes ≤8×8 passam). Se o
  prazo apertar, deixe-o por último.

### 5.2 M=1 (`WINO_HEIGHT=1`) — caminho de peso
- **Onde:**
  - `src/wino_buffer.cpp`: `load_weight_ddr_one_port`, branches `#if WINO_HEIGHT==8||2||1`
    (linhas ~867, ~959, ~991). Compare o ramo `WINO_HEIGHT==1` com o de `==2`.
  - `src/wino_macro.h`: `WEIGHT_PORT_NUM`, `WEIGHT_FEED_NUMBER_PER_PORT(_BITWIDTH)`,
    `OUT_PORT_BATCH_NUM`, `OUTDEPTH_MINITILE_SIZE_BITWIDTH = WINO_HEIGHT_BITWIDTH`
    (para M=1 isso vira 0 bits → cuidado com `ap_uint<0>`; use `max(1, ...)` como no Q=1).
  - `codegen/gen_systolic.py`: ramos `WINO_HEIGHT==1` em `Config_t`, no `weight_stream_out`
    e no bloco `weight_feed_one_port` (linha ~327).
- **Hipótese:** `OUTDEPTH_MINITILE_SIZE = WINO_HEIGHT = 1` muda o passo do weight DDR
  (`WEIGHTDDR_*_STEP`) e a contagem `weightbuffer_outdepth_minitile_number`; o ramo M=1
  provavelmente ainda assume 2. Além disso, `ap_uint<0>` em larguras derivadas de
  `WINO_HEIGHT_BITWIDTH` degenera em C-sim (mesma classe do bug Q=1 já corrigido).
- **Dica:** comece por M=1 **com Q=1 e B=2** (isola M), depois combine.

### 5.3 B=1 (`BATCH_SIZE=1`) — empacotamento de batch
- **Sintoma:** zero/center passam; `random`/`kernel_order` (magnitude maior) falham. Já se
  confirmou que **não é escala** (persiste com várias `scale_oback`). B=2 passa os mesmos testes.
- **Onde:**
  - `software/buffer.cpp`: `featuremap_int_to_hw_pointers` (packing de entrada, interleave
    `data1,data2`) e `featuremap_hw_to_int_pointers` (unpacking de saída). Já foi feito o
    unpacking B-aware; revise o **packing** de entrada.
  - `src/wino_IO.cpp`: escrita de saída / `out_buffer` e `outbuffer_data_*` (larguras
    `OUT_WIDTH*BATCH_SIZE`).
  - `testbench/single_main.cpp`: golden/compare B-aware (já ajustado).
- **Hipótese:** com B=1 a porta de saída é 32-bit (4×8-bit) e a de entrada 16-bit; o
  empacotamento interleaved de 2 batches está hardcoded em algum ponto e desalinha o byte
  certo do batch 0. Instrumente: imprima os primeiros índices divergentes
  (`gold` vs `hw`) e localize o padrão (borda? canal? deslocamento de 1?).
- **Dica:** teste B=1 com M=2/Q=1 primeiro (isola B do M=1).

## 6. Ordem de ataque recomendada (dentro do prazo)

1. **B=1** com M=2/Q=1 (isola uma variável; já há trabalho feito).
2. **M=1** com Q=1/B=2 (isola M).
3. **M=1 + B=1** (alvo).
4. Se sobrar tempo: **Q=1 h,w>8** (independente da contagem de MACs).

Cada passo: aplicar → build → rodar §4 → **commit** (mensagem `wip(micro): ...`).

## 7. Regras e armadilhas

- **Não regredir o baseline.** Rode §4 item 1 sempre.
- **Mudanças genéricas e backward-compatible.** Não use `#if` específico demais; prefira
  generalizar (como foi feito em `UV_MUL_TILE_DIM`/`INDEPTH_MINITILE_IDX_BITWIDTH`).
- **`ap_uint<0>`/`ap_int<0>` degeneram em C-sim** (incrementam sem limite). Sempre que uma
  largura derivada puder virar 0 (Q=1, M=1), proteja com `max(1, ...)`.
- **Não edite o golden para mascarar overflow.** Divergência de faixa ≠ bug.
- **Não edite `src/wino_systolic_kernel.cpp` à mão** (exceto os pragmas `m_axi` de §3.4);
  ele é regenerado.
- **Não mexa em AXI/memória externa** neste escopo (isso é a fase seguinte: wrapper de
  memória síncrona + síntese ASIC).
- **Commits pequenos e atômicos**, um por hipótese testada. Não commite `license.txt`
  apagado por `make clean` (restaure com `git checkout HEAD -- license.txt`).
- **Registre o que falhou** em `docs/micro_progress.md` (tabela de configs + hipótese).

## 8. Orçamento de 2 horas (sugestão)

| tempo | atividade |
|---|---|
| 0:00–0:15 | Ler `docs/micro_progress.md` + `configuration_exploration.md`; restaurar baseline e rodar §4 item 1. |
| 0:15–0:45 | **B=1** com M=2/Q=1: instrumentar o compare, localizar o desalinhamento, corrigir packing. |
| 0:45–1:15 | **M=1** com Q=1/B=2: auditar ramo `WINO_HEIGHT==1` no weight path + larguras `ap_uint<0>`; corrigir. |
| 1:15–1:45 | **M=1 + B=1**: combinar; rodar §4 completo. |
| 1:45–2:00 | Consolidar: rodar regressão, atualizar `docs/micro_progress.md`, commit. |

Se um passo estourar o tempo, **pare e documente** o estado (não deixe o repo quebrado).

## 9. Fallback aceitável

Se 16 MACs não fechar:
- Entregue **Q=1, M=2/H2=2, N=1/W2=1, B=2** (1 PE, funcional) como baseline final, **ou**
- **Q=2** com `mac16x2`: o hadamard 4×4 fica com 16 unidades `mac16x2` (≈16 MACs físicos),
  sem rework do weight path — micro válido com muito menos risco, **se** a comparação de
  área aceitar `mac16x2` como multiplicador.

Em qualquer caso: **documente o número de MACs efetivo e a config exata** para que a
comparação de PPA seja honesta.

## 10. Definição de pronto

- [ ] Alvo (ou fallback) passa §4 com `Not different!`.
- [ ] Baseline continua MATCH.
- [ ] `docs/micro_progress.md` atualizado (tabela + hipóteses + contagem de MACs).
- [ ] Commits atômicos na branch `experiment/winocnn-micro`, `license.txt` intacto.
- [ ] Relatório curto: config final, MACs efetivos, o que ficou pendente e por quê.
