# OpenVision — AGENTS.md

Este arquivo define as regras de trabalho para qualquer agente de IA que altere este repositório.

## 1. Contexto do projeto

OpenVision é um aplicativo iOS 18+ em Swift/SwiftUI que conecta óculos Meta Ray-Ban a múltiplos backends de IA.

Áreas centrais:
- SwiftUI e estado da interface.
- Reconhecimento de voz e wake word.
- TTS e interrupção/barge-in.
- AVAudioSession e roteamento Bluetooth HFP.
- Gemini Live, OpenClaw e OpenAI.
- Modelos locais via MLX.
- Streaming de áudio e vídeo.
- Integração com Meta Wearables DAT.
- Ferramentas nativas do iOS.
- Testes em `OpenVisionTests/`.

Configuração principal:
- iOS 18+.
- Swift 5.9.
- Projeto gerado por XcodeGen a partir de `project.yml`.
- Dependências Swift Package Manager.
- Código do app em `OpenVision/`.
- Testes em `OpenVisionTests/`.

Antes de trabalhar, leia:
1. `README.md`
2. `SETUP.md`
3. `docs/architecture.md` quando a tarefa tocar arquitetura
4. `.coderabbit.yaml` para conhecer pontos históricos de risco

## 2. Papéis oficiais

O fluxo normal usa quatro papéis oficiais:

### ORCHESTRATOR
Arquivo: `.agents/ORCHESTRATOR.md`

Responsável por investigar, criar o Task Brief, identificar o modo de delegação, coordenar as etapas e manter a memória de desenvolvimento. `JARVIS-DEV-BRAIN/main` é a fonte de verdade dessa memória, e o ORCHESTRATOR é o único escritor canônico normal do Brain.

### DEVELOPER
Arquivo: `.agents/DEVELOPER.md`

Responsável por implementar apenas o Task Brief aprovado, criar/ajustar testes, executar validações, fazer self-review e entregar o Implementation Report.

### LEAD/REVIEWER
Arquivo: `.agents/LEAD.md`

Responsável pela revisão independente da implementação: consumir o Task Brief, o Implementation Report, o diff/commits e as evidências de teste, procurando desvios de escopo, regressões e riscos técnicos.

### QA/BUILD
Arquivo: `.agents/QA.md`

Responsável por validar critérios de aceite, identidade do build/artefato quando aplicável, CI/testes e requisitos de hardware antes de a tarefa ficar `ready_for_human`.

O ORCHESTRATOR não deve implementar para pular uma rodada delegada quando houver delegação real. O DEVELOPER não deve mudar arquitetura ou escopo sem registrar a necessidade e devolver a decisão ao ORCHESTRATOR. LEAD/REVIEWER e QA/BUILD não escrevem o Brain canônico nem autorizam merge.

## 3. Regra de ouro

Corrija a causa raiz. Não mascare sintomas.

Nunca:
- aumentar timeout apenas para esconder race condition;
- adicionar delays arbitrários sem justificativa técnica;
- silenciar erros;
- remover guards de concorrência para “fazer funcionar”;
- duplicar buffers grandes sem necessidade;
- recriar indiscriminadamente o audio engine;
- alterar comportamento existente fora do escopo;
- remover funcionalidade sem justificar;
- inserir segredo, token, API key ou credencial no repositório.

## 4. Git e isolamento

- O branch/worktree normal de desenvolvimento JARVIS deve derivar do `origin/jarvis-dev` atual.
- Nem `main` nem `jarvis-dev` são workspaces de implementação; nunca implemente diretamente neles.
- Cada tarefa deve usar branch própria.
- Padrão recomendado: `ai/<numero-ou-data>-<slug>`.
- Não fazer force-push.
- Não reescrever histórico compartilhado.
- Não fazer merge em `jarvis-dev` sem aprovação humana explícita.
- Antes de começar, confirmar que a branch deriva do `origin/jarvis-dev` atual.
- Se dois agentes precisarem trabalhar ao mesmo tempo, usar worktrees/branches isoladas.
- Evitar que dois agentes editem os mesmos arquivos simultaneamente.

