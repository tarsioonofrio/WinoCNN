# Organização do repositório e compatibilidade com upstream

Este repositório mantém uma derivação experimental do WinoCNN dos autores,
incluindo o fluxo ASIC e a variante WinoCNN-micro. A organização deve facilitar
auditar essas diferenças sem deslocar os caminhos que o upstream usa para
código, HLS e testbench.

## Upstream e branches

O upstream dos autores é [`xliu0709/WinoCNN`](https://github.com/xliu0709/WinoCNN),
referenciado também pela página de software do grupo de Deming Chen. O remoto
local `upstream` aponta para esse repositório; `origin` aponta para o fork de
trabalho `tarsioonofrio/WinoCNN`.

Snapshot conferido em 2026-10-13:

| referência | commit | relação observada |
|---|---|---|
| `upstream/master` | `4a62569851db0276dc124bce4c4a738457ebf696` | master público dos autores na consulta; igual a `baseline/winocnn` |
| `master` e ref local `origin/master` | `4bb2ccb10788b155b5db468159179dce172d035f` | 2 commits à frente do upstream |
| `experiment/winocnn-micro` | `ff28359c14497d60025642dc59cd40e502225666` | 43 commits à frente de `master` |
| ref local `origin/experiment/winocnn-micro` | `37cf595c28034057352657c3c3f11d47bc56aab1` | remote-tracking ref; a branch local estava 1 commit à frente dessa ref |

Os hashes e contagens acima são um registro daquele snapshot, não aliases
permanentes, e as refs `origin/*` só representam o remoto até o último fetch.
Atualize-as antes de publicar ou comparar branches. A branch `baseline/winocnn`
é a referência congelada usada para identificar o source dos autores; não a
avance para incorporar mudanças experimentais.

Procedimento de sincronização:

```bash
git fetch --no-tags upstream master
git fetch --no-tags origin master experiment/winocnn-micro
git merge-base --is-ancestor upstream/master experiment/winocnn-micro
git log --oneline upstream/master..experiment/winocnn-micro
git diff --stat upstream/master...experiment/winocnn-micro
```

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
