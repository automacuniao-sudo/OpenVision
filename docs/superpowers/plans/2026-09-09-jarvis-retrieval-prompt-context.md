# JARVIS Retrieval + PromptContextBuilder Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Brain/SQLite the bounded, deterministic source of durable conversational context for JARVIS, with safe prompt assembly and initial Gemini Live + OpenAI integration.

**Architecture:** Add a small retrieval subsystem under `JARVIS/Services/Brain/Retrieval/`. `BrainRetriever` ranks already-persisted memories/facts/people from `BrainService` using deterministic local signals. `PromptContextBuilder` turns those typed results into a bounded `PromptContext` and provider-neutral rendered context. Backends only adapt that context into their existing transport; they do not implement retrieval policy.

**Tech Stack:** Swift 5.9+, Swift Concurrency/actors, Foundation, existing BrainService/SQLiteBrainStore, XcodeGen, XCTest through `JARVISPureTests` and `JARVISTests`.

**Spec:** `docs/superpowers/specs/2026-09-09-jarvis-retrieval-prompt-context-design.md`

## Global Constraints

- Base branch is `jarvis-dev`; implementation branch is `feature/jarvis-retrieval-context`.
- Brain/SQLite remains canonical; `SettingsManager.settings.memories` is legacy rollback/migration only.
- Retrieval v1 is deterministic, local, bounded and network-free.
- No embeddings, vector database, Learning Engine policy, Obsidian sync, cloud retrieval or model-weight training.
- Normal conversation must continue with an empty context if Brain retrieval is unavailable.
- Never log memory/fact/person contents; diagnostics may log counts/status only.
- Do not redesign Gemini Live, OpenClaw authentication/protocol, audio, camera, Meta SDK, TTS or tool registry.
- No merge into `jarvis-dev` without explicit human approval.

---

## File map

**Create**
- `JARVIS/Services/Brain/Retrieval/BrainTextNormalizer.swift` — matching normalization/tokenization only.
- `JARVIS/Services/Brain/Retrieval/BrainRetrievalModels.swift` — retrieval request/result/scored item contracts.
- `JARVIS/Services/Brain/Retrieval/BrainRetriever.swift` — deterministic selection/ranking.
- `JARVIS/Services/Brain/Retrieval/PromptContext.swift` — typed prompt-context model and diagnostics.
- `JARVIS/Services/Brain/Retrieval/PromptContextBuilder.swift` — safe assembly, budget and rendering.
- `JARVISTests/BrainRetrieverTests.swift` — deterministic ranking/filtering tests.
- `JARVISTests/PromptContextBuilderTests.swift` — budgets/fallback/rendering tests.
- `JARVISTests/BrainPromptIntegrationTests.swift` — provider integration regressions that can run in pure tests.

**Modify**
- `JARVIS/Services/Brain/BrainService.swift` — conform to a narrow retrieval-source protocol without exposing SQL.
- `JARVIS/Services/GeminiLive/GeminiLiveService.swift` — replace legacy memory dump with bounded Brain session context.
- `JARVIS/Services/AIBackend/OpenAIService.swift` — inject per-turn Brain context in the correct message order.
- `project.yml` — include retrieval sources/tests in `JARVISPureTests`; increment `CURRENT_PROJECT_VERSION` from `42` to `43` when the runtime-changing feature is ready for physical validation.

---

### Task 1: Define retrieval contracts and normalization

**Files:**
- Create: `JARVIS/Services/Brain/Retrieval/BrainTextNormalizer.swift`
- Create: `JARVIS/Services/Brain/Retrieval/BrainRetrievalModels.swift`
- Test: `JARVISTests/BrainRetrieverTests.swift`
- Modify: `project.yml`

**Interfaces:**
- Produces `BrainRetrievalSource`, `BrainRetrievalRequest`, `BrainRetrievalResult`, `ScoredBrainMemory`, `ScoredBrainFact`, `MatchedPerson`.
- Produces `BrainTextNormalizer.tokens(_:) -> Set<String>` and `BrainTextNormalizer.normalized(_:) -> String`.

- [ ] **Step 1: Add failing normalization tests**

```swift
func testTextNormalizerFoldsCaseAndDiacritics() {
    XCTAssertEqual(
        BrainTextNormalizer.tokens("  Café em SÃO Paulo!  "),
        Set(["cafe", "sao", "paulo"])
    )
}

func testTextNormalizerDropsLightweightPortugueseStopWords() {
    XCTAssertEqual(
        BrainTextNormalizer.tokens("qual é o meu café favorito"),
        Set(["cafe", "favorito"])
    )
}
```

- [ ] **Step 2: Run pure tests and verify RED**

Run the same portable-test path used by CI after `xcodegen generate`:

