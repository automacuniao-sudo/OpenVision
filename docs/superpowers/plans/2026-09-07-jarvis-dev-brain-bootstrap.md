# JARVIS Dev Brain Bootstrap Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Criar e validar o `JARVIS-DEV-BRAIN` como Second Brain privado do desenvolvimento, compartilhado entre Obsidian, Codex e ChatGPT via Git/GitHub.

**Architecture:** O produto continua em `automacuniao-sudo/OpenVision`, com `jarvis-dev` como branch estável. O Brain vive em um repositório privado separado, `automacuniao-sudo/JARVIS-DEV-BRAIN`, clonado em `C:\Users\Kaue\Documents\ChatGPT\Jarvis-Brain` e aberto como Vault do Obsidian. Markdown/Git é a fonte de dados; Obsidian é a interface humana; Codex e ChatGPT consomem e atualizam apenas o estado consolidado.

**Tech Stack:** Git/GitHub, Markdown, Obsidian, Codex Desktop, ChatGPT GitHub connector, PowerShell.

**Spec:** `docs/superpowers/specs/2026-09-07-jarvis-dev-brain-design.md`

## Global Constraints

- `OpenVision/jarvis-dev` continua sendo a fonte de verdade do código/runtime.
- `JARVIS-DEV-BRAIN/main` será a fonte de verdade da memória de desenvolvimento.
- Não colocar secrets, API keys, tokens, senhas, certificados ou credenciais no Brain.
- Não importar transcripts completos por padrão; consolidar somente conhecimento duradouro.
- Não misturar o futuro `JARVIS-BRAIN` de runtime com o `JARVIS-DEV-BRAIN`.
- Tarefas de código continuam em branch/worktree isolada e chegam a `jarvis-dev` por PR.
- Builds/testes só podem ser marcados como validados com evidência.
- `OpenVision` não deve virar o Vault privado.

---

### Task 1: Corrigir o checkout principal do Codex para `jarvis-dev`

**Files:**
- Nenhum arquivo do produto deve ser modificado.

**Interfaces:**
- Consumes: clone local `C:\Users\Kaue\Documents\ChatGPT\Jarvis`.
- Produces: checkout principal limpo e sincronizado com `origin/jarvis-dev`.

- [ ] **Step 1: Confirmar árvore limpa**

No PowerShell:

```powershell
cd C:\Users\Kaue\Documents\ChatGPT\Jarvis
git status --short
```

Expected: nenhuma linha de saída.

- [ ] **Step 2: Atualizar referências remotas**

```powershell
git fetch origin --prune
```

Expected: comando concluído sem erro.

- [ ] **Step 3: Criar/trocar branch local `jarvis-dev` rastreando o remoto**

Primeiro tente:

```powershell
git switch jarvis-dev
```

Se a branch local ainda não existir, use:

```powershell
git switch --track -c jarvis-dev origin/jarvis-dev
```

- [ ] **Step 4: Sincronizar sem merge implícito**

```powershell
git pull --ff-only origin jarvis-dev
```

- [ ] **Step 5: Verificar base correta**

```powershell
git branch --show-current
git rev-parse HEAD
git rev-parse origin/jarvis-dev
git status
```

Expected:
- branch atual: `jarvis-dev`;
- `HEAD` igual a `origin/jarvis-dev`;
- working tree clean.

---

### Task 2: Criar o repositório privado do Brain e cloná-lo localmente

**Files:**
- Create repository: `automacuniao-sudo/JARVIS-DEV-BRAIN` (PRIVATE).
- Create local clone: `C:\Users\Kaue\Documents\ChatGPT\Jarvis-Brain`.

**Interfaces:**
- Consumes: conta GitHub `automacuniao-sudo`.
- Produces: repositório privado `JARVIS-DEV-BRAIN` com branch `main` e clone local.

- [ ] **Step 1: Criar o repositório no GitHub**

Ação manual necessária porque o conector GitHub disponível nesta sessão não expõe criação de repositórios.

No GitHub: **New repository** → owner `automacuniao-sudo` → nome `JARVIS-DEV-BRAIN` → visibility **Private** → inicializar com README desmarcado, para evitar histórico desnecessário.

- [ ] **Step 2: Clonar ao lado do OpenVision**

```powershell
cd C:\Users\Kaue\Documents\ChatGPT
git clone https://github.com/automacuniao-sudo/JARVIS-DEV-BRAIN.git Jarvis-Brain
cd .\Jarvis-Brain
```

