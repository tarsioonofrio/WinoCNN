# Documentação do WinoCNN (baseline ASIC)

Índice. O foco é a comparação de PPA com o acelerador de referência (FastConv)
sob a mesma metodologia ASIC.

## Fluxo ASIC

| documento | conteúdo |
|---|---|
| [`synthesis.md`](synthesis.md) | escolher o domínio, interface de memória ASIC (`-DWINO_ASIC`), HLS → Genus, black-box das RAMs, constraints, resultados (dom4/dom6) |
| [`simulation.md`](simulation.md) | C-sim, estímulo, simulação RTL e gate-level/SDF, SHM, golden, potência e resultados |

## Arquitetura e micro-arquitetura

| documento | conteúdo |
|---|---|
| [`architecture.md`](architecture.md) | hierarquia de módulos a partir de `wino_systolic_top` |
| [`address_generation.md`](address_generation.md) | geração de endereços de entrada/peso/saída; hardware vs software |
| [`configuration_exploration.md`](configuration_exploration.md) | exploração das configurações; baseline micro adotado de 32 multiplicadores; domínio 4 vs 6 |
| [`micro_progress.md`](micro_progress.md) | jornada do WinoCNN-micro; configuração funcional adotada e bloqueio estrutural de M=1 |
| [`b1_pack_unpack_detail.md`](b1_pack_unpack_detail.md) | detalhe do fix de `BATCH_SIZE=1` (layout da palavra, overflow, macros) |

## Referência

| documento | conteúdo |
|---|---|
| [`history.md`](history.md) | relato de todas as mudanças desde o commit original preservado |
| [`agent_brief_16macs.md`](agent_brief_16macs.md) | histórico do alvo exploratório de 16 MACs, não adotado como baseline |

## Manutenção do repositório

| documento | conteúdo |
|---|---|
| [`repository_organization.md`](repository_organization.md) | relação com upstream, política de branches, compatibilidade e organização das mudanças locais |
| [`../reports/README.md`](../reports/README.md) | convenção para registrar resultados e separar evidências compactas de artefatos grandes |

## Convenções

- **Domínio** `<N>` = `WINO_DOMAIN_SIZE` (4 = F(2×2,3×3), 6 = F(4×4,3×3)).
  Artefatos são separados por domínio: `reports/genus/dom<N>/` (síntese),
  `sim_asic/dom<N>/` (simulação), `testbench/stim/dom<N>/` (estímulo).
- Config micro validada: `M=2, N=1, H2=2, W2=1, Q=1, B=1` → 1 PE.
- Configuração micro escolhida para comparação: domínio 4, 32 multiplicadores escalares. O alvo de 16 exigiria refatoração estrutural do PE/feed de pesos e fica fora do baseline atual.
- Ferramentas: Vivado HLS 2019.2, Genus 21.12, Xcelium 23.03 (host `paxos`),
  TSMC 28 nm BWP30P140, 2 ns.
