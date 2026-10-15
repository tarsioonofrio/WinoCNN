# Organização do repositório e compatibilidade com upstream

Este repositório mantém uma derivação experimental do WinoCNN dos autores,
incluindo o fluxo ASIC e a variante WinoCNN-micro. A organização deve facilitar
auditar essas diferenças sem deslocar os caminhos que o upstream usa para
código, HLS e testbench.

## Upstream e branches

O código-base dos autores é [`xliu0709/WinoCNN`](https://github.com/xliu0709/WinoCNN),
referenciado também pela página de software do grupo de Deming Chen. Este
repositório de trabalho tem um único remoto, `origin`
(`git@github.com:tarsioonofrio/WinoCNN.git`); não há remoto `upstream`
configurado. As branches publicadas são `master` (base estável) e `iscas2027`
(a linha do artigo ISCAS 2027).

O source original dos autores está preservado no commit `4a62569`
("Update README.md"), ancestral de `master` e de `iscas2027`. Esse snapshot já
foi referenciado pela branch `baseline/winocnn`, que não existe mais.

Procedimento de sincronização:

```bash
git fetch --no-tags origin
git merge-base --is-ancestor origin/master origin/iscas2027
git log --oneline origin/master..origin/iscas2027
git diff --stat origin/master...origin/iscas2027
git rev-list --left-right --count origin/master...origin/iscas2027
```

As refs `origin/*` só representam o remoto até o último fetch.
Atualize-as antes de publicar ou comparar branches. Use o commit `4a62569`
como referência congelada do source dos autores; não o avance para incorporar
mudanças experimentais.

Branches experimentais publicadas não devem receber rebase destrutivo para
acompanhar o upstream. Faça a atualização em uma branch de sincronização
temporária, rode os testes possíveis e integre-a com histórico explícito após
revisar os conflitos. Para envio normal, use explicitamente `origin` e a branch
de trabalho. Se a intenção for contribuir de volta ao projeto, prepare uma
proposta/PR contra o upstream em vez de fazer push direto.

## Layout

| área | papel | orientação |
|---|---|---|
| `src/`, `software/`, `src_gold/`, `codegen/`, `include/`, `hw_scripts/` | arquitetura HLS original e adaptações necessárias | manter nomes e caminhos do upstream; mudanças locais devem ser pequenas e rastreáveis por commit |
| `asic_scripts/` | fluxo local de estímulo, simulação, síntese e análise ASIC | adicionar aqui ferramentas específicas da comparação, sem renomear scripts upstream sem necessidade |
| `testbench/` | testbenches e estímulos funcionais compactos | manter fixtures reproduzíveis separadas por domínio/configuração |
| `docs/` | arquitetura, fluxo e decisões locais | usar `docs/README.md` como índice; separar procedimento de resultado quando o histórico crescer |
| `reports/` | pacotes por workload/experimento | aplicar a convenção de [`reports/README.md`](../reports/README.md) |

Não crie uma segunda cópia dos diretórios-fonte do WinoCNN apenas para separar
“original” e “micro”: a branch e o commit-base já preservam essa distinção.
Uma cópia duplicada tende a divergir e dificulta saber qual fonte foi
sintetizada. Para reproduzir o original, use o commit-base; para os resultados
micro, use a branch experimental e registre o SHA exato no pacote do run.

## Regras para mudanças locais

- Separe commits por finalidade: correção compatível do core, alteração
  específica do micro, fluxo ASIC e documentação/resultados.
- Não misture mudanças de datapath com artefatos de uma execução no mesmo
  commit, salvo quando o teste/relatório for necessário para demonstrar aquela
  mudança.
- Código compartilhado com a arquitetura original permanece nos caminhos
  originais. Scripts ASIC e integrações de comparação ficam em `asic_scripts/`.
- Registre incompatibilidades com o upstream, motivo e validação em
  `docs/history.md`; não apresente o micro como arquitetura original do paper.
- Execute validação C-sim/golden depois de mudanças funcionais. Fluxos que
  dependem de licença (HLS, Genus, Xcelium/Joules) devem ser reportados como
  validação separada, com ferramenta, versão, corner e estágio da medição.

No estado documentado, o baseline micro comparável é o fallback de 32
multiplicadores. A configuração de 16 multiplicadores ainda não deve ser
tratada como validada; veja `micro_progress.md` e `configuration_exploration.md`.