Expected: diretório `C:\Users\Kaue\Documents\ChatGPT\Jarvis-Brain` contém `.git`.

- [ ] **Step 3: Criar o primeiro commit local caso o repositório esteja vazio**

```powershell
Set-Content -Path README.md -Value '# JARVIS-DEV-BRAIN'
git add README.md
git commit -m "chore: initialize JARVIS Dev Brain"
git push -u origin main
```

- [ ] **Step 4: Verificar remoto e privacidade**

```powershell
git remote -v
git branch --show-current
git status
```

Expected:
- remote `origin` aponta para `automacuniao-sudo/JARVIS-DEV-BRAIN.git`;
- branch `main`;
- working tree clean.

No GitHub, confirmar visualmente o badge **Private**.

---

### Task 3: Bootstrap da estrutura canônica do Vault

**Files:**
- Create: `.gitignore`
- Create: `README.md`
- Create: `AGENTS.md`
- Create: `00-Dashboard.md`
- Create: `_memory/current-state.md`
- Create: `_memory/architecture.md`
- Create: `_memory/roadmap.md`
- Create: `_templates/session.md`
- Create: `_templates/decision.md`
- Create: `_templates/task.md`
- Create: `_templates/build.md`
- Create: `_tasks/active/.gitkeep`
- Create: `_tasks/completed/.gitkeep`
- Create: `_decisions/.gitkeep`
- Create: `_sessions/.gitkeep`
- Create: `_builds/.gitkeep`
- Create: `_knowledge/.gitkeep`
- Create: `_learnings/.gitkeep`
- Create: `_handoffs/.gitkeep`

**Interfaces:**
- Consumes: spec do Dev Brain.
- Produces: Vault Markdown navegável sem depender de plugins do Obsidian.

- [ ] **Step 1: Criar `.gitignore`**

Conteúdo mínimo:

```gitignore
# Obsidian state local/volatile
.obsidian/workspace.json
.obsidian/workspace-mobile.json
.obsidian/cache/
.trash/

# OS/editor noise
.DS_Store
Thumbs.db
*.tmp
*.log

# Secrets / local-only
.env
.env.*
*.pem
*.p12
*.mobileprovision
secrets/
_private/
```

- [ ] **Step 2: Criar `README.md`**

Conteúdo:

```markdown
# JARVIS-DEV-BRAIN

Second Brain privado do desenvolvimento do Projeto JARVIS.

## Fonte de verdade
- Código/runtime: `automacuniao-sudo/OpenVision` → `jarvis-dev`
- Memória de desenvolvimento: este repositório → `main`

## Leia primeiro
1. `00-Dashboard.md`
2. `_memory/current-state.md`
3. `_memory/roadmap.md`
4. tarefa ativa relacionada

## Regra de segurança
Nunca versionar secrets, credenciais ou tokens.
```

- [ ] **Step 3: Criar `AGENTS.md` do Brain**

Conteúdo:

```markdown
# JARVIS Dev Brain — Agent Rules

Este repositório é memória operacional do desenvolvimento, não o código do produto.

## Ao iniciar
Leia `00-Dashboard.md`, `_memory/current-state.md` e `_memory/roadmap.md`.

## Ao escrever
Promova somente informação duradoura e verificável:
- decisões aprovadas;
- mudanças reais de estado;
- builds/testes com evidência;
- tarefas concretas;
- aprendizados reutilizáveis;
- handoffs.

Não grave chain-of-thought, logs gigantes, tentativas descartadas ou secrets.

## Fonte de verdade
Código: `automacuniao-sudo/OpenVision`, branch `jarvis-dev`.
Brain: este repositório, branch `main`.

## Workflows nomeados
- `daily-briefing`: ler Dashboard → current-state → roadmap → tarefa ativa.
- `braindump`: classificar entrada antes de persistir.
- `end-session`: consolidar sessão, estado, decisões, builds, tarefas e learnings com evidência.
```

- [ ] **Step 4: Criar `00-Dashboard.md` inicial**

