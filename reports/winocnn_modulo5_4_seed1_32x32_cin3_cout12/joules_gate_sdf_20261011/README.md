# Genus/Joules power sobre atividade Gate-SDF — 2026-10-11

Esta pasta arquiva a reexecução de potência activity-based do WinoCNN para o
mesmo estímulo determinístico 5/4 e a mesma simulação gate-level com SDF
validada contra o golden.

## Configuração e proveniência

- Workload: entrada 32×32, `Cin=3`, `Cout=12`, kernel 3×3, stride 1, padding 0.
- Winograd: domínio 4, F(2×2,3×3), `M=2, N=1, Q=1, B=1` (2 PEs, 32
  multiplicadores no hadamard).
- Dataset: features signed de 5 bits e pesos signed de 4 bits, seed 1.
- Processo: Genus 21.12-s068_1 no host `paxos.inf.pucrs.br`, biblioteca TSMC
  28 nm, condição `tt0p9v25c`, 0,90 V / 25 °C, interconnect `ple`.
- Execução isolada: `/sim/tarsio/WinoCNN-gate-sdf-20261010.7uUqh7`, sem
  modificar o checkout remoto original. O workroot de potência foi
  `reports/joules_gate_sdf_power_20261011_genus_via_genus/workroot` dentro
  dessa cópia.
- Comando: `module load cadence/genus/211 && genus -f asic_scripts/power.tcl`.
- Entrada de atividade: SHM `sim_asic/dom4/gate/dut.shm` da mesma cópia
  isolada, lido com `read_stimulus -dut_instance tb.dut -start 0ns`.
- O `power.tcl` e `constraints.sdc` copiados para o workroot correspondem aos
  arquivos versionados neste repositório. SHA-256: `power.tcl`
  `dd559d85e2830e17d2c22b2b138a2652887cf99bad105ba3a7057dbaa97e689f`;
  `constraints.sdc`
  `1164faa69857c758de6e33b208af9c5a29ed673f147a326bf74db6cdac4f850a`.

A comparação funcional Gate-SDF vs golden está em
[`../gate_sdf_attempt_20261010/gate_sdf_golden_check.json`](../gate_sdf_attempt_20261010/gate_sdf_golden_check.json): PASS,
3.840 writes verificados, zero mismatches. Os logs Xcelium e de anotação SDF
também estão naquele diretório.

## Resultado

`power_shm_tt.rpt` reporta potência média total de **10,6353 mW**:

| Categoria | Potência total |
|---|---:|
| Register | 9,49094 mW |
| Logic | 0,644961 mW |
| Clock | 0,499393 mW |
| Leakage (subtotal) | 0,351326 mW |
| Total | 10,6353 mW |

O SHM termina em 102.630160 µs. Assim, a energia da janela inteira é
**≈1.091,50 nJ**, calculada por potência média × duração. Não é uma medição
direta de energia. O Xcelium registrou `$finish` em 102.629160 µs; o fim do
frame SHM usado no `read_stimulus` ocorre 1 ns depois. As memórias não foram
sintetizadas; o 0 mW em `memory`/`bbox` indica exclusão do cálculo, não consumo
físico nulo.

Atividade anotada: 419/419 entradas primárias, 21.108/21.108 saídas de flops,
178/178 ICGs e 59.720/59.721 driver nets. Oito saídas primárias não estão
conectadas. O log contém avisos TUI-94 de atributos de atividade em pinos
hierárquicos sem driver (`ap_idle` e `ap_return_0`). Resultado pré-route e
estimado; não é signoff de potência/timing.

## Licenças e logs

O caminho executado com sucesso foi o script de power do Genus empregado no
fluxo FastConv. O log mostra que a licença standalone `Joules_RTL_Power` não
estava disponível, mas que Genus usou `Joules_XL`; o `report_power` registra
explicitamente `Joules engine is used`, conclui `PWRA-0007` e termina com
`Normal exit`.

- [`genus.log`](genus.log): log integral do fluxo bem-sucedido.
- [`power_shm_tt.rpt`](power_shm_tt.rpt): relatório de potência arquivado.
- [`standalone_joules_attempt1.log`](standalone_joules_attempt1.log) e
  [`standalone_joules_retry1.log`](standalone_joules_retry1.log): tentativas
  standalone que falharam ao obter `Joules_RTL_Power`; mantidas para
  rastreabilidade, não são a origem do relatório de potência.

SHA-256 dos arquivos desta pasta:

```text
87e6ffeb9cbd9716a9436e6eb6e46e2bccd96d8f541b6347c3a216bf521eec5b  genus.log
25e0cf136ff6846d51036b7c25b7d8b607975a472af05fd658da350cdec199e9  power_shm_tt.rpt
5d6c640e9b56f9b75e9256ae08909acb6a024615febb7a789ea294b9d16ebdbe  standalone_joules_attempt1.log
eb74057a65494408b6df0a5b33eea13684e9ab16ae5b9b6c1d65db57ac0a9bfd  standalone_joules_retry1.log
```
