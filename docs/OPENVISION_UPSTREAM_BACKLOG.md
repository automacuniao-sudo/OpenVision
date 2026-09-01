# JARVIS - Backlog de sincronizacao com OpenVision 2.13

Atualizado em: 2026-09-01

## Objetivo

Incorporar seletivamente ao JARVIS as evolucoes uteis do OpenVision upstream 2.11-2.13 sem substituir nossas implementacoes proprias nem fazer merge cego dos commits do upstream.

Estrategia: uma funcionalidade por branch, CI verde, IPA e validacao no iPhone antes de qualquer merge em `jarvis-dev`.

## Ja presente no JARVIS - nao duplicar

- [x] Silero VAD / deteccao acustica de fim de fala.
- [x] Meta Wearables DAT SDK 0.9.0.
- [x] DeviceSession moderno, com `start()` e espera por `.started`.
- [x] Camera pela API nova do DAT SDK.
- [x] Install/Update Glasses App.
- [x] Supressao de alertas de stream esperados quando o app esta inativo/background.
- [x] Reconhecimento facial local e fallback para camera do iPhone.
- [x] Gemini Live customizado e Diagnostics.
- [x] Memoria persistente por voz.
- [x] Speaker verification / Owner Voice Lock da Build 39.

## P0 - Continuous Live Vision e memoria visual

- [ ] Implementar continuous watch loop no modo de video local.
- [ ] Percepcao silenciosa por padrao.
- [ ] Comandos opcionais para iniciar/parar narracao.
- [ ] Adicionar `FrameChange.swift`.
- [ ] Gerar thumbnails simplificados para comparacao de cenas.
- [ ] Definir threshold de mudanca de cena.
- [ ] Adicionar dwell gate antes de analisar a cena.
- [ ] Intervalo minimo entre inferencias (referencia upstream: ~4 s).
- [ ] Reduzir frames ambientais para aproximadamente 512 px.
- [ ] Descricoes ambientais curtas e deterministicas (temperatura 0).
- [ ] Tornar inferencia ambiente cancelavel.
- [ ] Dar prioridade absoluta ao turno do usuario.
- [ ] Cache da descricao atual com texto, horario e thumbnail.
- [ ] Validar identidade da cena antes de usar o cache.
- [ ] Resposta instantanea para perguntas visuais genericas quando o cache ainda corresponde a cena.
- [ ] Memoria visual rolante das ultimas aproximadamente 5 cenas.
- [ ] Usar cenas antigas apenas em perguntas que se referem ao passado.
- [ ] Scene-gated conversation history: nova cena = fresh eyes.
- [ ] Manter historico para follow-ups apenas quando a cena continua a mesma.
- [ ] Impedir que contexto textual antigo domine os pixels atuais.
- [ ] Quarentena de recusas visuais antigas como "please upload an image".
- [ ] Orientacao deterministica quando pergunta visual chega sem imagem.
- [ ] Testes automatizados para FrameChange, dwell e threshold.

## P1 - Kokoro TTS streaming

- [ ] Adicionar `beginStreaming()`.
- [ ] Adicionar `speakChunk()`.
- [ ] Adicionar `endStreaming()`.
- [ ] Sintetizar/falar frase por frase enquanto o LLM ainda gera.
- [ ] Adicionar FIFO drainer para preservar ordem das frases.
- [ ] Corrigir corrida quando a geracao termina antes da primeira sintese.
- [ ] Teardown/cancelamento seguro para nao deixar `isSpeaking` travado.
- [ ] Incluir Kokoro corretamente na logica de barge-in.
- [ ] Medir contencao de GPU entre Kokoro e modelo local no iPhone.

## P1 - Otimizacao de modelos locais

- [ ] Separar prompt em `stable` e `perTurn`.
- [ ] Adicionar `PromptDetail.verbose` e `PromptDetail.concise`.
- [ ] Usar prompt concise no Bonsai 8B.
- [ ] Manter prompt verbose nos modelos menores.
- [ ] Adicionar `ChatSession` persistente para roteamento.
- [ ] Reutilizar KV prefix cache entre turnos.
- [ ] Invalidar cache quando modelo, prompt ou modo mudar.
- [ ] Semear historico somente ao criar uma nova sessao.
- [ ] Adicionar caminho `cachedGenerate()` com streaming.
- [ ] Medir TTFT antes/depois no dispositivo real.

## P2 - Barge-in, wake word e stop

