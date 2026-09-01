# AI Development Workflow — OpenVision

Este documento descreve o fluxo de desenvolvimento com agentes no OpenVision/JARVIS.

## Modo recomendado: ORCHESTRATOR

O usuário conversa com um único chat principal:

`OpenVision — ORCHESTRATOR`

Esse agente lê `.agents/ORCHESTRATOR.md` e atua como LEAD/controlador.

Fluxo desejado:

```text
USUÁRIO
   ↓
ORCHESTRATOR / LEAD
   ↓ investiga + Task Brief
DEVELOPER subagente
   ↓ implementa + testa + self-review
ORCHESTRATOR / LEAD
   ↓ revisão
   ├── CHANGES_REQUIRED → DEV corrige → revisão
   └── APPROVED
           ↓
        Pull Request
           ↓
       CodeRabbit / CI
           ↓
     aprovação humana
           ↓
          main
```

O ORCHESTRATOR deve verificar o que a sessão realmente expõe. Se não houver ferramenta real de delegação/subagente, ele usa o modo manual abaixo em vez de simular comunicação.

## Prompt inicial do ORCHESTRATOR

Crie um novo chat no projeto e use:

```text
Você é o ORCHESTRATOR deste repositório.

Leia obrigatoriamente:
AGENTS.md
.agents/ORCHESTRATOR.md
.agents/LEAD.md
.agents/DEVELOPER.md
README.md
docs/AI_WORKFLOW.md

Siga essas regras durante toda a sessão.

Quero falar apenas com você. Para cada tarefa:
1. descubra se esta sessão possui delegação/subagentes reais;
2. se possuir, opere em AUTOMATED MODE;
3. investigue como LEAD e encontre a causa raiz;
4. produza o Task Brief;
5. delegue a implementação a um DEVELOPER isolado;
6. receba o Implementation Report;
7. revise o diff;
8. se houver CHANGES_REQUIRED, mande o DEV corrigir e revise novamente;
9. quando estiver APPROVED, abra um PR;
10. nunca faça merge na main sem minha aprovação explícita.

Se a sessão não suportar delegação real, use MANUAL FALLBACK MODE e nunca finja que acionou outra thread.

Confirme os arquivos lidos e informe se a sessão está em AUTOMATED MODE ou MANUAL FALLBACK MODE.
```

## Modo automático

Quando delegação/subagentes estiver disponível, o usuário só envia a solicitação.

Exemplo:

```text
Quando eu digo "Ok Jarvis", às vezes entra em Listening e transcreve,
mas não responde. Investigue e corrija a causa raiz sem quebrar Gemini Live
nem OpenClaw. Faça o ciclo completo até o PR, mas não faça merge.
```

O ORCHESTRATOR deve continuar sozinho por:
- investigação;
- criação de branch/worktree;
- Task Brief;
- dispatch do DEV;
- implementação;
- testes;
- revisão;
- correções;
- re-review;
- abertura do PR.

Ele só para nos limites definidos em `.agents/ORCHESTRATOR.md`.

## Modo manual de fallback

Os chats já existentes continuam úteis:

### `OpenVision — LEAD`
Lê:
- `AGENTS.md`
- `.agents/LEAD.md`

Produz Task Brief e revisa o DEV.

### `OpenVision — DEV`
Lê:
- `AGENTS.md`
- `.agents/DEVELOPER.md`

Implementa Task Briefs e produz Implementation Report.

Fluxo:

```text
USUÁRIO → LEAD → copiar Task Brief → DEV → copiar Report → LEAD
```

Use esse modo somente quando o ORCHESTRATOR confirmar que a sessão atual não tem delegação real ou quando você quiser depurar os papéis separadamente.

## Isolamento Git

Nenhuma implementação em `main`.

Toda tarefa não trivial deve partir do HEAD atual de `main`.

Padrão:

`ai/YYYY-MM-DD-<slug>`

Exemplo:

```bash
git fetch origin
git switch main
git pull --ff-only
git worktree add ../OpenVision-task -b ai/2026-09-01-wake-word main
```

O DEV trabalha no worktree isolado quando possível.

## Regras de paralelismo

Paralelize apenas problemas realmente independentes.

Bom:
- um agente investiga UI;
- outro investiga um parser separado;
- arquivos e estado não se sobrepõem.

Ruim:
- dois agentes alterando `VoiceCommandService.swift`;
- dois agentes mexendo no mesmo AVAudioSession;
- dois agentes mudando a mesma máquina de estados.

Para uma única feature/bug, prefira sequência:
ORCHESTRATOR/LEAD → DEV → ORCHESTRATOR/LEAD.

## Revisão e fix loop

O DEV não aprova o próprio trabalho.

O ORCHESTRATOR/LEAD responde:
- `APPROVED`; ou
- `CHANGES_REQUIRED`.

Se houver findings Critical/Important:
1. retornar ao DEV;
2. corrigir;
3. rodar testes afetados;
4. revisar novamente.

Não transformar o fix loop em refatoração de escopo aberto.

## Pull Request

Após `APPROVED`, o ORCHESTRATOR pode abrir o PR.

Título exemplo:

`fix(voice): stabilize wake-word response flow`

O corpo deve registrar:
- problema;
- causa raiz;
- solução;
- testes;
- teste em dispositivo;
- riscos.

O CodeRabbit é uma camada adicional, não substitui o LEAD.

## Merge

O ORCHESTRATOR, LEAD e DEVELOPER não podem fazer merge em `main` sem aprovação humana explícita.

Antes de merge:
- LEAD/ORCHESTRATOR: `APPROVED`;
- CI relevante: verde ou limitação explicada;
- findings importantes: resolvidos;
- CodeRabbit relevante: tratado;
- iPhone físico testado quando a mudança tocar Bluetooth, áudio real, Meta DAT ou MLX;
- usuário autorizou o merge.

## Resultado esperado

No modo automático, a experiência para o usuário deve ser próxima de:

```text
Usuário: "Corrija o bug X e faça tudo até o PR."

Orquestrador:
- investiga
- delega
- revisa
- manda corrigir
- valida
- abre PR

Orquestrador: "APPROVED. PR #N aberto. Falta apenas seu teste/aprovação para merge."
```

Sem cópia manual de Task Brief entre chats quando a plataforma disponibilizar delegação real.