```markdown
# JARVIS — Dashboard

## Estado estável
- Produto: `automacuniao-sudo/OpenVision`
- Branch: `jarvis-dev`
- Versão validada: `2.10.0 (42)`

## Últimos marcos
- Build 42: diagnóstico facial validado no iPhone físico.
- PR #17: Build 42 mergeada em `jarvis-dev`.
- PR #18: sincronização controlada da governança da `main` concluída.

## Próximas prioridades aprovadas
1. JARVIS-DEV-BRAIN / ambiente Codex + Obsidian.
2. Second Brain + PersonProfile do JARVIS runtime.
3. Learning Engine do JARVIS runtime.

## Adiados
- OpenClaw / Issue #4.
- Router JARVIS v1.
- Spotify e integrações adicionais.

## Bloqueado por hardware
- teste Ray-Ban end-to-end.
```

- [ ] **Step 5: Criar templates com frontmatter mínimo**

`_templates/session.md`:

```markdown
---
type: session
status: active
date: YYYY-MM-DD
project: JARVIS
source: codex
related_repo: automacuniao-sudo/OpenVision
related_branch: jarvis-dev
---

# Sessão — título

## Contexto

## Ações

## Decisões

## Evidências

## Pendências

## Links
```

`_templates/decision.md`:

```markdown
---
type: decision
status: accepted
date: YYYY-MM-DD
project: JARVIS
---

# ADR-XXXX — título

## Contexto

## Decisão

## Consequências

## Evidências / links
```

`_templates/task.md`:

```markdown
---
type: task
status: active
date: YYYY-MM-DD
project: JARVIS
related_repo: automacuniao-sudo/OpenVision
---

# Tarefa — título

## Objetivo

## Branch/worktree

## Critérios de aceite

## Evidências

## Bloqueios

## Handoff
```

`_templates/build.md`:

```markdown
---
type: build
status: pending
project: JARVIS
---

# Build N

## Versão

## Commit / PR

## CI

## Artefato

## Teste físico

## Resultado
```

- [ ] **Step 6: Criar as pastas vazias com `.gitkeep`**

No PowerShell, dentro de `Jarvis-Brain`:

```powershell
$dirs = @('_decisions','_sessions','_builds','_knowledge','_learnings','_handoffs','_tasks/active','_tasks/completed')
foreach ($d in $dirs) {
  New-Item -ItemType Directory -Force -Path $d | Out-Null
  New-Item -ItemType File -Force -Path (Join-Path $d '.gitkeep') | Out-Null
}
New-Item -ItemType Directory -Force -Path '_memory','_templates' | Out-Null
```

- [ ] **Step 7: Verificar estrutura**

```powershell
Get-ChildItem -Recurse -Force | Select-Object FullName
```

Expected: todos os caminhos listados em **Files** existem.

- [ ] **Step 8: Commit e push**

```powershell
git add .
git diff --cached --check
git commit -m "feat: bootstrap JARVIS Dev Brain vault"
git push
```

---

### Task 4: Consolidar o estado atual do projeto

**Files:**
- Modify: `00-Dashboard.md`
- Create/Modify: `_memory/current-state.md`
- Create/Modify: `_memory/architecture.md`
- Create/Modify: `_memory/roadmap.md`
- Create: `_builds/Build-40.md`
- Create: `_builds/Build-41.md`
- Create: `_builds/Build-42.md`

**Interfaces:**
- Consumes: `OpenVision/jarvis-dev`, PRs #14/#15/#17/#18, backlog aprovado e evidências de CI/teste físico.
- Produces: snapshot canônico e verificável do estado atual.

- [ ] **Step 1: Preencher `_memory/current-state.md`**

O documento deve conter, no mínimo:

```markdown
# Estado atual do JARVIS

## Produto
- Repo: `automacuniao-sudo/OpenVision`
- Branch estável: `jarvis-dev`
- Versão validada: `2.10.0 (42)`

## Base estável
- Build 41 foi baseline física antes da Build 42.
- Build 42 foi validada no iPhone físico e mergeada.
- Governança da `main` foi sincronizada de forma controlada pela PR #18.

## Funcionalidades estáveis relevantes
- Gemini Live customizado.
- Kokoro streaming/FIFO e cancelamento seguro.
- wake word e barge-in estabilizados na linha Build 40.
- speaker verification / Owner Voice Lock.
- reconhecimento facial local.
- câmera frontal/traseira do iPhone com roteamento explícito.
- Native Tools.
- memória persistente atual do app.
- Meta DAT 0.9 integrado no código, com teste end-to-end de óculos ainda pendente.

## Próximas prioridades
1. Dev Brain + ambiente de agentes.
2. Second Brain + PersonProfile de runtime.
3. Learning Engine.

## Adiados
- OpenClaw / Issue #4.
- Router JARVIS v1.
- Spotify.

## Bloqueios
- validação Ray-Ban end-to-end depende do hardware.
```

