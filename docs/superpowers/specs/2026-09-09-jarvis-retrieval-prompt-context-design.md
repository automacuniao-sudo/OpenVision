# JARVIS Retrieval + PromptContextBuilder — Design

## Status

Approved architecture, formalized for implementation planning.

## Base and scope

- Product repository: `automacuniao-sudo/OpenVision`.
- Stable product base: `jarvis-dev` at merge commit `20f71cccf0eb6428b9e2a46355f2507a6ee6c698`.
- Brain Core is already merged and validated by CI Build #177.
- This phase implements deterministic retrieval and prompt-context assembly only.
- Learning Engine policy, embeddings/vector search, Obsidian projection/sync, cloud sync and autonomous memory creation remain out of scope.
- No merge into `jarvis-dev` without explicit human approval.

## Problem to solve

Brain Core made SQLite the canonical runtime memory store, but conversational backends still consume context inconsistently.

Current examples:

- Gemini Live still appends every legacy `SettingsManager.settings.memories` entry directly into its system prompt.
- OpenAI builds its own system prompt and conversation context separately.
- OpenClaw sends user turns through its gateway with a different protocol shape.

This creates three problems:

1. the canonical Brain is not yet the source of contextual memory for normal conversation;
2. each backend can drift into different memory behavior;
3. sending all memories on every turn wastes context and can surface irrelevant information.

## Goal

Create a backend-agnostic retrieval and context layer that:

1. selects only relevant Brain records for a user turn;
2. produces a compact, deterministic, auditable context object;
3. lets each backend adapt that context into its own transport/prompt format without duplicating retrieval logic;
4. degrades safely when Brain retrieval is unavailable;
5. preserves existing voice, tool, web-search and conversation behavior;
6. prepares a clean boundary for the later Learning Engine and semantic/vector retrieval.

## Architectural decision

The shared flow becomes:

```text
User turn
   |
   v
PromptContextBuilder
   |
   v
BrainRetriever
   |
   v
BrainService / SQLite
   |
   v
PromptContext
   |
   +--> Gemini Live adapter
   +--> OpenAI adapter
   +--> OpenClaw adapter
   +--> Apple/local adapters later
```

Retrieval must not live inside individual AI backends.

The Brain remains canonical. `SettingsManager.settings.memories` remains only a legacy rollback/migration surface and must stop being injected directly into new conversational prompts once the new builder is active.

## Components

### BrainRetriever

A focused Brain component responsible only for selecting and ranking already-persisted information.

Input should include at least:

- current user text;
- optional identified person/entity IDs when available;
- requested result limit / budget.

Output should be typed retrieval results, not preformatted prompt strings.

The first version is deterministic and local. No embeddings, vector database or network calls.

### PromptContextBuilder

A backend-neutral assembler that combines:

- relevant Brain memories;
- relevant Brain facts;
- relevant person/entity context when available;
- minimal metadata needed for provenance/debugging without exposing sensitive content in logs.

It returns a typed `PromptContext` model.

### Backend adapters

Each backend may format `PromptContext` differently, but it must not implement its own ranking/query policy.

Examples:

- Gemini Live: convert the initial/session context into an additional system-instruction section.
- OpenAI: add a system-context message before conversation history.
- OpenClaw: use a safe context envelope/prefix compatible with its chat protocol; do not change OpenClaw authentication or tool transport.

The initial production integration should cover Gemini Live and OpenAI first. OpenClaw support may be added in the same phase only through the shared `PromptContext` contract and a minimal transport adapter, without redesigning the gateway protocol.

## Retrieval v1 policy

Retrieval v1 should combine deterministic signals already present in Brain Core.

Signals:

- textual overlap between user query and memory content / legacy key;
- textual overlap with fact predicate/value;
- alias/display-name match for known people/entities;
- explicit subject/entity match when an entity ID is already known;
- active status only;
- confidence;
- importance;
- recency / last confirmation as a bounded tie-breaker.

A simple weighted score is acceptable. The exact constants belong in implementation and tests, but ranking must be deterministic for identical inputs.

### Required guardrails

- never retrieve `forgotten` or `superseded` records for normal context;
- do not promote `candidate` or `conflictPending` records into authoritative context by default;
- do not expose biometric references or raw biometric payloads;
- do not include provenance notes that may contain sensitive source detail unless explicitly needed later;
- cap the number/size of selected records;
- stable ordering for equal scores;
- zero network dependency.

## Query normalization

Retrieval should normalize text for matching in a locale-tolerant way:

- trim whitespace;
- lowercase;
- fold diacritics for matching only;
- tokenize words;
- ignore empty tokens and lightweight stop words where useful.

The original stored text must never be rewritten by retrieval normalization.

## PromptContext model

The shared model should be structured rather than a single preformatted string.

Conceptual shape:

```text
PromptContext
  coreMemories[]
  relevantMemories[]
  relevantFacts[]
  relatedEntities[]
  generatedAt
  diagnosticsSummary
```

`diagnosticsSummary` must contain counts/status only, not memory contents.

