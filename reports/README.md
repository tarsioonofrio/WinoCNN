# Organização de resultados

Cada execução deve ser identificável por workload, precisão, seed, configuração
Winograd e data/run ID. Agrupe os artefatos em
`reports/<workload-ou-campanha>/`; não espalhe resultados de um mesmo run por
`reports/genus/`, `tmp/` e diretórios pessoais sem um manifesto que os conecte.
Não mova os caminhos existentes de saída do fluxo (`reports/genus/dom<N>/` e
os caminhos definidos pelos scripts ASIC) sem atualizar e validar os scripts;
o pacote do run pode apontar para esses relatórios por caminho e checksum.

## O que versionar

Mantenha no Git o conjunto pequeno necessário para interpretar e auditar um
resultado:

- `README.md` com objetivo, configuração, comando, resultado e limitações;
- `params.json`, `provenance.json` e manifest de SHA-256 das fontes/entradas;
- validação golden (`csim_validation.json` ou `rtl_golden_check.json`),
  contagens de tráfego e métricas resumidas;
- relatórios textuais concisos que fundamentem as métricas publicadas;
- estímulos e goldens pequenos quando forem necessários para reproduzir o caso.

Todo número publicado deve indicar top/configuração, commit de origem, versão da
ferramenta, corner, estágio da medição e se a memória foi incluída. Para
potência, distinguir atividade RTL de Gate-SDF e não chamar potência média ×
tempo de medição direta de energia.

## Artefatos grandes

Para novos runs, prefira armazenar fora do Git formas de onda SHM, netlists
mapeadas, bancos de síntese, SDF, logs integrais e traces extensos. O README do
run deve registrar o caminho persistente do artefato, tamanho, SHA-256, origem
(ferramenta/comando/commit) e como recuperá-lo. Se o artefato não puder ser
mantido em armazenamento persistente, não o remova silenciosamente: registre
essa limitação e preserve as evidências compactas que ainda sustentam o
resultado.

Esta regra é prospectiva. O repositório já contém alguns artefatos grandes
versionados — inclusive SHM, netlist e database Genus — que não serão removidos
por esta política. Migração desses objetos exige plano separado, validação dos
checksums, atualização de links e decisão sobre histórico remoto. Não adicione
regras globais de ignore para `reports/**` enquanto houver resultados locais
pendentes de classificação.

## Estrutura recomendada para uma campanha

```text
reports/<workload>_<precisao>_<seed>_<run-id>/
├── README.md
├── params.json
├── provenance.json
├── source_manifest.sha256
├── validation/
│   └── golden_check.json
├── metrics/
│   └── summary.json
└── artifacts_external.md   # apenas se houver artefatos externos grandes
```

Os nomes dos arquivos podem acompanhar o fluxo existente quando isso evitar
quebrar scripts. O requisito é manter juntos a configuração, a proveniência,
as evidências de validação e o resumo do resultado; não renomear campanhas
antigas apenas para adequá-las a este exemplo.