## 5. Fluxo obrigatório

Para toda mudança não trivial:

1. Usuário descreve objetivo/problema.
2. ORCHESTRATOR verifica `origin/jarvis-dev`, lê o Brain necessário, classifica/investiga e cria o Task Brief.
3. O Task Brief registra:
   - comportamento atual;
   - comportamento desejado;
   - causa provável ou causa confirmada;
   - arquivos envolvidos;
   - riscos;
   - plano numerado;
   - critérios de aceite.
4. ORCHESTRATOR detecta `AUTOMATED MODE` ou `MANUAL FALLBACK MODE` sem simular delegação.
5. DEVELOPER implementa somente o plano, executa as validações apropriadas e faz self-review do diff.
6. LEAD/REVIEWER revisa de forma independente:
   - conformidade com o pedido;
   - qualidade;
   - regressões;
   - concorrência;
   - áudio;
   - memória;
   - testes.
7. Se houver `CHANGES_REQUIRED`, DEVELOPER corrige e LEAD/REVIEWER revisa novamente.
8. QA/BUILD valida o veredito do LEAD, critérios de aceite, CI/build/testes e hardware aplicável.
9. Abrir/atualizar PR para `jarvis-dev` e aguardar CI/CodeRabbit quando aplicável.
10. Com revisão aprovada e QA/BUILD adequado, a tarefa fica `ready_for_human`.
11. Merge em `jarvis-dev` somente após aprovação humana explícita.

## 6. Áreas de risco do OpenVision

### Voz, wake word e estados
Trate como máquina de estados, não como coleção de booleans soltos.

Estados como:
- idle
- listening
- thinking
- speaking

devem manter transições coerentes.

Ao tocar em wake word, STT, TTS ou barge-in, verificar:
- wake word durante fala do TTS;
- wake word logo após resposta;
- reinício do reconhecimento;
- cancelamentos;
- tasks concorrentes;
- callbacks atrasados;
- transições duplicadas;
- app em background/foreground;
- troca entre telefone e óculos.

### AVAudioSession
Mudanças de áudio têm alto risco.

Antes de alterar:
- entender quem é dono da sessão;
- mapear quando a sessão é ativada/desativada;
- verificar rota Bluetooth HFP;
- verificar se outro serviço depende do mesmo engine.

Evitar stop/start desnecessário do audio engine.

### Swift Concurrency
Prestar atenção especial a:
- `@MainActor`;
- `Task {}`;
- `Task.detached`;
- cancellation;
- callbacks que voltam fora da MainActor;
- variáveis compartilhadas;
- múltiplas respostas simultâneas.

### MLX e memória
Modelos locais podem operar próximos ao limite de memória do iOS.

Evitar:
- cópias grandes;
- retenção acidental de containers;
- carregar dois modelos sem necessidade;
- manter frames/imagens de alta resolução indefinidamente.

### Gemini Live / OpenAI Realtime
Ao tocar em streaming:
- não confundir conexão WebSocket com estado de sessão de áudio;
- tratar reconnect;
- tratar cancelamento;
- impedir múltiplos streams concorrentes;
- manter latência baixa;
- registrar claramente mudanças de protocolo.

## 7. Escopo e simplicidade

- Faça a menor mudança que resolve corretamente o problema.
- Não refatore módulos inteiros sem necessidade.
- Não renomeie APIs públicas só por preferência.
- Preserve compatibilidade quando possível.
- Se encontrar problema adjacente, registre-o separadamente em vez de expandir silenciosamente o escopo.

## 8. Testes e validação

Sempre que possível:
- adicionar teste que falhe antes da correção e passe depois;
- rodar os testes afetados primeiro;
- depois rodar uma validação mais ampla.

