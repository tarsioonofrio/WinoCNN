# Contadores de acesso às SRAMs — WinoCNN

Execução em 2026-10-10 no Xcelium 23.03-s003 para `32×32`, `Cin=3`,
`Cout=12`, kernel `3×3`, stride 1, padding 0, Winograd F(2×2,3×3),
`M=2`, `N=1`, `Q=1`, `B=1` (32 multiplicadores lógicos no hadamard).

As contagens são operações de porta observadas na simulação, não endereços
únicos. A memória externa é modelada no testbench; os 153 modelos de RAM
internos correspondem às instâncias RAM comportamentais geradas pelo HLS.
Os contadores não são sintetizados. Os writes de saída por banco são derivados
do `out_writes.txt`, que também é conferido bit a bit contra o golden.

## Validação

| simulação | ciclos `ap_start`→`ap_done` | writes comparados ao golden | mismatches |
|---|---:|---:|---:|
| RTL HLS | 50.293 | 3.840/3.840 | 0 |
| Gate-level com SDF nominal | 50.295 | 3.840/3.840 | 0 |

O hash do golden e do trace de saída é igual nas duas etapas. O runner gate/SDF
terminou com sucesso, incluindo a checagem de anotação SDF em `tb.dut` e a
rejeição de violações de timing.

## Interfaces externas

| SRAM/porta | reads | writes |
|---|---:|---:|
| `input_DDR0` | 560 | 0 |
| `input_DDR1` | 560 | 0 |
| `weight_DDR0` | 2.101 | 0 |
| `mem_params` | 129 | 0 |
| `output_DDR0` | 0 | 1.920 |
| `output_DDR1` | 0 | 1.920 |

As portas `output_DDR*` não possuem caminho de leitura no RTL, por isso reads
zero. Os 3.840 writes externos coincidem com o número de palavras verificado
contra o golden.

## SRAMs internas, por tipo de módulo

Os valores abaixo são iguais na simulação RTL e na gate/SDF para esta execução.

| tipo de RAM HLS | instâncias | reads | writes |
|---|---:|---:|---:|
| `load_params_parambkb_ram` | 1 | 50 | 128 |
| `weight_feed_one_pg8j_ram` | 8 | 115.200 | 8.192 |
| `wino_input_computqcK_ram` | 64 | 115.200 | 8.192 |
| `wino_systolic_topbwn_ram` | 64 | 2.551.808 | 526.336 |
| `wino_systolic_topcyx_ram` | 16 | 0 | 32 |
| **Total interno** | **153** | **2.782.258** | **542.880** |

Somando interfaces externas e RAMs internas: **2.785.608 reads** e
**546.720 writes** por execução.

## Arquivos

- [`rtl_sram_access_counts.json`](rtl_sram_access_counts.json): contadores RTL,
  por porta externa e instância interna, com agregados por tipo.
- [`rtl_sram_access_counts.tsv`](rtl_sram_access_counts.tsv): registros brutos
  usados para compor o JSON RTL.
- [`rtl_sram_golden_check.json`](rtl_sram_golden_check.json): comparação RTL
  com o golden.
- [`gate_sdf_attempt_20261010/sram_access_counts.json`](gate_sdf_attempt_20261010/sram_access_counts.json):
  contadores gate/SDF.
- [`gate_sdf_attempt_20261010/sram_access_counts.tsv`](gate_sdf_attempt_20261010/sram_access_counts.tsv):
  registros brutos gate/SDF.
- [`gate_sdf_attempt_20261010/sram_golden_check.json`](gate_sdf_attempt_20261010/sram_golden_check.json):
  comparação gate/SDF com o golden.
- [`gate_sdf_attempt_20261010/sram_sdf_annotation.log.gz`](gate_sdf_attempt_20261010/sram_sdf_annotation.log.gz):
  log original compactado da anotação SDF (bytes preservados).

Cada JSON também lista as 153 instâncias internas pelo caminho hierárquico
completo. Os TSVs foram normalizados pelo trace de writes para que os valores
de saída por banco reflitam exatamente as operações verificadas.
