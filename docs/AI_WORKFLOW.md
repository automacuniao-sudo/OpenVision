# AI Development Workflow — OpenVision / JARVIS

Este documento é o runbook operacional para executar tarefas do OpenVision/JARVIS com os quatro chats Codex fixos. O fluxo normal é coordenado pelo ORCHESTRATOR, mantém a implementação isolada em uma branch de tarefa derivada de `jarvis-dev` e só termina em `ready_for_human` quando LEAD/REVIEWER e QA/BUILD tiverem produzido seus vereditos.

## Pipeline normal

```text
USER
  ↓
JARVIS — ORCHESTRATOR
  ↓
DEVELOPER
  ↓
LEAD / REVIEWER
  ↓
QA / BUILD
  ↓
ORCHESTRATOR
  ↓
USER approval / physical test / merge decision
```

O target do Pull Request e a base de toda tarefa são `jarvis-dev`. A branch de tarefa deve ser criada a partir do `origin/jarvis-dev` confirmado como atual; nenhuma implementação é feita diretamente na branch compartilhada.

## Os quatro chats fixos

### `JARVIS — ORCHESTRATOR`

É a interface principal com o usuário e o controlador do fluxo. No startup, leia os contratos e o contexto necessário nos dois repositórios:

- o repositório OpenVision/JARVIS;
- o repositório `JARVIS-DEV-BRAIN`.

`JARVIS-DEV-BRAIN/main` é a fonte canônica da memória de desenvolvimento. Somente o ORCHESTRATOR escreve nessa branch no fluxo normal; os demais papéis podem consumir o contexto fornecido, mas não fazem escritas canônicas.

Antes de iniciar qualquer tarefa significativa, execute automaticamente o `daily-briefing` usando apenas a memória relevante do Brain. Em seguida, confirme `origin/jarvis-dev`, investigue o problema, crie um Task Brief autocontido, determine o modo de execução e coordene DEVELOPER → LEAD/REVIEWER → QA/BUILD. O ORCHESTRATOR é o único escritor canônico normal do Brain.

O Task Brief deve delimitar comportamento atual e desejado, causa ou hipótese, arquivos, plano, itens fora do escopo, critérios de aceite, validação e riscos. O ORCHESTRATOR não implementa para pular uma etapa delegada, não simula comunicação entre chats e não autoriza merge.

### `JARVIS — DEVELOPER`

Recebe somente o Task Brief aprovado, o contexto técnico e os arquivos necessários. Trabalha em branch/worktree isolado, implementa apenas o plano, cria ou ajusta testes quando aplicável, executa as validações e entrega um Implementation Report com commit e evidências. Não redesenha a arquitetura nem escreve no Brain canônico.

### `JARVIS — LEAD / REVIEWER`

Recebe o Task Brief, o Implementation Report, o diff/commits e as evidências disponíveis. Faz revisão independente de escopo, causa raiz, regressões, concorrência, áudio, memória, testes e segurança. Retorna exatamente `APPROVED` ou `CHANGES_REQUIRED`; não implementa para encurtar o ciclo, não escreve no Brain canônico e não autoriza merge.

### `JARVIS — QA / BUILD`

Recebe o Task Brief, o veredito do LEAD/REVIEWER, a identidade da branch/commit/PR e as evidências de CI, build, testes e hardware. Valida os critérios de aceite e retorna exatamente `PASS`, `FAIL` ou `PHYSICAL_TEST_REQUIRED`. Não escreve no Brain canônico e não autoriza merge ou release.

## Startup e preparação Git

O ORCHESTRATOR deve confirmar a identidade da base antes de criar a branch da tarefa. O procedimento equivalente é:

```bash
git fetch origin --prune
git switch jarvis-dev
git pull --ff-only origin jarvis-dev
git worktree add ../OpenVision-task -b ai/YYYY-MM-DD-task-slug jarvis-dev
```

Na execução real, confirme que `origin/jarvis-dev` é a base esperada e atual (por exemplo, compare o commit remoto com o contexto da tarefa) antes de criar a branch. O worktree deve ficar em `ai/YYYY-MM-DD-task-slug`; `jarvis-dev` é a base/target compartilhada, não o local de implementação.

## Escolha do modo de execução

### AUTOMATED MODE

