# Simulação — C-sim, RTL e potência

Objetivo: validar funcionalmente o WinoCNN (C-sim) e medir **ciclos, tráfego de
memória e potência com atividade real** (RTL sim → SHM → Genus power).

Dois níveis:

| nível | o que valida | onde roda |
|---|---|---|
| **C-sim** | hardware (C) vs golden | local |
| **RTL sim** | RTL do HLS vs modelo C + SHM para potência | paxos (Xcelium) |

Documento irmão: **[`synthesis.md`](synthesis.md)** (HLS, Genus, black-box).
O relato das mudanças está em **[`history.md`](history.md)**.

---

## 1. Escolher o domínio

Vem de `WINO_DOMAIN_SIZE` em `src/wino_hw_config.h` (ver
[`synthesis.md`](synthesis.md) §1). Config micro validada:
`M=2, N=1, H2=2, W2=1, Q=1, B=1`.

```bash
python3 asic_scripts/setcfg.py 4 2 1 2 1 0 1   # dom4 = F(2x2,3x3)
python3 asic_scripts/setcfg.py 6 2 1 2 1 0 1   # dom6 = F(4x4,3x3)
python3 codegen/gen_systolic.py
```

Os artefatos são separados por domínio: `testbench/stim/dom<N>/`,
`sim_asic/dom<N>/`, `reports/genus/dom<N>/`. O RTL (HLS) é específico do
domínio — **re-rode o HLS** ao trocar (ver `synthesis.md` §3).

---

## 2. C-sim (validação funcional, local)

O C-sim compara o hardware (C) com o golden model. O modo `compare` imprime
`Not different!` e retorna 0 quando coincidem, ou 3 quando divergem.

```bash
make clean && make single_csim.out CFLAG="-fPIC -O1 -fsigned-char -fsanitize=address"

# protocolo (4 testes determinísticos)
for t in "one center" "one kernel_order" "order center" "random center"; do
  set -- $t
  ./single_csim.out 8 8 8 8 8 8 3 3 1 1 1 0 128 $1 random $2 compare . 3 || echo "FAIL $t"
done
```

Argumentos: `ih iw id  oh ow od  kh kw  stride  padh padw  relu  scale  input_gold  output_gold  weight_gold  dump_method  folder  use_kernel_size`.

O modo ASIC (`-DWINO_ASIC`) troca só os pragmas de memória; o C-sim ignora.

> **Nota de escopo.** O C-sim de `single_main` usa `scale_oback_int` fixo (não
> calculado); ele valida o datapath, não é um teste de acurácia para dados
> aleatórios de grande magnitude. O micro é funcional para `h/w` até 64×64
> nos casos já testados com profundidades alinhadas a 8. Também foi validado
> `32×32, Cin=3, Cout=12` com dados de baixa amplitude (ver `micro_progress.md`).

---

## 3. Estímulo

O C-sim escreve os buffers DDR em `input.bin`, `weight.bin`, `param.bin`
(little-endian). O RTL os carrega via `$readmemh`, então
`asic_scripts/bin2hex.py` os converte:

```bash
python3 asic_scripts/bin2hex.py <dir>   # <dir>/*.bin -> <dir>/*.hex
```

Os `.hex` versionados ficam em `testbench/stim/dom<N>/` (teste
`random random center`, conv 8×8×8, kernel 3×3). Tamanhos: `input.hex` e
`weight.hex` = 64 × 128 bits; `param.hex` = 128 × 32 bits.

### 3.1 Dataset externo (lib `fast-convolution-rtl`)

O dataset pode vir da lib de referência em `../fast-convolution-rtl`. O `sim`
(2-D) dela passou a exportar, sob `<sim>/winocnn/`:

| arquivo | conteúdo |
|---|---|
| `feature.bin` | int8, `Cin*H*W`, layout `c*H*W + h*W + w` |
| `weight.bin` | int8, `Cout*Cin*kh*kw`, layout `(od*Cin+id)*kh*kw + ks` |
| `params.json` | descritor (dims, stride, pad, scale) |
| `README.md` | layout e como alimentar o WinoCNN |

Esses layouts são os do `software/buffer.cpp` do WinoCNN, então o
`single_main` carrega direto via o modo `file:`:

