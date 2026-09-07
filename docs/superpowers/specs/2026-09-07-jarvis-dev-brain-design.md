# JARVIS Dev Brain — Design

**Data:** 2026-09-07

## Objetivo

Criar um Second Brain privado para o desenvolvimento do Projeto JARVIS, utilizável pelo Codex no PC principal e pelo ChatGPT via GitHub em qualquer outro computador, sem depender do histórico interno de uma thread específica.

A primeira fase cobre apenas o cérebro do **projeto de desenvolvimento**. O cérebro do **JARVIS em runtime** será um sistema separado, criado depois, reutilizando os aprendizados desta fase sem compartilhar automaticamente dados entre os dois domínios.

## Estado de partida

- Repositório de produto: `automacuniao-sudo/OpenVision`.
- Branch estável de produto: `jarvis-dev`.
- Checkout local do Codex: `C:\Users\Kaue\Documents\ChatGPT\Jarvis`.
- O checkout local deve usar `jarvis-dev` como base principal; implementação de tarefas deve ocorrer em branches/worktrees isoladas.
- O repositório já contém regras de agentes em `AGENTS.md`, `.agents/ORCHESTRATOR.md`, `.agents/LEAD.md`, `.agents/DEVELOPER.md` e `docs/AI_WORKFLOW.md`.

## Decisão arquitetural

Serão mantidos dois cérebros logicamente separados:

1. **JARVIS-DEV-BRAIN** — memória do projeto, desenvolvimento, decisões, builds, tarefas, sessões e conhecimento técnico.
2. **JARVIS-BRAIN** — memória futura do assistente JARVIS em runtime: pessoas, preferências, relações, fatos, hábitos e aprendizados.

A fase atual implementa somente o `JARVIS-DEV-BRAIN`.

## Repositórios e pastas

### Produto

```text
C:\Users\Kaue\Documents\ChatGPT\Jarvis
└── automacuniao-sudo/OpenVision
    └── branch base: jarvis-dev
```

### Brain de desenvolvimento

Criar um repositório GitHub **privado** separado:

```text
automacuniao-sudo/JARVIS-DEV-BRAIN
```

Clone local sugerido:

```text
C:\Users\Kaue\Documents\ChatGPT\Jarvis-Brain
```

O Obsidian abrirá `Jarvis-Brain` como um Vault. O conteúdo útil será Markdown versionado em Git. Configurações locais do Obsidian e plugins que não forem necessários ao fluxo compartilhado não devem virar dependência do sistema.

## Regra de fonte de verdade

- **Código e runtime:** `OpenVision/jarvis-dev`.
- **Memória de desenvolvimento:** `JARVIS-DEV-BRAIN/main`.
- **Trabalho em andamento:** branch/worktree da tarefa + nota de tarefa ativa no Brain.
- **Integração:** Pull Request.
- **Estado estável:** somente depois de merge e validação.

Nenhum agente deve usar uma conversa específica como única fonte de verdade quando o dado já estiver consolidado no Brain ou no Git.

## Estrutura do Vault

```text
JARVIS-DEV-BRAIN/
├── README.md
├── AGENTS.md
├── 00-Dashboard.md
│
├── _memory/
│   ├── current-state.md
│   ├── architecture.md
│   └── roadmap.md
│
├── _decisions/
│   └── ADR-XXXX-<slug>.md
│
├── _sessions/
│   └── YYYY-MM-DD-<slug>.md
│
├── _builds/
│   └── Build-<numero>.md
│
├── _tasks/
│   ├── active/
│   └── completed/
│
├── _knowledge/
│   └── <topico>.md
│
├── _learnings/
│   └── <topico>.md
│
├── _handoffs/
│   └── <tarefa-ou-pr>.md
│
└── _templates/
    ├── session.md
    ├── decision.md
    ├── task.md
    └── build.md
```

## Responsabilidade de cada área

### `00-Dashboard.md`

Visão curta para humanos: versão estável, branch estável, tarefa atual, PRs relevantes, próximos passos e bloqueios.

### `_memory/current-state.md`