- [ ] Permitir interrupcao enquanto o modelo esta em `.thinking`.
- [ ] Aceitar wake word no meio do buffer quando nenhum audio do assistente esta tocando.
- [ ] Exigir wake word no inicio do buffer apenas quando houver risco real de eco.
- [ ] Matching de `stop` por limite de palavra, nao substring.
- [ ] Em live mode: `stop` = silenciar/cancelar resposta.
- [ ] Em live mode: `stop video` = encerrar a sessao de video.
- [ ] Guard deterministico para palavra de parada nao virar pergunta ao modelo.
- [ ] Unificar as rotas de full stop.
- [ ] Comparar cada mudanca com nossas alteracoes de Gemini Live e Owner Voice Lock antes de portar.

## P3 - Telemetria e observabilidade

- [ ] Adicionar `MetricsCollector`.
- [ ] Adicionar `TurnTimeline`.
- [ ] Adicionar `SystemMetrics`.
- [ ] Adicionar protocolo `MetricsSink`.
- [ ] Adicionar `InfluxMetricsSink`.
- [ ] Adicionar stack InfluxDB + Grafana opcional.
- [ ] Medir speech end -> commit.
- [ ] Medir commit -> first token (TTFT).
- [ ] Medir generation time e tokens/s.
- [ ] Medir TTS request -> first audio (TTS TTFB).
- [ ] Medir perceived latency.
- [ ] Medir sucesso/falha (RED metrics).
- [ ] Medir interruption rate.
- [ ] Medir saude do STT: wake words, comandos completos e recognizer restarts.
- [ ] Tags corretas por modelo, backend e TTS.
- [ ] Restaurar sink de telemetria automaticamente no launch.
- [ ] Auditar agregacoes/queries do Grafana (median, p95, p99, last-value).

## Ordem recomendada

1. Continuous Live Vision + FrameChange + memoria visual.
2. Scene-gated history e protecoes contra contexto visual obsoleto.
3. Kokoro streaming + FIFO + interrupcao segura.
4. Prompt concise + ChatSession/KV prefix cache.
5. Revisao seletiva de barge-in, wake word e stop.
6. Telemetria completa.

## Regra de integracao

1. Criar branch isolada.
2. Portar apenas as ideias/commits necessarios.
3. Adaptar OpenVision -> JARVIS preservando Gemini Live, OpenClaw, camera do iPhone, face recognition, memoria e voice auth.
4. Compilar testes e app.
5. Gerar IPA.
6. Validar no iPhone.
7. Comparar comportamento com a Build 39.
8. Somente depois fazer merge em `jarvis-dev`.

## Checklist de regressao

- [ ] Wake word "Ok Jarvis" repetivel.
- [ ] Gemini Live sem Owner Voice Lock: conversa continua e barge-in.
- [ ] Gemini Live com Owner Voice Lock: STT -> speaker verification -> texto verificado -> Gemini.
- [ ] Face recognition reconhece cadastro persistente anterior.
- [ ] Camera Ray-Ban e fallback da camera do iPhone.
- [ ] OpenClaw basico nao regride.
- [ ] Live Vision acompanha a cena atual depois de virar a cabeca.
- [ ] Memoria visual responde sobre cena passada sem contaminar o presente.
- [ ] Kokoro mantem frases em ordem e inicia fala antes do fim da geracao.
- [ ] "stop" silencia e "stop video" encerra video.
- [ ] Monitorar thermal state em sessao longa de Continuous Live Vision.

## Projeto externo inspirado em JARVIS - analise do "PROMPT JARVIS"


### Ideias aprovadas para aproveitar no JARVIS

Estas sao as ideias do documento externo que consideramos realmente uteis para o nosso projeto nativo:

- [ ] **Second Brain estruturado** - Evoluir a memoria de frases soltas para notas estruturadas, categorias, metadados e relacoes.
- [ ] **Relacoes entre memorias** - Conectar pessoas, projetos, metas, preferencias e outros fatos em vez de manter apenas uma lista plana.
- [ ] **Unificar rosto + voz + memoria** - Criar um `PersonProfileStore` com `personId` persistente ligando face embeddings, speaker embedding, aliases e fatos.
- [ ] **Memoria viva automatica, mas por tool call** - Salvar fatos duradouros de forma automatica usando `MemoryTool` com sucesso verificavel; nao usar `[[SAVE:...]]`/regex como mecanismo de persistencia.
- [ ] **Second Brain visual** - Criar uma tela nativa opcional com grafo de pessoas, projetos, metas e memorias conectadas.
- [ ] **Perfil e personificacao do JARVIS** - Organizar nome, forma de tratamento, personalidade, wake word, voz e tema em um perfil consistente.
- [ ] **Entrada de texto como alternativa a voz** - Adicionar um campo de texto para testes, acessibilidade e uso quando o microfone nao for conveniente.
- [ ] **Claude/Anthropic como backend opcional** - Avaliar futuramente como backend adicional de texto/tool calling, sem substituir o Gemini Live no fluxo de audio realtime.