AUTOMATED MODE só é permitido quando a sessão atual comprovar que consegue, de verdade:

1. spawn/dispatch de um worker ou subagent;
2. fornecer a ele contexto e tarefa isolados;
3. receber o resultado produzido por ele;
4. enviar trabalho de follow-up, de preferência ao mesmo worker para correções.

Quando os quatro recursos existem, o ORCHESTRATOR despacha o DEVELOPER com Task Brief autocontido, recebe o Implementation Report, encaminha a revisão ao LEAD/REVIEWER e depois a validação ao QA/BUILD. Findings de correção retornam ao mesmo DEVELOPER sempre que possível.

### MANUAL FALLBACK MODE

Se qualquer uma das quatro capacidades não estiver realmente disponível, use MANUAL FALLBACK MODE e diga explicitamente que não houve delegação real. Os chats não se comunicam automaticamente: o usuário copia os artefatos para o chat dedicado seguinte e traz cada resultado de volta ao ORCHESTRATOR. O handoff exato é:

1. o ORCHESTRATOR prepara o Task Brief; o usuário copia-o para `JARVIS — DEVELOPER` e traz o Implementation Report, commit e evidências de volta ao ORCHESTRATOR;
2. o usuário copia o Task Brief, o Implementation Report, o commit, o diff e as evidências para `JARVIS — LEAD / REVIEWER` e traz o veredito de volta ao ORCHESTRATOR;
3. em `CHANGES_REQUIRED`, o usuário copia os findings e o Task Brief para o mesmo `JARVIS — DEVELOPER`, traz o report corrigido de volta ao ORCHESTRATOR e então copia o pacote atualizado para `JARVIS — LEAD / REVIEWER` para re-review;
4. em `APPROVED`, o usuário copia o Task Brief, o veredito, o commit e as evidências para `JARVIS — QA / BUILD` e traz o resultado QA de volta ao ORCHESTRATOR;
5. o usuário traz ao ORCHESTRATOR o resultado `PASS`, `FAIL` ou `PHYSICAL_TEST_REQUIRED` produzido pelo QA, sem atribuir comunicação direta entre os chats;
6. após QA adequado, o ORCHESTRATOR prepara PR/CI e retorna ao usuário para aprovação, teste físico ou decisão de merge.

Não diga que um worker, outro chat ou uma revisão foi acionado quando isso não aconteceu.

## Fix loop e gate QA

O ciclo de correção é fechado e não vira refatoração aberta:

```text
LEAD CHANGES_REQUIRED → same DEVELOPER corrects → LEAD re-review
LEAD APPROVED → QA/BUILD
QA FAIL → correction/review loop
QA PHYSICAL_TEST_REQUIRED → exact test steps to user
QA PASS → ready_for_human
```

Em `QA PHYSICAL_TEST_REQUIRED`, o QA deve fornecer passos exatos: o que instalar, onde tocar, o que falar ou fazer, resultado esperado e logs a coletar se falhar. O ORCHESTRATOR encaminha isso ao usuário e não declara o requisito físico validado sem evidência. CI e CodeRabbit são camadas adicionais de qualidade; não substituem a revisão independente do LEAD/REVIEWER nem o gate do QA/BUILD.

## Pull Request, aprovação e merge

Depois de `APPROVED` e de um veredito QA adequado, o ORCHESTRATOR pode abrir ou atualizar o PR com target `jarvis-dev`. O PR deve registrar problema, causa raiz, solução, arquivos, testes, CI/CodeRabbit, teste físico quando necessário e riscos conhecidos.

`ready_for_human` significa que o pacote está pronto para a decisão humana. Merge no `jarvis-dev`, release e qualquer teste físico dependente de hardware continuam exigindo aprovação ou ação explícita do usuário. Nem ORCHESTRATOR, nem DEVELOPER, nem LEAD/REVIEWER, nem QA/BUILD autoriza merge por conta própria.

## Escopo e segurança

- Use a menor mudança que satisfaça o Task Brief.
- Não escreva segredos, tokens ou credenciais no repositório.
- Não altere o Brain canônico fora do contrato do ORCHESTRATOR.
- Não use delays, timeouts ou supressão de erros para mascarar falhas.
- Registre limitações de simulador e a necessidade de iPhone/óculos reais quando aplicável.