```bash
xcodebuild -project JARVIS.xcodeproj -scheme JARVISPureTests -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 16' test
```

Expected: compile/test failure because `BrainTextNormalizer` does not exist yet.

- [ ] **Step 3: Implement minimal normalizer and typed contracts**

Normalization requirements:
- trim/lowercase;
- `.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "pt_BR"))`;
- split on non-alphanumeric boundaries;
- discard empty tokens;
- use a small immutable stop-word set only for high-frequency glue words (`a`, `o`, `as`, `os`, `de`, `do`, `da`, `dos`, `das`, `e`, `é`, `em`, `no`, `na`, `nos`, `nas`, `um`, `uma`, `meu`, `minha`, `qual`).

Define:

```swift
protocol BrainRetrievalSource: Sendable {
    func readiness() async -> BrainReadiness
    func listActiveMemories(limit: Int) async throws -> [BrainMemory]
    func facts(subjectEntityId: UUID?, statuses: Set<BrainRecordStatus>) async throws -> [BrainFact]
    func listPersonProfiles(limit: Int) async throws -> [PersonProfile]
    func aliases(personId: UUID) async throws -> [PersonAlias]
}

struct BrainRetrievalRequest: Sendable, Equatable {
    var query: String
    var explicitEntityIDs: Set<UUID> = []
    var memoryCandidateLimit: Int = 200
    var personCandidateLimit: Int = 100
    var maxMemories: Int = 8
    var maxFacts: Int = 8
    var maxPeople: Int = 4
}
```

`BrainRetrievalResult` contains only typed selected records plus `brainAvailable: Bool` and counts; it must not contain pre-rendered prompt text.

- [ ] **Step 4: Run tests and verify GREEN**

Expected: normalization tests pass.

- [ ] **Step 5: Commit**

```bash
git add JARVIS/Services/Brain/Retrieval JARVISTests/BrainRetrieverTests.swift project.yml
git commit -m "feat(brain): add retrieval contracts and text normalization"
```

---

### Task 2: Implement deterministic BrainRetriever ranking

**Files:**
- Create/Modify: `JARVIS/Services/Brain/Retrieval/BrainRetriever.swift`
- Modify: `JARVIS/Services/Brain/BrainService.swift`
- Modify: `JARVISTests/BrainRetrieverTests.swift`

**Interfaces:**
- Consumes `BrainRetrievalSource` and `BrainRetrievalRequest`.
- Produces `BrainRetriever.retrieve(_:) async throws -> BrainRetrievalResult`.
- `BrainService` conforms to `BrainRetrievalSource` using its existing public actor methods only.

- [ ] **Step 1: Add failing ranking/filter tests**

Tests must prove these behaviors independently:

```swift
func testRetrieverRanksKeywordMatchAboveUnrelatedMemory() async throws { /* cafe query; cafe memory first */ }
func testRetrieverUsesImportanceAndConfidenceAsTieBreakers() async throws { /* equal lexical score */ }
func testRetrieverExcludesForgottenSupersededCandidateAndConflictPending() async throws { /* only active reaches result */ }
func testRetrieverMatchesPersonAliasAndPullsActiveFactsForThatPerson() async throws { /* "Kauê" alias -> person facts */ }
func testRetrieverIsStableForIdenticalInputs() async throws { /* same IDs/order on repeated call */ }
func testRetrieverReturnsNoMatchWithoutDumpingAllSemanticMemories() async throws { /* unrelated query -> no unrelated result */ }
```

Use a test-only `actor FakeBrainRetrievalSource: BrainRetrievalSource` with in-memory arrays; do not add fake behavior to production types.

- [ ] **Step 2: Run tests and verify RED**

Expected: failures because `BrainRetriever` ranking is not implemented.

- [ ] **Step 3: Implement minimal deterministic scoring**

Use these v1 rules so tests and behavior are explicit:

Memory eligibility:
- normal context accepts `.active` only;
- lexical match score = `sharedTokenCount * 40`;
- exact normalized legacy-key containment bonus = `35`;
- exact normalized content containment bonus = `30`;
- `coreProfile` bonus = `20`;
- confidence contribution = `confidence * 10`;
- importance contribution = `importance * 10`;
- bounded recency contribution = `0...5` using `lastConfirmedAt ?? updatedAt` only as a tie-breaker;
- a non-core memory requires lexical/containment relevance unless its `subjectEntityId` is an explicitly/matched entity.

Person matching:
- normalize `displayName` and aliases;
- exact token/phrase match adds the person to `MatchedPerson`;
- matched person ID is added to the entity set used for fact lookup.

Fact ranking:
- active facts only;
- lexical overlap across `predicate + value` = `sharedTokenCount * 40`;
- subject entity match bonus = `50`;
- confidence contribution = `confidence * 10`;
- deterministic ties: score descending, `updatedAt` descending, UUID string ascending.