Fonte analisada em 2026-09-01: PDF `PROMPT JARVIS.pdf`.

O material e uma especificacao/prompt para gerar um Jarvis web em arquivo unico, nao um repositorio de codigo pronto. Portanto, o que vale aproveitar sao principalmente conceitos de produto, memoria e UX; a implementacao HTML/Web Speech/localStorage nao deve ser portada literalmente para o app iOS.

### P1 - Second Brain estruturado e memoria viva

- [ ] Evoluir `AppSettings.memories: [String:String]` para um modelo estruturado `MemoryNote`.
- [ ] Campos minimos por memoria: `id`, `area`, `title`, `body`, `createdAt`, `updatedAt`.
- [ ] Adicionar `source`/proveniencia da memoria (voz, edicao manual, pessoa/rosto, importacao).
- [ ] Adicionar nivel de confianca/confirmacao para fatos inferidos automaticamente.
- [ ] Categorias inspiradas no documento: metas, trabalho, projetos, financas, aprendizado, saude, relacoes e meta/perfil.
- [ ] Tratar saude e financas como categorias sensiveis: opt-in, armazenamento local e controle explicito de envio a backends cloud.
- [ ] Criar `MemoryRelation` para ligar notas relacionadas em vez de uma lista plana.
- [ ] Tipos de relacao: pessoa-projeto, projeto-meta, pessoa-relacao, preferencia-contexto, entre outras.
- [ ] Criar um `CoreProfile` do usuario para fatos estaveis que devem estar sempre disponiveis.
- [ ] Migrar as memorias simples da Build 39 para o novo store sem perder dados existentes.
- [ ] Auto-save de fatos duradouros, mas via `MemoryTool`/tool call confirmada - nao por texto magico `[[SAVE:...]]`.
- [ ] Atualizar memoria existente quando o fato for claramente o mesmo, evitando duplicatas.
- [ ] Criar busca/retrieval de memorias relevantes para cada comando.
- [ ] Injetar sempre o CoreProfile e somente as memorias relevantes ao turno, em vez de mandar o Second Brain inteiro em toda chamada.
- [ ] Criar UI de gerenciamento de memoria: listar, buscar, editar, excluir e adicionar nota manualmente.
- [ ] Mostrar origem e ultima atualizacao de cada memoria na UI.
- [ ] Criar testes de persistencia, update, deduplicacao, busca e exclusao.
- [ ] Permitir export/import do Second Brain futuramente.

### P1 - Integrar Second Brain com identidade de pessoas

- [ ] Criar `PersonProfileStore` com UUID por pessoa, sem usar o nome como chave primaria.
- [ ] Ligar face embeddings ao `personId`.
- [ ] Ligar speaker embedding/voice profile ao mesmo `personId` quando aplicavel.
- [ ] Ligar notas, relacoes, aliases e fatos ao `personId`.
- [ ] Permitir perguntas como "quem e esta pessoa?" + "o que eu lembro sobre ela?" sem confundir reconhecimento biometrico com memoria semantica.
- [ ] Registrar `lastSeen`/ultima interacao como metadado opcional.
- [ ] Adicionar aliases sem perder a identidade persistente da pessoa.
- [ ] Futuramente mostrar pessoas como hubs do grafo do Second Brain.

### P2 - Second Brain visual

- [ ] Criar uma tela/tab nativa "Second Brain" para inspecao das memorias.
- [ ] Grafo com um no central e um no por memoria/pessoa/projeto/meta.
- [ ] Cor por categoria.
- [ ] Tamanho do no baseado em quantidade/forca de conexoes.
- [ ] Arestas para `MemoryRelation`.
- [ ] Clique/toque em no abre editor.
- [ ] Botao para nova nota e contador de notas/areas.
- [ ] Animacoes devem ser leves e pausadas quando a tela nao estiver visivel para nao gastar bateria.
- [ ] O grafo e ferramenta de visualizacao/administracao; nao deve ser requisito para o funcionamento pelos oculos.

### P2 - Perfil e personalizacao