Fonte canônica do estado técnico atual. Deve conter apenas fatos vigentes e verificáveis, como branch estável, última build validada, features estáveis e pendências de curto prazo.

### `_memory/architecture.md`

Arquitetura atual consolidada. Não é histórico; decisões antigas ficam em ADRs.

### `_memory/roadmap.md`

Prioridades atuais e itens adiados/bloqueados. Deve refletir o backlog aprovado, não cada ideia mencionada em conversa.

### `_decisions/`

ADRs imutáveis no sentido histórico. Se uma decisão mudar, criar nova ADR que substitui a anterior, sem apagar a decisão antiga.

### `_sessions/`

Resumo estruturado de sessões relevantes. Não armazenar transcript integral por padrão. Uma sessão deve registrar contexto, ações, decisões, evidências, pendências e links para PR/commits/builds.

### `_builds/`

Histórico de builds, CI, versão, artefato e teste físico. Uma build não pode ser marcada como validada sem evidência correspondente.

### `_tasks/`

Estado operacional. Cada tarefa ativa deve apontar para branch/worktree, objetivo, critérios de aceite, agente responsável, PR e bloqueios.

### `_knowledge/`

Conhecimento técnico estável: Meta DAT, Gemini Live, reconhecimento facial, áudio, CI, etc. Evitar duplicar documentação que já vive melhor no repositório do produto; preferir links e sínteses.

### `_learnings/`

Aprendizados reutilizáveis derivados de incidentes, debugging e implementação, especialmente os que mudam como os agentes devem trabalhar.

### `_handoffs/`

Passagem explícita entre ORCHESTRATOR, DEVELOPER, LEAD/REVIEWER e QA quando uma tarefa atravessa agentes ou ferramentas.

## Metadados Markdown

Notas operacionais devem usar frontmatter YAML simples quando aplicável:

```yaml
---
type: session
status: active
date: 2026-09-07
project: JARVIS
source: chatgpt
related_repo: automacuniao-sudo/OpenVision
related_branch: jarvis-dev
---
```

Campos permitidos devem ser poucos e estáveis. Evitar schemas grandes nesta fase.

## Fluxo de sessão

### Início de sessão — `daily-briefing`

O agente deve ler, nesta ordem:

1. `00-Dashboard.md`
2. `_memory/current-state.md`
3. `_memory/roadmap.md`
4. tarefa ativa relacionada, se houver
5. última sessão relevante, se necessário

O briefing deve responder de forma curta:

- onde o projeto está;
- qual é a branch/base estável;
- qual tarefa está ativa;
- qual é o próximo passo;
- quais bloqueios existem.

### Durante a sessão

O agente deve escrever no Brain somente fatos que sobreviverão à conversa:

- decisões;
- mudança de estado;
- nova tarefa;
- resultado de build/teste;
- aprendizado reutilizável;
- handoff.

Pensamentos transitórios, logs enormes e tentativas descartadas não devem ser promovidos para memória canônica.

### Fim de sessão — `end-session`

O agente deve:

1. resumir o que aconteceu;
2. atualizar `current-state.md` apenas se o estado real mudou;
3. atualizar roadmap/tarefa se necessário;
4. registrar decisões novas em ADR;
5. registrar build/teste quando houver evidência;
6. registrar aprendizados reutilizáveis;
7. criar uma nota de sessão com links para os artefatos relacionados;
8. não declarar merge/teste/sucesso sem evidência.

## Fluxo `braindump`

Entrada livre do usuário não deve ir automaticamente para `current-state.md`.

Classificação mínima:

- ideia de produto → roadmap/backlog;
- decisão aprovada → ADR;
- fato técnico confirmado → knowledge/current-state conforme escopo;
- tarefa concreta → `_tasks/active`;
- preferência de processo → AGENTS/learning se realmente duradoura.

## Integração com Codex

O projeto Codex `Jarvis` continuará associado ao checkout do `OpenVision` como pasta principal.

O `JARVIS-DEV-BRAIN` deve ser disponibilizado ao Codex como pasta/repositório adicional quando a versão instalada do Codex permitir múltiplas pastas no projeto; caso contrário, os dois clones permanecerão lado a lado e os agentes receberão o caminho explícito do Brain nas instruções.