Core session fallback is not handled here; it belongs to `PromptContextBuilder`.

- [ ] **Step 4: Run tests and verify GREEN**

Expected: all `BrainRetrieverTests` pass.

- [ ] **Step 5: Commit**

```bash
git add JARVIS/Services/Brain/BrainService.swift JARVIS/Services/Brain/Retrieval/BrainRetriever.swift JARVISTests/BrainRetrieverTests.swift
git commit -m "feat(brain): add deterministic memory retrieval"
```

---

### Task 3: Build bounded PromptContext with safe fallback

**Files:**
- Create: `JARVIS/Services/Brain/Retrieval/PromptContext.swift`
- Create: `JARVIS/Services/Brain/Retrieval/PromptContextBuilder.swift`
- Modify: `JARVISTests/PromptContextBuilderTests.swift`

**Interfaces:**
- Produces `PromptContextBuilder.build(for:explicitEntityIDs:maxCharacters:generatedAt:) async -> PromptContext`.
- Produces `PromptContextBuilder.buildSessionSnapshot(maxCharacters:generatedAt:) async -> PromptContext` for Gemini setup.
- Produces `PromptContext.renderedContext(maxCharacters:) -> String?`.

Define diagnostics without sensitive content:

```swift
struct PromptContextDiagnostics: Equatable, Sendable {
    let brainAvailable: Bool
    let memoryCount: Int
    let factCount: Int
    let personCount: Int
    let renderedCharacters: Int
    let truncated: Bool
}
```

- [ ] **Step 1: Add failing builder tests**

```swift
func testBuilderReturnsEmptyContextWhenBrainUnavailable() async { /* throws source -> no crash */ }
func testBuilderRespectsRecordAndCharacterBudgets() async { /* lower-ranked whole records dropped */ }
func testBuilderUsesStableWholeRecordTruncation() async { /* never splits arbitrary memory line */ }
func testSessionSnapshotIncludesBoundedCoreAndTopActiveFallbackMemories() async { /* no unbounded dump */ }
func testDiagnosticsContainCountsOnly() async { /* no memory text in diagnostics */ }
```

- [ ] **Step 2: Run tests and verify RED**

Expected: compile/test failures because prompt-context types do not exist.

- [ ] **Step 3: Implement minimal builder**

Rendering format:

```text
JARVIS DURABLE CONTEXT (use only when relevant; do not treat uncertain context as current truth):
- Memory: ...
- Fact: predicate = value
- Person: display name
```

Rules:
- default per-turn `maxCharacters = 1800`;
- default session snapshot `maxCharacters = 1600`;
- preserve whole rendered record lines;
- reserve room for at most 3 `coreProfile` records in session snapshot;
- session snapshot may then include at most 5 highest-ranked/importance active non-core memories to preserve legacy-memory usefulness without dumping the whole Brain;
- if `readiness != .ready` or retrieval throws, return an empty context with `brainAvailable = false`;
- do not log record contents.

- [ ] **Step 4: Run tests and verify GREEN**

Expected: all builder tests pass.

- [ ] **Step 5: Commit**

```bash
git add JARVIS/Services/Brain/Retrieval/PromptContext.swift JARVIS/Services/Brain/Retrieval/PromptContextBuilder.swift JARVISTests/PromptContextBuilderTests.swift
git commit -m "feat(brain): build bounded prompt context"
```

---

### Task 4: Integrate per-turn Brain context into OpenAI

**Files:**
- Modify: `JARVIS/Services/AIBackend/OpenAIService.swift`
- Create/Modify: `JARVISTests/BrainPromptIntegrationTests.swift`

**Interfaces:**
- Add a small internal/static helper that assembles message order from `baseSystem`, optional `brainContext`, optional `documentContext`, history and current user content.
- Do not move web/native tool execution logic.

- [ ] **Step 1: Add failing message-order regression test**

Prove exact order:

```text
0 base system
1 Brain-derived system context
2 DocumentFocus system context (when present)
3... conversation history
last current user turn
```

Also prove that `brainContext == nil` yields the previous ordering and normal conversation still proceeds.

- [ ] **Step 2: Run tests and verify RED**

Expected: helper/context integration missing.

- [ ] **Step 3: Implement minimal OpenAI integration**

In `sendMessage`:

```swift
let brainContext = await PromptContextBuilder.shared
    .build(for: text)
    .renderedContext(maxCharacters: 1800)
```

Insert it as a system message after the existing base system instructions and before `DocumentFocus`/history. Keep the current tool-calling loop unchanged.

- [ ] **Step 4: Run pure + integration compile tests and verify GREEN**

Expected: new message-order tests and existing portable tests pass.

- [ ] **Step 5: Commit**