- [ ] Consolidar configuracoes de identidade do assistente: nome, forma de tratamento, personalidade, wake word, voz e cor/tema.
- [ ] Criar onboarding opcional para perfil basico do usuario, sem obrigar uma entrevista longa.
- [ ] Permitir que o JARVIS aprenda o perfil gradualmente por voz usando o MemoryTool.
- [ ] Usar as areas "voce/metas/carreira/projetos/aprendizado/relacoes" como sugestoes de organizacao, nao como campos obrigatorios.
- [ ] Manter respostas curtas e orientadas a fala como regra de UX configuravel.
- [ ] Adicionar entrada de texto como fallback/teste/acessibilidade na tela principal, alem da voz.

### P3 - Backend Anthropic/Claude opcional

- [ ] Avaliar um backend `AnthropicService` adicional, independente do Gemini Live.
- [ ] Reutilizar nosso STT/TTS nativo; nao usar Web Speech API.
- [ ] Reutilizar Native Tools/MemoryTool com adaptador de tool calling da Anthropic.
- [ ] Reutilizar historico de sessao e retrieval do Second Brain.
- [ ] Guardar API key no armazenamento seguro do iOS (preferencialmente Keychain), nunca em `localStorage`.
- [ ] Nao copiar o header browser-only `anthropic-dangerous-direct-browser-access`; ele existe para o prototipo web do documento e nao e arquitetura para iOS.
- [ ] Verificar o model ID e a API oficial atual no momento da implementacao, sem hard-code baseado no PDF.
- [ ] Considerar proxy proprio se quisermos reduzir a exposicao de chave/API no cliente.
- [ ] Tratar Claude como backend de texto/tool calling; o documento nao oferece um equivalente comprovado ao streaming de audio bidirecional do Gemini Live.

### P3 - UX aproveitavel

- [ ] Avaliar saudacao curta "Sistemas online" ao iniciar uma sessao, sem adicionar atraso artificial.
- [ ] Manter/expandir estados visuais idle, listening, thinking e speaking no orbe atual.
- [ ] Garantir botao de interrupcao/cancelamento visivel.
- [ ] Falar erros importantes quando a interacao estiver em modo voz.
- [ ] Mostrar status claro de microfone/permissao/erro.
- [ ] A tela de boot cinematografica pode ser opcional; nao deve atrasar todo launch em ~2,2 s.

### Nao portar literalmente do projeto web

- [x] Nao transformar o app nativo em um HTML unico.
- [x] Nao usar Web Speech API no lugar de Speech/AVAudioEngine do iOS.
- [x] Nao usar `localStorage` para API keys.
- [x] Nao enviar o Second Brain inteiro em toda chamada quando ele crescer; usar retrieval.
- [x] Nao usar `[[SAVE:...]]` como protocolo de execucao de memoria; manter tool call com sucesso verificavel.
- [x] Nao depender de parsing regex de texto do modelo para acoes persistentes.
- [x] Nao copiar headers CORS/browser-only para o cliente iOS.
- [x] Nao forcar um clique de "ATIVAR SISTEMA" em todo launch apenas por limitacao de autoplay do navegador.
- [x] Nao reproduzir animacoes pesadas do grafo fora da tela de gerenciamento.

## Arquitetura alvo do Second Brain

```text
JARVIS
├── CoreProfile
│   ├── identidade/preferencias do usuario
│   └── preferencias do assistente
├── MemoryStore
│   ├── MemoryNote
│   ├── MemoryRelation
│   └── Retriever
├── PersonProfileStore
│   ├── personId UUID
│   ├── aliases
│   ├── face embeddings
│   ├── speaker embedding
│   ├── facts/notes
│   └── relations
└── Prompt Context Builder
    ├── CoreProfile sempre
    ├── memorias relevantes
    ├── pessoa reconhecida quando houver
    └── contexto visual relevante
```

## Ordem recomendada atualizada

1. Validar completamente a Build 39 no iPhone.
2. Continuous Live Vision + FrameChange + memoria visual.
3. Second Brain estruturado + migracao das memorias simples.
4. PersonProfileStore unificando rosto, voz e fatos.
5. Scene-gated history e protecoes contra contexto visual obsoleto.
6. Kokoro streaming + FIFO + interrupcao segura.
7. Prompt concise + ChatSession/KV prefix cache.
8. UI nativa do Second Brain.
9. Revisao seletiva de barge-in/wake word/stop.
10. Telemetria completa.
11. Backend Anthropic/Claude opcional.