```bash
# 1) empacotar + validar contra o golden do WinoCNN
./single_csim.out <H> <W> <Cin> <Oh> <Ow> <Cout> 3 3 1 0 0 0 128 \
    file:<sim>/winocnn/feature.bin random file:<sim>/winocnn/weight.bin compare . 3
# 2) gerar o estímulo (empacota o DDR, roda C-sim e salva golden)
python3 asic_scripts/bin2hex.py .
```

Ressalvas:
- a memória agrupa canais em tiles de 8, mas as dimensões lógicas podem ser
  menores/não múltiplas de 8. Para a saída, `output_burst_length` precisa cobrir
  o último tile físico alinhado, e o unpack do software precisa percorrer esse
  tile parcial. O caso `Cin=3, Cout=12` foi validado em 32×32 após essas
  correções; não generalize essa evidência para todas as profundidades.
- `single_main` usa `scale_oback_int` fixo e o campo `scale` do `params.json`
  FastConv não é automaticamente uma escala WinoCNN. O fixture original
  `sim-032-3-12-normal-trunc-nbits16` ainda não passa: com `scale=128`, 3.498 de
  10.800 outputs diferem. O loader de `weight.bin` também precisa respeitar a
  pré-quantização WinoCNN para `G_WIDTH=7`; o arquivo FastConv contém pesos
  signed-8, e não pesos já escalados para esse caminho. Detalhes e os limites do
  teste derivado estão em [`micro_progress.md`](micro_progress.md#diagnostico-do-fixture-fastconv-original).
  Não use a passagem com operandos reduzidos como validação do fixture original.

---

## 4. Testbench RTL (`asic_scripts/tb_wino_asic.v`)

Modela as quatro RAMs externas com o protocolo `ap_memory`, carrega o
estímulo, pulsa `ap_start`, espera `ap_done`, conta ciclos/acessos e escreve
um SHM para o Genus.

**Latência do modelo de RAM** (escalonada pelo HLS; verificada contra o modelo
`AESL_automem_*` do cosim):

| porta | latência |
|---|---|
| `input_DDR*` | 3 ciclos |
| `weight_DDR0` | 3 ciclos |
| `mem_params` | 1 ciclo |

Contadores de simulação (não sintetizados): ciclos, reads de entrada/peso/params,
writes de saída, endereços máximos e out-of-range. O testbench registra cada
write como `banco endereço dado` em `out_writes.txt`.

Também são contabilizados **reads e writes por SRAM** em
`sram_access_counts.json`: as seis interfaces externas (`input_DDR0/1`,
`weight_DDR0`, `mem_params`, `output_DDR0/1`) aparecem individualmente; cada
instância das RAMs inferidas pelo HLS aparece pelo caminho hierárquico, além de
um agregado por classe de RAM. A porta externa `output_DDR*` não tem sinal de
read-data no RTL WinoCNN, portanto seus reads são reportados como zero e suas
escritas são contadas a partir de `out_writes.txt`, o mesmo trace transacional
que é validado contra o golden. Nas RAMs internas contam-se as operações
por porta: `ce && !we` como read quando existe porta de saída `q`, e `ce && we`
como write. Nos modelos read-only, `ce` é read; nas RAMs só de escrita não se
inventam reads. A contagem é de transações de porta (duas operações podem
ocorrer no mesmo ciclo em uma dual-port), não de endereços únicos.

Os modelos HLS usados em simulação são **cópias temporárias** instrumentadas
por `instrument_sram_models.py`; o RTL gerado original e o netlist permanecem
intocados. Os contadores e o relatório JSON existem somente para simulação e
não acrescentam lógica, área ou potência sintetizada. Os JSONs ficam em
`sim_asic/dom<N>/sram_access_counts.json` (RTL) e
`sim_asic/dom<N>/gate/sram_access_counts.json` (gate/SDF).

---

## 5. Como rodar (host paxos)

```bash
ssh -p 8888 -i ~/.ssh/gaph tarsio.onofrio@paxos.inf.pucrs.br
cd ~/gaph/WinoCNN
source /etc/profile.d/modules.sh && module use /soft64/modulefiles
module load vivado_hls
module load cadence/xcelium/2303
module load cadence/genus/211
# gere stimulus e golden com o mesmo C-sim/dataset antes da RTL:
bash asic_scripts/prepare_asic_stimulus.sh \
  32 32 3 30 30 12 3 3 1 0 0 0 128 \
  reports/winocnn_modulo5_4_seed1_32x32_cin3_cout12/feature.bin \
  reports/winocnn_modulo5_4_seed1_32x32_cin3_cout12/weight.bin \
  testbench/stim/dom4 3
bash asic_scripts/run_asic_flow.sh all
# -> HLS, RTL/golden, Genus synthesis, gate-level/SDF + golden e power
```

O runner deriva `<N>` de `src/wino_hw_config.h`, copia o estímulo de
`testbench/stim/dom<N>/` e os **`*_ram.dat`** gerados pelo HLS (as RAMs internas
fazem `$readmemh("./*_ram.dat")`; sem eles o RTL simula com memória não
inicializada e a saída sai errada).

`prepare_asic_stimulus.sh` primeiro roda `single_csim.out` em modo `compare` e
só continua com `Not different!`; depois gera a imagem DDR esperada e os `.hex`
com os mesmos arquivos de features/pesos. `run_sim_asic.sh` falha se
`output_golden.bin` não existir,
se a RTL não emitir `WINO_SIM_DONE`, ou se a comparação falhar. Ele compara
bit a bit todos os writes RTL por banco/endereço com a saída DDR do modelo C,
confere a cobertura esperada e salva `rtl_golden_check.json`. Síntese e power
também recusam prosseguir sem esse marcador em PASS.

---

## 6. Validação (RTL vs modelo C)

A união dos bancos ping-pong `output_DDR0` + `output_DDR1` bateu com o
`autotvout_output_DDR0` do cosim do HLS em **128/128 palavras** nos testes
anteriores (dom4 e dom6). Para cada execução de potência, a verificação atual
compara todos os writes RTL bit a bit contra a imagem DDR do modelo C gerada
para o mesmo estímulo.

O cosim do HLS em si **falha** (rc=3), mas por um artefato conhecido: o
testbench C aponta `output_DDR0` e `output_DDR1` para o **mesmo buffer**,
enquanto o cosim os modela como memórias separadas. O testbench RTL usa
memórias separadas e por isso é a referência válida.

---

## 7. Simulação gate-level com SDF

Depois da simulação RTL validada e da síntese Genus, `run_gate_sim_asic.sh`
simula a netlist mapeada com o SDF nominal (`tt0p90v25c`) e modelos Verilog das
células padrão TSMC. Como o Genus mantém os buffers RAM inferidos como
black-box, o runner também compila seus modelos comportamentais gerados pelo
HLS; as portas de memória externas são dirigidas pelos modelos síncronos do
testbench. Essas RAMs não fazem parte da netlist de potência. O runner gera SHM
da instância gate-level, verifica a conclusão, exige log de anotação SDF e
compara os writes da netlist bit a bit com o mesmo golden C antes de aprovar potência.
O caminho do modelo Verilog pode ser sobrescrito por `WINO_CELL_MODELS`.

O SDF é escolhido com `MTM_CONTROL=MAXIMUM` e `-maxdelays` para a view nominal,
seguindo o padrão usado nos fluxos ASIC locais. Isto é simulação temporizada de
netlist sintetizada, ainda sem parasitas pós-route. As mensagens `WSDF-201` do
Genus indicam instâncias sem descrição de atraso; devem ser revisadas no log de
geração e no log de anotação Xcelium, e impedem tratar a simulação como
totalmente anotada sem essa evidência. O Xcelium também informa a cobertura de
timing checks separadamente dos path delays; ambos os percentuais devem ser
reportados, não apenas a mensagem de anotação bem-sucedida.

Os modelos comportamentais RAM usados nesta etapa não têm tCO caracterizado.
Para evitar leitura ideal de saída no mesmo instante da borda, o runner cria
cópias temporárias dos modelos HLS e aplica 30 ps aos seis outputs de leitura;
o modelo das memórias externas no testbench aplica 200 ps. Isso não modifica os
RTL HLS, não entra na síntese e **não representa caracterização de SRAM/DDR**.
Esses valores são hipóteses de simulação e limitam a interpretação temporal e
de potência até serem substituídos por modelos de memória apropriados.

Na mesma execução, o runner registra acessos por porta externa e por instância
RAM HLS, incluindo classe, caminho hierárquico, leituras e escritas em
`sim_asic/dom<N>/gate/sram_access_counts.json`. O JSON é separado da contagem
de tráfego externo e pode mostrar contagens diferentes entre RTL HLS e a
netlist gate-level, pois a hierarquia/replicação de RAM pode mudar na síntese.

O fluxo completo agora executa `run_asic_flow.sh all`: HLS → RTL/C-golden →
Genus → gate-level/SDF/C-golden → potência. As etapas podem ser chamadas
separadamente com `gate-sim` e `power`; potência recusa continuar sem o JSON
PASS da comparação gate-level.

## 8. SHM e potência

`asic_scripts/power.tcl` recria um MMMC de canto `tt`, lê o DB mapeado
(`reports/genus/dom<N>/gate_level/...`) e anota a atividade do SHM da
simulação gate-level/SDF (`sim_asic/dom<N>/gate/dut.shm`):

```bash
module load cadence/genus/211
genus -f asic_scripts/power.tcl
# -> reports/genus/dom<N>/wino_systolic_top_power_shm_tt.rpt
```

A anotação cobre ~100 % dos flops e portas primárias. Resultado (tt0p9v25c):

| categoria | dom4 | dom6 |
|---|---:|---:|
| register | 7.881 mW | ~27.2 mW |
| logic | 0.184 mW | ~0.41 mW |
| clock | 0.392 mW | — |
| memory / bbox | 0.000 mW | 0.000 mW |
| **total** | **8.457 mW** | **28.36 mW** |

Comparação: sem estímulo (`lp_default_probability 0.5`) o relatório de síntese
dava 27.5 mW (dom4) e 72.6 mW (dom6) em tt — o número com SHM é o realista.

---

## 9. Resultados (micro, 2 PEs, conv 8×8×8)

| métrica | dom4 (F(2×2,3×3)) | dom6 (F(4×4,3×3)) |
|---|---:|---:|
| ciclos (`ap_start`→`ap_done`) | 34 122 | 75 419 |
| input reads | 88 | 88 |
| weight reads | 339 | 516 |
| param reads | 129 | 129 |
| output writes | 128 | 128 |
| potência com SHM (tt) | 8.46 mW | 28.36 mW |
| SHM | `sim_asic/dom4/dut.shm` | `sim_asic/dom6/dut.shm` |

---

## 10. Armadilhas

1. **`*_ram.dat` ausentes** → RAMs internas não inicializadas → saída errada. O
   runner os copia; não rode o `xrun` à mão sem eles.
2. **Latência de RAM errada** (usar 1 ciclo em tudo) → o DUT lê dados velhos.
   Entrada/peso = 3, params = 1.
3. **O write-back continua depois de `ap_done`.** Parar cedo perde as últimas
   palavras (a falsa "escrita incompleta", 102 vs 128). O testbench espera
   **2000 ns** após `ap_done` antes de encerrar (o domínio 6 precisou; o valor
   maior também cobre o dom4).
4. **Nunca confunda** `reports/genus/dom<N>/` (síntese) com `sim_asic/dom<N>/`
   (simulação) — são domínios diferentes de artefato.
5. **`make clean` apaga `license.txt`** — restaure antes de commitar.

---

## 11. Dados normais e métricas compatíveis com FastConv

`asic_scripts/winocnn_normal_metrics.py` reproduz a geração `cmd_sim_normal` do
FastConv (`RandomState(seed)`, primeiro `N(0,1)` para a entrada NCHW, depois
pesos OIHW), calcula uma referência float de convolução válida e executa o
C-sim WinoCNN. O fluxo grava métricas no formato familiar do FastConv: MAE,
RMSE, erro absoluto/relativo máximo, R² e erro contra a saída golden
quantizada. Exemplo:

```bash
python3 asic_scripts/winocnn_normal_metrics.py --height 32 --width 32 \
  --cin 3 --cout 12 --seed 3
```

Os tensores float e a seed seguem o gerador do FastConv. Os operandos **não**
são iguais aos do pacote FastConv: a quantização FastConv de 8 bits aplica
`trunc(x*256)`, cujos valores podem exceder signed-8; para esta execução, o
WinoCNN usa input signed-8 e peso signed-7 (limite imposto por `G_WIDTH=7`), com
escala/headroom declarados no JSON. Assim, a comparação de qualidade usa a
convolução float original, não presume equivalência bit a bit entre datasets.

Execução diagnóstica em `32×32`, `Cin=3`, `Cout=12`, seed 3, kernel 3×3,
stride 1, sem padding/bias/ReLU: o C-sim **falhou** contra o golden inteiro,
com 863 saídas divergentes de 10.800. Por isso os MAE/R² abaixo são apenas
diagnósticos e **não são resultados válidos para o paper**:

| origem da saída | MAE | RMSE | R² | mismatches vs golden inteiro |
|---|---:|---:|---:|---:|
| C-sim hardware | 87.060 | 102.536 | -425.361 | 863 / 10.800 |
| modelo inteiro WinoCNN | 87.630 | 103.291 | -431.662 | — |

O R² fortemente negativo e a divergência hardware/modelo mostram que ainda há
um problema de correção/escalas para este workload aleatório; esses números
não devem ser comparados como acurácia do acelerador. A fórmula é a mesma do
FastConv (`1 − SSE/SST`), global sobre as saídas pareadas; R² é ilimitado
inferiormente, então não deve ser truncado para zero. O JSON guarda dimensões,
seed, escalas, métricas e status da validação. O script também exporta os
operandos int8 realmente fornecidos ao WinoCNN e códigos de saída para permitir
reprodução e depuração. Só depois de corrigir o mismatch e obter `Not different!`
as métricas devem ser usadas para comparação acadêmica.

### Diagnóstico antes de `Scale_oback`

Para localizar a origem do R² negativo, o script também compara a correlação
inteira exata em int64 dos mesmos operandos quantizados (`input_int8` e
`weight_int8`) com o `output_buffer` do modelo WinoCNN **antes** de
`Scale_oback`. Na execução acima, a convolução direta quantizada cobre
`[-2790, 2947]` e tem valores positivos e negativos (50,0% positivos), enquanto
o modelo Winograd antes da escala cobre apenas `[-3, 0]` (nenhum positivo).
A correlação entre as saídas é 0,445; mesmo o melhor ajuste afim meramente
diagnóstico explica só R²=0,198. Isso localiza o problema antes da escala final
de saída: alterar apenas `Scale_oback` não deve resolver a discrepância.

Como teste de sensibilidade, repetir com alvos de quantização maiores para
entrada/peso (127/63) manteve a saída pré-escala em `[-3, 0]`, reduziu a
correlação para 0,053 e aumentou os mismatches C-sim/modelo inteiro para
7.021/10.800. Portanto, aumentar a magnitude dos operandos não é uma correção.
Uma sondagem de flips/transposição espacial e permutação simples de canais
também não melhorou materialmente a correlação; isso não exclui outros erros de
layout. A causa exata ainda não está isolada, mas os dados apontam para a
aritmética/quantização intermediária da transformada ou outra interpretação
dos tensores antes da saída, não para um R² calculado incorretamente. O
diagnóstico de maior faixa está em `/tmp/winocnn-fullrange` e é exploratório,
não um resultado de comparação.

### Dataset padrão para publicação (2026-10-10)

Para os experimentos de publicação com `32×32`, `Cin=3`, `Cout=12`, kernel
`3×3`, stride 1 e sem padding, fica adotado o dataset determinístico
WinoCNN-modulo em
`reports/winocnn_modulo5_4_seed1_32x32_cin3_cout12/`: features signed de 5 bits
(`[-16, 15]`), pesos signed de 4 bits (`[-8, 7]`) e seed 1. A geração adapta
as rotinas aleatórias do WinoCNN por redução módulo (`random()%32` para
features, interpretado como complemento de dois signed-5; `random()%16-8`
para pesos). A proveniência completa está no `provenance.json` do dataset.

O C-sim comparou sem divergências (`Not different!`, 0 mismatches) para
padding 0 e também passou no teste adicional com padding 1. O caso sem padding
é o padrão do experimento e produz `12×30×30` saídas; padding 1 é somente uma
validação extra, com `12×32×32` saídas. Esta escolha é um workload derivado e
quantizado para o WinoCNN, não deve ser descrita como o dataset nativo do paper
nem como equivalência bit a bit com os operandos FastConv.

O fluxo RTL → SHM → Genus foi executado para essa condição em 2026-10-10, com
HLS F(2×2,3×3), `M=2, N=1, Q=1, B=1` (32 multiplicadores), TSMC 28 nm e
corner nominal `0,90 V / 25 °C`. O C-sim passou (`Not different!`, 0 mismatches).
A síntese HLS gerou o RTL e o relatório C-synthesis; o empacotamento opcional
de IP terminou com o erro conhecido `bad lexical cast` do Vivado 2019.2, mas os
artefatos Verilog estavam presentes e foram aceitos pelos fluxos Xcelium/Genus.
A simulação RTL completou em 50.293 ciclos (latência `ap_start`→`ap_done` de
100,586 µs a 2 ns), com 1.120 leituras de input, 2.101 de pesos, 129 de
parâmetros e 3.840 writes físicos.

Depois, o trace RTL arquivado foi comparado bit a bit com a imagem DDR gerada
pelo modelo C usando exatamente os `.hex` do run: **3.840/3.840 writes
conferem, sem divergências**. Essa checagem retrospectiva está em
`power_flow_20261010/rtl_sim/rtl_golden_check.json`. O run original não tinha
esse gate integrado; o runner atualizado exige comparação antes de power.

Na campanha isolada de 2026-10-10, os primeiros modelos comportamentais de RAM
geravam violações setup/hold e `X` na netlist; sem SDF, a temporização dos modelos
de célula também gerava divergência. A causa operacional era a combinação de
saídas RAM idealizadas sem clock-to-output explícito com os delays/checks das
células e clocks gated. Com saídas e pipelines inicializados, tCO explícito nos
modelos de RAM e contadores do testbench que ignoram enables `X`, o runner gate
SDF completou em 50.295 ciclos, com 1.120 leituras de input, 2.101 de pesos,
129 de parâmetros e 3.840 writes. Os **3.840/3.840 writes passaram** na
comparação bit a bit com o golden C. O SDF nominal foi aplicado em `tb.dut`;
271.429/271.437 path delays (100,00%) e 66.834/182.168 timing checks (36,69%)
foram anotados pelo Xcelium. Não houve avisos de violação setup/hold durante a
execução, mas a baixa cobertura de timing checks e os tCO assumidos impedem
tratar esse resultado como signoff de timing ou como modelo de memória
caracterizado.

Com a comparação gate-SDF em PASS, o Genus Power executou sobre o SHM da mesma
simulação, no canto `tt0p9v25c`: potência média total **10,6353 mW**, com
register 9,4910 mW, logic 0,6450 mW e clock 0,4994 mW. Memórias aparecem como
0 mW porque são externas/black-box e não estão sintetizadas. Essa é uma
estimativa de potência activity-based da netlist sintetizada; não é medida
pós-route e depende dos modelos/atrasos assumidos acima. Multiplicando pela
janela SHM completa de 102,62916 µs (reset + operação + drenagem), a energia
estimada é **≈1.091,49 nJ**; é derivada de potência média × tempo, não uma
medição direta de energia. Logs, checker, trace e relatório estão em
[`gate_sdf_attempt_20261010/`](../reports/winocnn_modulo5_4_seed1_32x32_cin3_cout12/gate_sdf_attempt_20261010/).

Os números de potência anteriores, gerados com atividade RTL, permanecem
históricos e não devem ser confundidos com o novo resultado baseado em
gate-level/SDF.

O relatório SHM dá potência média total de **10,2384 mW**: 9,12138 mW interna,
0,763946 mW de switching e 0,353082 mW leakage. A janela completa do SHM foi
102,627 µs (inclui reset e os 2 µs de drenagem após `ap_done`), portanto a
energia total nessa janela é **1.050,74 nJ** (1.014,50 nJ dinâmica e 36,24 nJ
leakage). A energia é do intervalo inteiro analisado, não somente do trecho
ativo entre start e done. As memórias externas/black boxes continuam excluídas:
Genus reporta 0 mW em `memory`/`bbox`, o que não significa memória física sem
consumo. A anotação cobriu 100% dos flops e portas primárias; 178 ICGs ficaram
sem atividade anotada e o log reporta alguns pinos `ap_return_0` não dirigidos.

Artefatos (incluindo logs, estímulos `.hex`, SHM, DB e netlist mapeado) estão em
[`reports/winocnn_modulo5_4_seed1_32x32_cin3_cout12/power_flow_20261010/`](../reports/winocnn_modulo5_4_seed1_32x32_cin3_cout12/power_flow_20261010/).
Os relatórios de power antigos para `8×8×8` continuam sendo outro workload.
As tentativas com features/pesos de 6/5 e 8/7 bits divergiram do golden; ver os
respectivos `csim_validation.json`.
