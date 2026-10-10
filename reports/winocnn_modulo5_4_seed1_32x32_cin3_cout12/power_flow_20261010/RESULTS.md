# Power flow — WinoCNN modulo 5/4

Execução de 2026-10-10 para o dataset padrão de publicação: `32×32`,
`Cin=3`, `Cout=12`, kernel `3×3`, stride 1, padding 0, features signed-5
(`[-16,15]`), pesos signed-4 (`[-8,7]`), seed 1, escala 128. O C-sim foi
reexecutado com os mesmos binários e terminou com `Not different!`.

## Configuração e ferramentas

- WinoCNN F(2×2,3×3), `WINO_HEIGHT=2`, `WINO_WIDTH=1`, `Q=1`, `BATCH_SIZE=1`;
  configuração arquitetural de 32 multiplicadores.
- HLS: Vivado HLS 2019.2; RTL sim: Xcelium 23.03-s003; síntese/power: Genus
  21.12-s068_1, biblioteca TSMC 28 nm, `tt0p9v25c` (0,90 V, 25 °C), período
  de clock 2 ns.
- O checkout Paxos preexistente estava em `master`, com alterações não
  relacionadas. A execução foi feita numa pasta isolada:
  `/sim/tarsio/WinoCNN-power-5_4-20261010-oSKE9J`.
- A síntese HLS gerou o Verilog e o relatório `csynth`, mas o passo opcional de
  empacotamento IP retornou `bad lexical cast` (Vivado 2019.2). Os artefatos RTL
  estavam presentes; a simulação Xcelium, a síntese Genus e o power terminaram
  normalmente.

## Resultados

| Métrica | Resultado |
|---|---:|
| ciclos `ap_start` → `ap_done` | 50.293 |
| latência ativa a 2 ns | 100,586 µs |
| janela completa do SHM | 102,627 µs |
| leituras de input | 1.120 |
| leituras de peso | 2.101 |
| leituras de parâmetros | 129 |
| writes físicos de saída | 3.840 |
| potência leakage | 0,353082 mW |
| potência interna | 9,12138 mW |
| potência switching | 0,763946 mW |
| **potência total média** | **10,2384 mW** |
| energia dinâmica na janela SHM | 1.014,50 nJ |
| **energia total na janela SHM** | **1.050,74 nJ** |

A energia foi calculada como potência média Genus multiplicada pela janela
completa do SHM (`102,627 µs`), que começa em 0 ns e inclui reset e a drenagem
de 2 µs depois de `ap_done`. Não é uma integração limitada somente ao trecho
ativo `ap_start`→`ap_done`. A potência média total inclui leakage; a dinâmica
é `internal + switching`.

Genus reportou `cell area = 64.821,456 µm²`, `net area = 22.233,616 µm²` e
`total area = 87.055,072 µm²`. No corner nominal, o slack do caminho crítico
reportado foi `+451 ps` para o clock de 2 ns. QoR: 19.252 instâncias
sequenciais e 31.151 combinacionais.

## Limites de interpretação

- `memory` e `bbox` aparecem com 0 mW porque as RAMs externas/black boxes não
  fazem parte do netlist medido; isso não representa o consumo das memórias
  físicas.
- A anotação SHM cobriu 100% dos flops e das portas primárias; 178 ICGs ficaram
  sem atividade anotada. O log também contém avisos sobre `ap_return_0` não
  dirigido e 8 saídas desconectadas.
- Na execução original de 2026-10-10, o testbench RTL completou e produziu os
  dumps, mas não havia ainda uma comparação RTL-vs-golden integrada ao fluxo.
  Depois, foi gerada a imagem de referência do mesmo modelo C com exatamente
  os estímulos `.hex` arquivados e comparada ao trace RTL salvo: **3.840/3.840
  writes conferem bit a bit, 0 mismatches**. O `Not different!` no log original
  continua sendo especificamente o resultado do C-sim.
- A potência arquivada neste diretório usa atividade da simulação RTL; não foi
  gerada a partir de uma simulação gate-level com SDF. O runner foi agora
  estendido para incluir essa etapa e exigir comparação gate-level contra o
  golden antes do power. A etapa foi tentada em cópia isolada, mas falhou: com
  SDF houve 0/3.840 writes observados e 1.226 violações setup/hold; sem SDF a
  netlist completou, porém 1.350/3.840 words divergiram do golden. Portanto,
  ainda não há potência baseada em atividade gate-level/SDF.
- O fluxo foi alterado para tornar essa comparação obrigatória antes de
  synthesis/power. A comparação retrospectiva confirma a captura RTL, mas não
  substitui a simulação gate-level/SDF aprovada nem uma nova campanha de power.
- Os logs e resultados das tentativas gate-level estão em
  `../gate_sdf_attempt_20261010/`; a causa das divergências ainda não foi
  identificada. Não usar a potência antiga como se viesse da atividade SDF.
- `in_oob` e `w_oob` no testbench usam os limites antigos do smoke test 8×8; os
  contadores positivos deste caso não indicam, por si só, acessos fora das
  memórias (endereços máximos observados: input 1023, peso 127).

## Artefatos

- `genus/wino_systolic_top_power_shm_tt.rpt`: relatório de potência usado nos
  cálculos acima.
- `rtl_sim/dut.shm/`: atividade lida pelo Genus.
- `genus/wino_systolic_top_logic_mapped.db` e `.v`: banco e netlist sintetizados
  para esta configuração.
- `logs/`: saída integral de HLS, Genus, Xcelium e power.
- `stimulus/`: entrada `.hex` efetivamente lida pelo testbench RTL.
- `stimulus/*.bin`: dumps DDR de 128 bits/32 bits gerados pelo C-sim antes da
  conversão para `.hex`.
- `stimulus/output_golden.bin`: imagem DDR de referência C-sim para os mesmos
  estímulos.
- `rtl_sim/output_rtl*.hex`, `out_writes.txt` e `rtl_golden_check.json`: dumps
  e comparação bit a bit dos writes RTL com o golden DDR.
- `run_metadata.json`: parâmetros, versões, caminhos e valores numéricos em
  formato estruturado.
- `source_manifest.sha256`: checksums dos fontes-chave copiados para a execução.
