# AI Development Workflow — OpenVision

Este documento descreve como operar dois agentes de IA no desenvolvimento diário do OpenVision.

## Objetivo

Você conversa principalmente com o LEAD.

O fluxo ideal é:

```text
USUÁRIO
   ↓
LEAD — investiga e cria Task Brief
   ↓
DEVELOPER — implementa e testa
   ↓
LEAD — revisa
   ├── CHANGES_REQUIRED → DEVELOPER corrige → LEAD revisa
   └── APPROVED
           ↓
        Pull Request
           ↓
       CodeRabbit
           ↓
     aprovação humana
           ↓
          main
```

## Sessões recomendadas no Codex

Crie duas threads/sessões separadas para o mesmo repositório.

### Sessão 1
Nome sugerido:

`OpenVision — LEAD`

Prompt inicial:

```text
Você é o agente LEAD deste repositório.
Leia AGENTS.md e .agents/LEAD.md e siga essas regras durante toda a sessão.
Sua função é investigar, planejar e revisar. Não implemente a tarefa principal.
Quando eu descrever um pedido, produza um Task Brief completo para o DEVELOPER.
Depois revise o diff produzido pelo DEVELOPER.
```

### Sessão 2
Nome sugerido:

`OpenVision — DEV`

Prompt inicial:

```text
Você é o agente DEVELOPER deste repositório.
Leia AGENTS.md e .agents/DEVELOPER.md e siga essas regras durante toda a sessão.
Implemente somente Task Briefs produzidos pelo LEAD.
Trabalhe sempre fora da main, execute testes apropriados e entregue um Implementation Report.
```

## Isolamento

Não coloque os dois editando o mesmo checkout ao mesmo tempo.

Preferência:
- LEAD usa o checkout principal para leitura/revisão;
- DEV usa uma Git worktree ou branch isolada por tarefa.

Exemplo:

```bash
git fetch origin
git switch main
git pull --ff-only

git worktree add ../OpenVision-task -b ai/2026-09-01-wake-word main
```

O DEV trabalha em `../OpenVision-task`.

Depois:

```bash
git -C ../OpenVision-task status
git -C ../OpenVision-task diff
```

## Como iniciar uma tarefa

Você pode falar normalmente com o LEAD, por exemplo:

```text
Quando eu digo "Ok Jarvis", às vezes aparece Listening, transcreve o que eu falo,
mas não responde. Investigue o projeto e crie um plano para corrigir sem quebrar
Gemini Live nem OpenClaw.
```

O LEAD deve investigar e devolver o Task Brief.

Copie o Task Brief para o DEV.

O DEV implementa e devolve o Implementation Report.

Passe o relatório/diff ao LEAD.

## Branches

Uma branch por tarefa.

Exemplos:
- `ai/2026-09-01-wake-word-reliability`
- `ai/2026-09-01-gemini-audio-streaming`
- `ai/2026-09-01-openclaw-reconnect`

Evite:
- `fix`
- `test2`
- `new`
- trabalho direto em `main`

## Ciclo de revisão

Se o LEAD retornar `CHANGES_REQUIRED`, envie todos os findings ao mesmo DEV.

Não comece outra refatoração.

O DEV:
1. corrige;
2. roda testes afetados;
3. atualiza o Implementation Report.

O LEAD faz uma revisão focada nas correções e procura regressões novas introduzidas pelo patch.

## Pull Request

Somente depois de `APPROVED`.

Título sugerido:

`fix(voice): stabilize wake-word response flow`

Corpo:

```markdown
## Problema
...

## Causa raiz
...

## Solução
...

## Testes
...

## Teste em dispositivo
...

## Riscos
...
```

O CodeRabbit já está configurado em `.coderabbit.yaml` e deve revisar automaticamente PRs não-draft, conforme configuração atual.

## Critérios para merge

Antes de merge:
- LEAD: APPROVED;
- CI/build aplicável: verde;
- findings Critical/Important: resolvidos;
- CodeRabbit: findings relevantes tratados;
- teste em iPhone físico realizado quando a mudança tocar Bluetooth, áudio real, Meta DAT ou modelos locais;
- usuário aprovou o merge.

## Quando paralelizar

Só use agentes paralelos quando as tarefas forem realmente independentes.

Bom exemplo:
- agente A investiga falha de UI;
- agente B investiga teste isolado de parser.

Mau exemplo:
- dois agentes modificando `VoiceCommandService.swift` ao mesmo tempo;
- um alterando AVAudioSession enquanto outro altera o mesmo fluxo de TTS.

Para implementação do mesmo feature, prefira sequência:
LEAD → DEV → LEAD.

## Registro de decisões

Para tarefas maiores, crie um arquivo temporário/issue com:
- objetivo;
- Task Brief;
- decisões do LEAD;
- Implementation Report;
- findings;
- resultado dos testes.

A conversa não deve ser a única fonte de verdade.

## Primeiro uso recomendado

Comece com um bug real e relativamente delimitado.

Fluxo:
1. descreva o bug ao LEAD;
2. valide o Task Brief;
3. envie ao DEV;
4. teste;
5. revise;
6. abra PR;
7. teste no iPhone;
8. faça merge.

Depois de 2–3 tarefas bem-sucedidas, automatize mais etapas, mas mantenha merge e ações destrutivas sob aprovação humana.
