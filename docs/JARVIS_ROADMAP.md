# Projeto JARVIS — Roadmap Oficial

> Documento vivo do projeto. Atualizar conforme cada objetivo avança.
>
> Legenda: ✅ Concluído · 🟡 Em andamento · ⏭️ Próximo · ⬜ Backlog · ⛔ Bloqueado

## Estado atual

**Baseline estável:** JARVIS 2.10.0 (37)

### ✅ Concluído
- [x] Wake word **"Ok Jarvis"**.
- [x] Reconhecimento de fala em pt-BR.
- [x] Integração com **Gemini Live**.
- [x] Resposta de áudio em streaming.
- [x] Conversa persistente com Gemini Live.
- [x] Barge-in / interrupção enquanto o JARVIS fala.
- [x] Reprodução de áudio do Gemini no modo de voz normal.
- [x] Ferramentas nativas do iPhone para funções já integradas.
- [x] Busca web com rastreabilidade básica das fontes.
- [x] Diagnostics persistente no aplicativo.
- [x] Diagnostics melhorado: copiar somente última falha ou sessão atual.
- [x] Correção de compatibilidade dos schemas de tools do Gemini.
- [x] Build 37 validada no aparelho.

## Fase 1 — Comunicação e uso real

### 🟡 1. Estabilizar OpenClaw e comandos diretos no PC
**Objetivo:** comandos simples destinados ao computador não devem depender desnecessariamente do LLM.

Problema conhecido:
- [ ] Corrigir o caso **"No meu computador abra o YouTube"**.
- [ ] Garantir que ações diretas sejam tentadas antes do agente.
- [ ] Não cair silenciosamente no LLM quando a ação direta deveria funcionar.
- [ ] Exibir erro claro quando o PC/agent estiver indisponível.
- [ ] Registrar nos Diagnostics se o caminho usado foi **direto** ou **agente**.

**Critério de aceite:** abrir YouTube e outras ações simples no PC funciona mesmo se o provedor LLM estiver com quota/rate limit.

### ⏭️ 2. Uniformizar Gemini Live e OpenClaw
**Objetivo:** os dois backends devem parecer o mesmo JARVIS.

- [ ] Mesma voz.
- [ ] Streaming de resposta sempre que possível.
- [ ] Barge-in consistente.
- [ ] Conversa contínua.
- [ ] Estados de UI coerentes: listening / processing / speaking.
- [ ] Tratamento consistente de erros e reconexão.
- [ ] Reduzir diferenças perceptíveis de latência entre os backends.

### ⏭️ 3. Validar Ray-Ban Meta ponta a ponta
**Objetivo:** tornar os óculos a interface principal do JARVIS.

Fluxo alvo:

```
Ray-Ban Meta
    ↓
iPhone / JARVIS
    ↓
IA
    ↓
áudio de resposta
    ↓
Ray-Ban Meta
```

Testes:
- [ ] Microfone dos óculos como entrada.
- [ ] Wake word pelos óculos.
- [ ] Resposta reproduzida nos alto-falantes dos óculos.
- [ ] Captura de câmera quando solicitada.
- [ ] Perguntas contextuais sobre o que o usuário está vendo.
- [ ] Reconexão dos óculos sem precisar reiniciar o app em condições normais.
- [ ] Alternância segura entre áudio do iPhone e áudio dos óculos.

**Critério de aceite:**  
"Ok Jarvis, você está me ouvindo?" e "O que estou vendo?" funcionam usando os óculos do início ao fim.

---

## Fase 2 — Integração e controle do iPhone

### 🟡 Base já existente
- [x] Status básico do dispositivo.
- [x] Calendário.
- [x] Lembretes.
- [x] Clipboard.
- [x] Timers / Pomodoro.
- [x] Ferramentas nativas expostas ao backend.

### ⬜ Próximos objetivos
- [ ] Mapear o que o iOS permite ler/controlar por API pública.
- [ ] Avaliar App Intents / Shortcuts.
- [ ] Notificações: definir o que é tecnicamente e legalmente acessível pelo app.
- [ ] Wi-Fi.
- [ ] Bluetooth.
- [ ] Modo avião.
- [ ] Volume.
- [ ] Outras configurações do sistema.
- [ ] Criar fallback por Atalhos quando a API pública não permitir ação direta.
- [ ] Documentar claramente: **direto / via Shortcut / não permitido pelo iOS**.

**Regra:** o JARVIS nunca deve fingir que executou uma ação que o iOS bloqueou.

---

## Fase 3 — Reconhecimento avançado

### 🟡 Reconhecimento facial — implementação Build 38
- [x] Base de reconhecimento local herdada do OpenVision (Apple Vision feature print).
- [x] Câmera traseira do iPhone como fallback quando os Ray-Ban não estiverem disponíveis.
- [x] Tool nativa de reconhecimento para Gemini Live/OpenAI.
- [ ] Validar cadastro explícito de pessoas conhecidas no aparelho.
- [ ] Validar matching e calibrar threshold com testes reais.
- [ ] Threshold para evitar falsos positivos.
- [ ] Estado **"não reconheço"** quando confiança for insuficiente.
- [ ] Remover/recriar cadastro.
- [ ] Definir política de privacidade para dados biométricos.

### ⬜ Reconhecimento de voz / locutor
- [ ] Estudar speaker verification local vs API.
- [ ] Cadastro de voz.
- [ ] Diferenciar **identificação** de **autenticação**.
- [ ] Medir falso aceite e falsa rejeição.
- [ ] Definir política de segurança para ações sensíveis.
- [ ] Não usar somente voz como autorização para ações de alto risco sem fator adicional.

---

## Backlog futuro

- [ ] Memória persistente maior e estruturada.
- [ ] Contexto de pessoas conhecidas.
- [ ] Mais automações do computador.
- [ ] Integrações adicionais via ferramentas/MCP quando fizer sentido.
- [ ] Melhor roteamento automático entre backends.
- [ ] Melhor recuperação de sessão e tolerância a falhas.
- [ ] Modo offline/fallback local mais completo.
- [ ] Avaliar novos frameworks somente quando resolverem uma limitação concreta.

### Decisões atuais
- **OpenJarvis:** analisado, mas não será integrado por enquanto.
- **OpenClaw:** permanece como backend operacional para computador/agentes.
- **Gemini Live:** permanece como backend principal de voz/visão em tempo real.
- **Build 37:** baseline atual a preservar.

---

## Ordem de execução atual

1. **Validar reconhecimento facial + câmera do iPhone (Build 38).**
2. **Retomar estabilização do OpenClaw e comandos diretos no PC.**
3. **Uniformizar experiência Gemini Live / OpenClaw.**
4. **Validar Ray-Ban Meta ponta a ponta.**
5. **Expandir Fase 2 no iPhone.**
6. **Iniciar reconhecimento de voz.**

---

## Regra de manutenção deste roadmap

Ao concluir uma etapa:
1. marcar o item como `[x]`;
2. registrar a build/commit que implementou;
3. só considerar concluído depois do teste no aparelho quando aplicável;
4. mover o próximo objetivo para **Em andamento**.

Última atualização inicial: 2026-09-01.
