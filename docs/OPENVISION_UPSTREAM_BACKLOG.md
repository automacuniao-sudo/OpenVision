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

## Projeto externo inspirado em JARVIS

Pendente de analise. O Google Docs fornecido em 2026-09-01 nao ficou acessivel pelos conectores/fetch desta sessao. Quando o conteudo estiver disponivel como arquivo/PDF/texto ou por um link publicamente exportavel, adicionar uma secao com:

- recurso/ideia;
- arquitetura;
- dependencias;
- viabilidade no iOS/Ray-Ban Meta;
- o que podemos reaproveitar;
- prioridade;
- riscos e conflitos com o JARVIS atual.