The builder may expose a separate formatter for spoken-model prompts, but the typed model is the canonical boundary.

## Context budget

Retrieval must be bounded so the JARVIS does not blindly send the entire Brain to every model.

V1 requirements:

- explicit maximum record count;
- explicit maximum rendered character budget;
- core-profile information may receive a small reserved budget;
- lower-ranked records are dropped first;
- truncation must preserve whole record boundaries where practical;
- behavior must be deterministic and testable.

Token counting against provider-specific tokenizers is not required in v1; a character budget is sufficient.

## Core-profile behavior

Stable `coreProfile` memories may be included with a small reserved budget because they define durable user context, but not as an unlimited dump.

If many core-profile records exist, they are still ranked/capped by importance/confidence and deterministic order.

## Failure behavior

Context retrieval is optional to conversational availability.

If Brain is not initialized or retrieval fails:

```text
user turn -> empty PromptContext -> backend continues normally
```

Requirements:

- no app crash;
- no blocked conversation solely because Brain retrieval failed;
- diagnostic log records status/count/error category only;
- never log retrieved memory/fact text.

## Gemini Live integration

Gemini currently creates a session-level `systemInstruction` in `buildSystemPrompt()`.

V1 integration should remove direct iteration over legacy `SettingsManager.settings.memories` and use Brain-derived context instead.

Because Gemini Live system instructions are established during setup, the first implementation should support a session-context snapshot built from durable core context at connection time, plus a per-turn context path only if the current Gemini Live protocol integration can add it without breaking real-time semantics.

Do not reconnect every turn merely to refresh memory context.

If per-turn injection is not safe for Gemini Live v1, the accepted fallback is:

- session setup receives bounded core context;
- explicit memory search/tool remains available during the session;
- per-turn contextual retrieval is implemented for request/response backends first.

This limitation must be documented and tested rather than hidden.

## OpenAI integration

OpenAI request/response already assembles a `messages` array per turn, so it is the cleanest first consumer of per-turn `PromptContext`.

Order should be:

```text
base system instructions
Brain-derived contextual system message
DocumentFocus context when active
conversation history
current user turn
```

Brain context must not replace DocumentFocus or conversation history.

## OpenClaw integration

OpenClaw uses `chat.send` through Gateway protocol v4.

Do not redesign the protocol in this phase.

The adapter may prepend a compact context envelope to the user message only if doing so preserves user text, session behavior and tool routing. Otherwise OpenClaw may remain on explicit memory tools until a dedicated protocol-safe context field is available.

The shared retriever/builder must not depend on OpenClaw.

## Conversation context

Retrieval does not replace `ConversationContext` working/session memory.

Boundary:

```text
ConversationContext = recent conversational continuity
Brain = durable memory/facts/entities
PromptContextBuilder = selects durable context for the current request
```

No recent-turn transcript is persisted into Brain automatically in this phase.

## Privacy and logging

Allowed diagnostics:

```text
Retrieval completed memories=3 facts=2 entities=1
PromptContext built chars=1480 truncated=false
Retrieval unavailable; continuing without Brain context
```

Disallowed diagnostics:

```text
Retrieved memory: "user home address is ..."
Retrieved fact value: "..."
```

## Testing requirements

Tests must cover at least:

- deterministic ranking for identical inputs;
- active records included, forgotten/superseded excluded;
- candidate/conflict records excluded by default;
- keyword and alias matching;
- importance/confidence tie-breaking;
- context count/character budgets;
- stable truncation;
- empty/no-match result;
- Brain unavailable fallback;
- no direct dependency on `SettingsManager.settings.memories` in new retrieval logic;
- OpenAI ordering of Brain context relative to other system/document/history messages;
- Gemini removal of the legacy direct-memory dump;
- regression that normal conversation still proceeds when context is empty.

## Non-goals

Do not implement in this phase:

- automatic learning from conversation;
- memory conflict resolution policy;
- embeddings;
- vector database/search;
- semantic rerankers requiring an LLM;
- cloud retrieval;
- Obsidian projection/sync;
- memory decay/reinforcement;
- model-weight training;
- unrelated audio, camera, Meta SDK, TTS or tool-registry refactors.

## Future boundary

Learning Engine v1 will later write candidate/active knowledge through BrainService. Retrieval will consume that knowledge without needing to know how it was learned.

A future Retrieval v2 may add semantic/vector similarity behind the same `BrainRetriever` interface so backend consumers and `PromptContextBuilder` do not need to change.

## Acceptance criteria

This phase is complete when:

1. a typed `BrainRetriever` and `PromptContextBuilder` exist with deterministic bounded behavior;
2. Brain/SQLite is the source of durable prompt context;
3. Gemini no longer directly dumps the legacy settings memory dictionary into its prompt;
4. OpenAI receives relevant per-turn Brain context without breaking DocumentFocus/tools/history;
5. unavailable Brain degrades to normal conversation;
6. privacy-safe diagnostics are preserved;
7. tests and CI are green;
8. physical iPhone validation is performed before merge if the resulting build changes runtime conversational behavior;
9. no merge occurs without explicit human approval.