- [ ] **Step 2: Preencher `_memory/architecture.md`**

Registrar somente arquitetura vigente: app iOS, Gemini Live, TTS/STT, Vision, câmera iPhone, Meta DAT, memória atual, Native Tools, CI e a nova separação `OpenVision` vs `JARVIS-DEV-BRAIN`.

- [ ] **Step 3: Preencher `_memory/roadmap.md`**

Usar o backlog aprovado como fonte e separar explicitamente:

```markdown
## Agora
- JARVIS-DEV-BRAIN.
- preparar ambiente multiagente Codex/ChatGPT.

## Próximo
- Second Brain estruturado.
- PersonProfile.
- Learning Engine.

## Depois
- Router JARVIS v1.
- Spotify e integrações adicionais.
- melhorias upstream ainda não portadas: Live Vision/FrameChange, scene-gated history, otimizações de modelos locais e telemetria.

## Adiado
- OpenClaw / Issue #4.

## Bloqueado
- Ray-Ban end-to-end até hardware disponível.
```

- [ ] **Step 4: Criar notas das Builds 40, 41 e 42**

Cada nota deve registrar versão/commit/PR, mudanças principais, CI e teste físico conhecido. Não marcar o que não foi testado.

- [ ] **Step 5: Verificar consistência com GitHub**

Comparar os SHAs/PRs usados nas notas com o histórico real antes do commit.

- [ ] **Step 6: Commit e push**

```powershell
git add 00-Dashboard.md _memory _builds
git diff --cached --check
git commit -m "docs: seed canonical JARVIS project state"
git push
```

---

### Task 5: Registrar decisões arquiteturais e conhecimento reutilizável

**Files:**
- Create: `_decisions/ADR-0001-jarvis-dev-is-product-base.md`
- Create: `_decisions/ADR-0002-separate-dev-brain-from-runtime-brain.md`
- Create: `_decisions/ADR-0003-pr-based-agent-workflow.md`
- Create: `_decisions/ADR-0004-defer-openclaw-router-spotify.md`
- Create: `_knowledge/Gemini-Live.md`
- Create: `_knowledge/Face-Recognition.md`
- Create: `_knowledge/Audio-and-Kokoro.md`
- Create: `_knowledge/Meta-DAT.md`
- Create: `_knowledge/CI-and-Builds.md`

**Interfaces:**
- Consumes: estado consolidado e documentação do produto.
- Produces: memória histórica/explicativa que não precisa ser reconstruída a partir de chats.

- [ ] **Step 1: Criar ADRs com decisão e consequência explícitas**

Cada ADR deve usar `_templates/decision.md`, data real e links para PR/commit quando aplicável.

- [ ] **Step 2: Criar knowledge notes curtas**

Cada nota deve responder:
- o que é o subsistema;
- estado atual;
- arquivos/serviços principais no `OpenVision`;
- riscos conhecidos;
- links para docs do produto.

Não copiar código nem documentação longa para o Brain.

- [ ] **Step 3: Revisar duplicação**

Se um detalhe já estiver melhor documentado no `OpenVision`, manter no Brain apenas resumo + link/caminho.

- [ ] **Step 4: Commit e push**

```powershell
git add _decisions _knowledge
git diff --cached --check
git commit -m "docs: seed JARVIS decisions and knowledge"
git push
```

---

### Task 6: Documentar os workflows `daily-briefing`, `braindump` e `end-session`

**Files:**
- Create: `_knowledge/Brain-Workflows.md`
- Modify: `AGENTS.md`

**Interfaces:**
- Consumes: estrutura canônica do Vault.
- Produces: protocolos reproduzíveis por qualquer agente, sem depender de comandos proprietários.

- [ ] **Step 1: Documentar `daily-briefing`**

Entrada sugerida ao Codex/ChatGPT:

```text
Execute o workflow daily-briefing do JARVIS Dev Brain. Leia Dashboard, current-state, roadmap e a tarefa ativa relacionada. Responda com estado, base estável, tarefa ativa, próximo passo e bloqueios. Não invente estado ausente do Brain/GitHub.
```

- [ ] **Step 2: Documentar `braindump`**

Entrada sugerida:

```text
Classifique este braindump antes de persistir. Ideia vai para roadmap/backlog; decisão aprovada vira ADR; fato técnico confirmado vai para knowledge/current-state; tarefa concreta vai para _tasks/active; aprendizado duradouro vai para _learnings. Não grave rascunhos transitórios como estado canônico.
```