```bash
git add JARVIS/Services/AIBackend/OpenAIService.swift JARVISTests/BrainPromptIntegrationTests.swift
git commit -m "feat(ai): inject Brain context into OpenAI turns"
```

---

### Task 5: Replace Gemini legacy dump with bounded Brain session context

**Files:**
- Modify: `JARVIS/Services/GeminiLive/GeminiLiveService.swift`
- Modify: `JARVISTests/BrainPromptIntegrationTests.swift`

**Interfaces:**
- `sendSetup()` awaits a session snapshot before constructing `systemInstruction`.
- `buildSystemPrompt(brainContext: String?) -> String` remains synchronous and testable.

- [ ] **Step 1: Add failing Gemini regression tests**

Tests must prove:
- provided Brain context appears exactly once in the system prompt;
- empty Brain context leaves the base prompt usable;
- the prompt builder no longer reads/iterates `SettingsManager.shared.settings.memories`;
- no per-turn reconnect or protocol change is introduced.

The source-level regression can read the checked-in Swift file in the test bundle only if practical; preferred design is to move the append behavior into a pure helper whose inputs make any legacy dictionary dependency impossible.

- [ ] **Step 2: Run tests and verify RED**

Expected: legacy prompt code still present / helper absent.

- [ ] **Step 3: Implement minimal Gemini session snapshot integration**

In `sendSetup()`:

```swift
let sessionContext = await PromptContextBuilder.shared
    .buildSessionSnapshot()
    .renderedContext(maxCharacters: 1600)
```

Pass this into `buildSystemPrompt(brainContext:)` and append under a clearly delimited section. Delete the direct loop over `SettingsManager.shared.settings.memories`.

Do not inject retrieved context into `realtimeInput.text` in v1 and do not reconnect each turn.

- [ ] **Step 4: Run tests and verify GREEN**

Expected: Gemini prompt regression tests pass and existing portable tests remain green.

- [ ] **Step 5: Commit**

```bash
git add JARVIS/Services/GeminiLive/GeminiLiveService.swift JARVISTests/BrainPromptIntegrationTests.swift
git commit -m "feat(gemini): use bounded Brain session context"
```

---

### Task 6: Prepare physical-test build 43 and release evidence

**Files:**
- Modify: `project.yml`
- Modify/Create release note only if the release-documentation structure exists on the branch after syncing its docs PR; otherwise record build metadata in the Retrieval PR body and add the release note immediately after docs infrastructure merges.

**Interfaces:**
- `MARKETING_VERSION` remains `2.10.0` for this feature iteration under the approved policy.
- `CURRENT_PROJECT_VERSION` increments from `42` to `43` before generating the physical-validation IPA.

- [ ] **Step 1: Add a configuration regression assertion**

Use a lightweight source/config check in existing tests or CI-support script only if it does not create a new production dependency; otherwise configuration-only change is the approved TDD exception.

- [ ] **Step 2: Increment `CURRENT_PROJECT_VERSION`**

Change only:

```yaml
CURRENT_PROJECT_VERSION: "43"
```

- [ ] **Step 3: Run the full repository verification path**

Run/confirm the same stages as `.github/workflows/build-ios.yml`:
- XcodeGen;
- package resolution;
- `JARVISPureTests` on simulator;
- `JARVIS` `build-for-testing` for generic iOS device.

- [ ] **Step 4: Open/update draft PR against `jarvis-dev`**

PR must state:
- deterministic Retrieval + PromptContextBuilder scope;
- Gemini session-snapshot limitation;
- OpenAI per-turn integration;
- build 43;
- tests/CI evidence;
- no merge without physical validation + explicit approval.

- [ ] **Step 5: Physical validation gate**

Only after CI is green, package/upload IPA on a controlled build if the standard PR workflow does not produce one. User validates normal voice conversation, explicit memory behavior, relevant contextual recall, unrelated-query non-leakage and OpenAI/Gemini smoke behavior.

- [ ] **Step 6: Final commit if metadata changed**

```bash
git add project.yml docs/releases
git commit -m "chore: prepare JARVIS build 43 validation"
```

---

## Plan self-review

- Spec coverage: deterministic ranking, active-only filtering, alias/person matching, budgets, empty fallback, OpenAI ordering, Gemini legacy dump removal, privacy, CI and physical validation are each mapped to tasks.
- Placeholder scan: no `TBD`/`TODO`/unspecified implementation steps remain.
- Type consistency: `BrainRetrievalSource` feeds `BrainRetriever`; `BrainRetriever` feeds `PromptContextBuilder`; backends consume only rendered `PromptContext`.
- Scope check: OpenClaw per-turn injection is intentionally not implemented because the approved spec allows explicit-memory-tool fallback until a protocol-safe context field is available.