Os agentes do Codex devem continuar com responsabilidades separadas:

- **ORCHESTRATOR:** cria/coordena tarefa e mantém estado operacional.
- **DEVELOPER:** implementa em branch/worktree isolada.
- **LEAD/REVIEWER:** revisa diff, arquitetura, regressões e evidências.
- **QA/BUILD:** valida testes, CI, versão, artefatos e checklist.

Nenhum agente deve fazer merge sem a aprovação humana exigida pelas regras do repositório.

## Integração com ChatGPT remoto

O ChatGPT não dependerá do filesystem local do computador do usuário.

Para continuidade entre computadores, o `JARVIS-DEV-BRAIN` deve estar sincronizado no GitHub privado. O ChatGPT usa o repositório conectado como fonte remota do Brain.

Consequência: alterações locais não commitadas no Vault não estão disponíveis ao ChatGPT remoto e não contam como memória compartilhada.

## Obsidian

O Obsidian é a interface de navegação e edição humana, não a camada de armazenamento exclusiva.

Princípio:

```text
Markdown/Git = dados
Obsidian = interface humana
Codex/ChatGPT = agentes consumidores/produtores
```

O fluxo não pode depender de um plugin proprietário para ler as notas básicas. Plugins podem melhorar UX, links, busca e grafo, mas o conteúdo canônico deve continuar acessível como Markdown comum.

## Segurança e privacidade

O Brain de desenvolvimento será privado porque pode conter contexto de trabalho, histórico de desenvolvimento, nomes internos, logs e informações que não devem ir ao repositório público do produto.

Regras:

- não salvar API keys, tokens, senhas, certificados ou secrets;
- não copiar credenciais de chats/logs para o Vault;
- adicionar padrões de arquivos sensíveis ao `.gitignore` quando necessário;
- preferir links para artefatos externos em vez de incorporar dados sensíveis;
- revisar antes de commit/push;
- o futuro `JARVIS-BRAIN` terá controles de privacidade próprios e não compartilhará automaticamente conteúdo com o `JARVIS-DEV-BRAIN`.

## Importação do histórico atual

Não importar todos os transcripts integralmente.

Primeira migração deve consolidar o histórico já conhecido em:

- `current-state.md`;
- `architecture.md`;
- `roadmap.md`;
- notas de Build 40, 41 e 42;
- ADRs das principais decisões arquiteturais;
- uma sessão histórica resumindo a migração Codex/Obsidian;
- knowledge notes para os subsistemas mais importantes.

Depois disso, somente novas sessões relevantes serão adicionadas incrementalmente.

## Relação com o futuro JARVIS-BRAIN

O `JARVIS-BRAIN` futuro reutilizará padrões de armazenamento e retrieval aprendidos aqui, mas terá domínio separado.

Não fazer nesta fase:

- face embeddings;
- speaker embeddings;
- memória pessoal de pessoas;
- hábitos/preferências do usuário em runtime;
- Learning Engine do assistente;
- sincronização automática DEV-BRAIN → JARVIS-BRAIN.

## Critérios de aceite da fase 1

A fase estará pronta quando:

1. existir um repositório privado `JARVIS-DEV-BRAIN`;
2. o Vault abrir normalmente no Obsidian;
3. a estrutura canônica estiver criada;
4. o estado atual do JARVIS estiver consolidado;
5. o Codex conseguir iniciar uma sessão lendo o Brain;
6. o ChatGPT conseguir consultar o Brain via GitHub em outro computador;
7. existir um fluxo documentado de `daily-briefing`, `braindump` e `end-session`;
8. uma sessão de teste provar que uma decisão escrita em um ambiente pode ser recuperada no outro após sincronização Git;
9. nenhum segredo estiver versionado;
10. o repositório `OpenVision` permanecer responsável apenas pelo produto e sua documentação técnica, sem virar o Vault privado.

## Próxima fase após aceite

Somente depois de validar o `JARVIS-DEV-BRAIN` será projetado o `JARVIS-BRAIN` de runtime, incluindo Second Brain estruturado, `PersonProfile`, retrieval, proveniência, confiança e Learning Engine.