- [ ] **Step 3: Documentar `end-session`**

Entrada sugerida:

```text
Execute end-session. Registre uma nota em _sessions, atualize current-state somente se algo realmente mudou, mova/conclua tarefas conforme evidência, crie ADR apenas para decisão aprovada, registre build/teste apenas com evidência e capture learnings reutilizáveis. Nunca grave secrets ou chain-of-thought.
```

- [ ] **Step 4: Adicionar referências em `AGENTS.md`**

O `AGENTS.md` deve apontar para `_knowledge/Brain-Workflows.md` como especificação dos três workflows.

- [ ] **Step 5: Commit e push**

```powershell
git add AGENTS.md _knowledge/Brain-Workflows.md
git diff --cached --check
git commit -m "docs: define Dev Brain session workflows"
git push
```

---

### Task 7: Conectar o Vault ao Obsidian e ao Codex

**Files:**
- Local-only Obsidian config under `C:\Users\Kaue\Documents\ChatGPT\Jarvis-Brain\.obsidian\`.
- Optional local junction: `C:\Users\Kaue\Documents\ChatGPT\Jarvis\_brain`.
- Modify `OpenVision/.gitignore` only if the fallback junction is used, via uma branch/PR separada.

**Interfaces:**
- Consumes: clone local do Brain.
- Produces: Obsidian navega o Brain; Codex consegue ler Brain e produto na mesma tarefa.

- [ ] **Step 1: Abrir o Vault no Obsidian**

Obsidian → **Open folder as vault** → selecionar:

```text
C:\Users\Kaue\Documents\ChatGPT\Jarvis-Brain
```

Verificar que `00-Dashboard.md` e as pastas aparecem no File Explorer do Obsidian.

- [ ] **Step 2: Tentar adicionar o Brain como pasta secundária do Project Jarvis no Codex**

No Project `Jarvis`, procurar opção de adicionar pasta/folder ao projeto e selecionar:

```text
C:\Users\Kaue\Documents\ChatGPT\Jarvis-Brain
```

Se a instalação atual expuser essa opção, não usar junction.

- [ ] **Step 3: Fallback determinístico se a UI não suportar pasta secundária**

Criar junction local dentro do clone do produto:

```powershell
cd C:\Users\Kaue\Documents\ChatGPT\Jarvis
New-Item -ItemType Junction -Path _brain -Target C:\Users\Kaue\Documents\ChatGPT\Jarvis-Brain
```

Antes de qualquer commit no `OpenVision`, adicionar `_brain/` ao `.gitignore` em branch separada e abrir PR; nunca versionar o conteúdo do Brain no repositório público.

- [ ] **Step 4: Testar leitura pelo Codex**

Em uma thread nova do Project Jarvis, pedir:

```text
Leia o JARVIS Dev Brain e execute daily-briefing. Diga a versão estável atual, as três próximas prioridades e o que está adiado.
```

Expected: resposta baseada em `00-Dashboard.md`, `_memory/current-state.md` e `_memory/roadmap.md`.

---

### Task 8: Habilitar acesso remoto do ChatGPT ao repositório privado do Brain

**Files:**
- Nenhum arquivo obrigatório.

**Interfaces:**
- Consumes: GitHub App/connector já usado pelo ChatGPT.
- Produces: ChatGPT consegue ler `JARVIS-DEV-BRAIN` sem filesystem local.

- [ ] **Step 1: Verificar se o repositório privado aparece para o conector**

Após criação/push do Brain, consultar os repositórios disponíveis pelo GitHub connector.

Expected: `automacuniao-sudo/JARVIS-DEV-BRAIN` aparece.

- [ ] **Step 2: Se não aparecer, autorizar o repositório na instalação do GitHub App**

GitHub → Settings → Applications/Installed GitHub Apps → conexão usada pelo ChatGPT → Repository access → incluir `JARVIS-DEV-BRAIN`.

- [ ] **Step 3: Provar leitura remota**

Pedir ao ChatGPT:

```text
Leia o JARVIS-DEV-BRAIN e me diga a versão estável do JARVIS e as prioridades atuais.
```

Expected: valores coincidem com `current-state.md`/roadmap.

---

### Task 9: Importar o histórico relevante sem importar transcripts completos

**Files:**
- Create: `_sessions/2026-09-07-bootstrap-dev-brain.md`
- Create: `_learnings/Build-and-Release-Discipline.md`
- Create additional notes only when the content survives as knowledge duradouro.

**Interfaces:**
- Consumes: estado dos chats, PRs/commits e backlog já consolidado.
- Produces: memória suficiente para continuar o projeto sem reler conversas antigas.

- [ ] **Step 1: Criar sessão histórica do bootstrap**

Registrar:
- motivação para Codex + ChatGPT compartilharem memória;
- decisão de usar Obsidian/Markdown/Git;
- separação DEV-BRAIN vs runtime BRAIN;
- estrutura criada;
- estado de Build 42 e PR #18;
- próximos passos.

- [ ] **Step 2: Criar learning sobre disciplina de builds**

Registrar como regra reutilizável:
- branch isolada;
- RED/GREEN quando aplicável;
- CI completo;
- IPA quando o evento gerar artefato;
- teste físico para hardware/áudio/câmera/MLX;
- merge somente após aprovação humana.

- [ ] **Step 3: Validar cobertura**

Depois da importação, uma thread nova deve conseguir responder sem chats antigos:
- qual é a branch estável;
- qual é a versão validada;
- quais features principais estão estáveis;
- o que está adiado;
- quais são as próximas prioridades;
- quais itens dependem de Ray-Ban físico.

- [ ] **Step 4: Commit e push**

```powershell
git add _sessions _learnings
git diff --cached --check
git commit -m "docs: import durable JARVIS development history"
git push
```

---

### Task 10: Teste cruzado Codex ↔ GitHub ↔ ChatGPT

**Files:**
- Create: `_decisions/ADR-0005-dev-brain-cross-client-test.md`
- Create: `_sessions/2026-09-07-cross-client-validation.md`

**Interfaces:**
- Consumes: Codex local, GitHub privado, ChatGPT remoto.
- Produces: evidência de que o Brain funciona como memória compartilhada real.

- [ ] **Step 1: Codex cria uma decisão de teste**

No Codex, criar ADR contendo uma frase de teste não sensível, por exemplo:

```markdown
## Decisão
Para validar o Dev Brain, o marcador de teste é `DEV-BRAIN-CROSS-CLIENT-001`.
```

Commit/push no `JARVIS-DEV-BRAIN/main`.

- [ ] **Step 2: ChatGPT recupera a decisão via GitHub**

Pedir ao ChatGPT, sem fornecer o marcador no prompt:

```text
Leia a ADR de validação cruzada mais recente no JARVIS-DEV-BRAIN e me diga o marcador registrado.
```

Expected: `DEV-BRAIN-CROSS-CLIENT-001`.

- [ ] **Step 3: ChatGPT registra confirmação em uma nova nota ou commit permitido**

Registrar no Brain que a leitura remota foi confirmada, sem alterar o marcador original.

- [ ] **Step 4: Codex faz pull e recupera a confirmação**

```powershell
cd C:\Users\Kaue\Documents\ChatGPT\Jarvis-Brain
git pull --ff-only
```

No Codex, pedir para localizar a confirmação escrita pelo ChatGPT.

- [ ] **Step 5: Registrar sessão de validação**

`_sessions/2026-09-07-cross-client-validation.md` deve registrar:
- commit Codex → GitHub;
- recuperação pelo ChatGPT;
- commit ChatGPT → GitHub, se suportado;
- recuperação pelo Codex;
- quaisquer limitações encontradas.

- [ ] **Step 6: Verificação final de secrets**

```powershell
git grep -n -I -E "(api[_-]?key|secret|password|token|BEGIN (RSA|OPENSSH|PRIVATE) KEY)" -- .
```

Revisar qualquer ocorrência manualmente. Expected: nenhuma credencial real versionada.

---

## Self-review do plano

- Cobertura do spec: todos os 10 critérios de aceite estão mapeados para Tasks 1–10.
- Separação de domínios: DEV-BRAIN e futuro runtime BRAIN permanecem distintos.
- Segurança: secrets são explicitamente excluídos, ignorados e verificados no final.
- Continuidade: há fluxo local (Codex/Obsidian) e remoto (ChatGPT/GitHub).
- Independência do Obsidian: conteúdo canônico continua Markdown puro.
- Importação: histórico duradouro é consolidado; transcripts integrais ficam fora por padrão.
- Validação cruzada: existe teste concreto Codex → GitHub → ChatGPT → GitHub → Codex.