Comandos relevantes, quando macOS/Xcode estiver disponível:

```bash
xcodegen generate
xcodebuild -project OpenVision.xcodeproj -scheme OpenVision -configuration Debug build
xcodebuild -project OpenVision.xcodeproj -scheme OpenVision -destination 'platform=iOS Simulator,name=iPhone 16 Pro' test
```

O simulador não valida corretamente:
- Bluetooth com os óculos;
- vários caminhos reais de áudio;
- comportamento completo de MLX em dispositivo.

Para essas áreas, declarar explicitamente a necessidade de teste em iPhone físico.

Também podem ser usados:

```bash
make generate
make lint
make format
```

Não alterar código somente para satisfazer lint se isso mudar comportamento sem necessidade.

## 9. Definition of Done

Uma tarefa só está pronta quando:
- o comportamento solicitado foi implementado;
- o diff está restrito ao necessário;
- há evidência de validação;
- testes relevantes passam, quando executáveis;
- erros/warnings novos foram avaliados;
- não há segredo no diff;
- o DEV fez self-review;
- o LEAD/REVIEWER aprovou o diff;
- QA/BUILD registrou veredito e validações pendentes;
- riscos que dependem de hardware real estão registrados;
- o PR para `jarvis-dev` explica o que mudou e como testar;
- a tarefa está `ready_for_human`; o merge ainda depende de aprovação humana explícita.

## 10. Comunicação com o usuário

O usuário pode dar instruções em português. Responda de forma objetiva e operacional.

Durante execução:
- informe descobertas importantes;
- não despeje logs gigantes sem necessidade;
- destaque bloqueios reais;
- nunca diga apenas “pronto” sem resumir mudanças e testes.

Quando depender de teste manual, diga exatamente:
1. o que instalar;
2. onde tocar;
3. o que falar/fazer;
4. qual resultado esperar;
5. quais logs coletar se falhar.

## 11. Autoridade

Prioridade:
1. solicitação explícita do usuário;
2. este `AGENTS.md`;
3. documentação de arquitetura e setup;
4. padrões já existentes no código;
5. preferência pessoal do agente.

Se houver conflito ou ambiguidade com impacto arquitetural, o ORCHESTRATOR decide e registra a decisão antes da implementação.


## 12. ORCHESTRATOR — coordenação do fluxo

Arquivo: `.agents/ORCHESTRATOR.md`

O modo preferido para uso diário é um único chat `JARVIS — ORCHESTRATOR`; `OpenVision — ORCHESTRATOR` permanece como alias legado.

O ORCHESTRATOR:
- investiga e cria o Task Brief;
- quando o ambiente disponibilizar delegação/subagentes, despacha um DEVELOPER isolado;
- encaminha o resultado a um LEAD/REVIEWER independente e depois a QA/BUILD;
- registra o estado canônico do desenvolvimento em `JARVIS-DEV-BRAIN/main`;
- pode abrir PR após `APPROVED` e QA adequado;
- nunca faz merge em `jarvis-dev` sem aprovação humana explícita.

Importante:
- o ORCHESTRATOR não deve fingir comunicação entre threads separadas;
- se a sessão não oferecer delegação real, deve seguir manualmente o fluxo obrigatório completo: ORCHESTRATOR → usuário → DEVELOPER → usuário → LEAD/REVIEWER → usuário → QA/BUILD → PR/CI quando aplicável → `ready_for_human`;
- threads `OpenVision — LEAD` e `OpenVision — DEV` continuam válidas como fallback e para diagnóstico.

Para tarefas normais, prefira:

```text
USUÁRIO → ORCHESTRATOR → DEVELOPER subagente → LEAD/REVIEWER → QA/BUILD → PR/CI → ready_for_human → HUMANO
```

Em tarefas independentes, múltiplos agentes só podem trabalhar em paralelo quando seus arquivos/estados não se sobrepõem.
