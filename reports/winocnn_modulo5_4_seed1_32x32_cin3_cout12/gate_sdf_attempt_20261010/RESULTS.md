# Gate-level/SDF e potência — 2026-10-10

Execução feita numa cópia isolada em
`/sim/tarsio/WinoCNN-gate-sdf-20261010.7uUqh7`, preservando o checkout remoto
original e a campanha anterior. Foram reutilizados o netlist mapeado Genus e o
SDF nominal da campanha, junto dos mesmos estímulos/golden 5/4 para convolução
32×32, `Cin=3`, `Cout=12`, padding 0, dom4 / F(2×2,3×3), 2 PEs.

## Resultado final

| etapa | resultado |
|---|---|
| RTL HLS contra golden | PASS, 3.840/3.840 writes |
| Gate-level com SDF nominal | PASS funcional, 3.840/3.840 writes, 0 divergências |
| Duração simulada | 50.295 ciclos; 102,62916 µs no relógio de 2 ns incluindo reset/drenagem |
| Tráfego contado | 1.120 leituras input; 2.101 leituras weight; 129 leituras params; 3.840 writes |
| Anotação SDF | escopo `tb.dut`; 271.429/271.437 path delays (100,00%) e 66.834/182.168 timing checks (36,69%) |
| Violações setup/hold em runtime | nenhuma mensagem `Warning! Timing violation` |
| Genus power (tt0p9v25c) | PASS; total 10,6353 mW |
| Energia estimada na janela SHM | ≈1.091,49 nJ (= 10,6353 mW × 102,62916 µs) |

Detalhamento de potência: register 9,49096 mW; logic 0,644966 mW; clock
0,499395 mW; memória 0 mW (externa/black-box, não sintetizada); leakage
0,351326 mW, internal 9,63763 mW e switching 0,646371 mW.
Energia é calculada a partir da potência média e da duração completa da
atividade SHM, incluindo reset e drenagem; não é uma medição direta de energia.

## Causa e correção do bloqueio

As primeiras tentativas tiveram 1.226 violações setup/hold e sinais `X`. O
modelo comportamental de RAM entregava dados com tCO ideal/zero, no mesmo
instante em que a netlist com atrasos SDF e clocks gated verificava os
registradores. A correção foi inicializar no tempo zero as saídas/pipelines da
RAM externa, dar tCO explícito de 200 ps às respostas externas e criar cópias
temporárias dos modelos de RAM HLS com tCO de 30 ps nos seis outputs internos de
leitura. O runner jamais altera os RTL HLS originais. Os contadores do
testbench também foram protegidos de enables `X`.

Os valores 200 ps e 30 ps são **hipóteses de simulação**, não caracterização de
memórias. O Xcelium anotou 100% dos path delays, mas apenas 36,69% dos timing
checks; por isso o resultado é uma verificação funcional gate-level/SDF útil
para gerar atividade, não signoff de timing nem evidência temporal de macros
SRAM caracterizadas. A potência é estimativa activity-based pré-route, e as
memórias externas não contribuem para ela.

## Evidências

- `gate_sdf_xrun_final.log`: execução final do Xcelium e estatísticas de anotação.
- `gate_sdf_annotation_final.log`: backannotation SDF e escopo.
- `gate_sdf_golden_check.json`: comparação PASS, 3.840 writes e 0 mismatches.
- `gate_sdf_out_writes_final.txt`: trace de writes comparado ao golden.
- `gate_sdf_power_tt.rpt`: relatório Genus power.
- `gate_sdf_xrun.log`, `gate_sdf_annotation.log`, `gate_sdf_out_writes.txt` e
  `no_*`: diagnósticos anteriores, preservados para rastreabilidade.
