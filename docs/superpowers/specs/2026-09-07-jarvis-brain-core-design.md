# JARVIS Brain Core — Design

## Status

Approved architecture, formalized for implementation planning.

## Base and scope

- Product repository: `automacuniao-sudo/OpenVision`.
- Stable product base: `jarvis-dev`.
- This design covers only **JARVIS-BRAIN Phase 1 — Brain Core**.
- Later phases remain separate: Retrieval/PromptContextBuilder, Learning Engine behavior, Obsidian projection, memory-management UI expansion, remote sync/backup, and advanced semantic/vector retrieval.
- No blind merge into `jarvis-dev`; implementation must use an isolated task branch/worktree and PR.

## Current runtime memory that must be preserved

The app already has persistent memory, but it is intentionally simple:

- `AppSettings.memories` is a `[String: String]` dictionary.
- `SettingsManager` persists it inside `settings.json`.
- `MemoryTool` supports explicit `remember`, `get`, `search`, `list`, and `forget` operations against that dictionary.
- `MemoriesView` edits the same key/value dictionary.
- The current JARVIS starter profile seeds several stable memories on first run.

The Brain Core must **evolve this system without data loss**. Existing users must not lose saved memories when the structured Brain becomes canonical.

## Goal

Create a local-first, structured, auditable runtime memory foundation for JARVIS that:

1. works fully offline on the iPhone;
2. uses SQLite as the canonical structured store;
3. provides stable identities and relations instead of relying on memory-key strings;
4. represents confidence, provenance, lifecycle, corrections, and history explicitly;
5. preserves and imports the existing `settings.json` memories exactly once;
6. exposes a small service layer that future Retrieval, Learning Engine, Obsidian projection, face/voice identity, and sync layers can consume without knowing SQLite details;
7. keeps biometric payloads out of Markdown/export-oriented records;
8. does not yet implement automatic learning, semantic retrieval, Obsidian synchronization, or cloud sync.

## Architectural decision

The canonical runtime Brain is **not Obsidian and not `settings.json`**.

```text
JARVIS runtime
    |
    v
BrainService
    |
    v
BrainStore protocol
    |
    v
SQLiteBrainStore
    |
    +--> structured entities
    +--> facts / relations / memories
    +--> provenance / confidence / lifecycle
    +--> migration metadata

Future adapters
    +--> MemoryRetriever
    +--> LearningEngine
    +--> ObsidianProjection
    +--> SyncEngine
```

Obsidian will later be a human-facing projection/edit surface. SQLite remains canonical so JARVIS does not depend on the Obsidian application.

## Storage technology

Use the system SQLite database engine directly rather than introducing a new database framework dependency in Phase 1.

Requirements:

- standard SQLite file stored in the app's protected application data container;
- explicit schema migrations managed by JARVIS code;
- transactions for multi-row writes and migrations;
- foreign keys enabled;
- WAL journal mode where supported by the app runtime;
- all SQL isolated behind `SQLiteBrainStore`/database helpers;
- application code outside the Brain module must not execute SQL directly.

This keeps the persisted format portable and minimizes additional dependency risk.

## Brain module boundaries

Create a focused Brain subsystem under `JARVIS/Services/Brain/`.

Recommended responsibility split:

```text
JARVIS/Services/Brain/
├── Models/
│   ├── BrainEntity.swift
│   ├── PersonProfile.swift
│   ├── BrainMemory.swift
│   ├── BrainFact.swift
│   ├── BrainRelation.swift
│   ├── LearningEvent.swift
│   └── BrainProvenance.swift
├── Storage/
│   ├── BrainStore.swift
│   ├── BrainDatabase.swift
│   ├── BrainMigrations.swift
│   └── SQLiteBrainStore.swift
├── Migration/
│   └── LegacyMemoryImporter.swift
└── BrainService.swift
```

The exact file count may be adjusted during planning if a smaller split is clearer, but the responsibilities must remain separated: domain models, storage contract, SQLite implementation/migrations, legacy import, and high-level service.

## Identity model

### Stable primary identity

All durable entities use UUIDs as primary identifiers.

Names, aliases, face matches, speaker matches, labels, memory keys, and natural-language descriptions are **attributes/signals**, never primary identity.

This is required especially for people:

```text
PersonProfile.id = UUID
```

A future face or voice match resolves to this UUID rather than directly to a person's name.

### PersonProfile

Phase 1 `PersonProfile` must support at least:

- `id: UUID`
- `displayName: String?`
- `createdAt: Date`
- `updatedAt: Date`
- `firstSeenAt: Date?`
- `lastSeenAt: Date?`
- `status`
- `confidence`
- provenance references

Aliases are stored separately so one person can have many aliases without changing identity.

Biometric embeddings are not required to be generated or matched in Phase 1, but the schema must allow future opaque profile references to be associated with a PersonProfile without storing them in exported Markdown.

## Memory lifecycle

The runtime architecture recognizes three promotion states:

```text
transient -> candidate -> consolidated
```

Phase 1 persists the durable states needed by later phases. Transient conversational state can remain outside SQLite unless explicitly promoted.

Every durable memory has a lifecycle/status field. Minimum values:

- `candidate`
- `active`
- `superseded`
- `forgotten`
- `conflictPending`

A record marked `superseded` or `forgotten` is excluded from normal active-memory queries but can remain available for audit/history according to deletion policy.

## Memory classes

Brain Core must support these semantic categories in a single durable memory model or through clearly related models:

- `coreProfile`
- `semantic`
- `episodic`
- `preference`

`workingMemory` is intentionally not a durable Phase 1 database requirement. It belongs to conversation/session context and may be integrated later.

Each `BrainMemory` must include at least:

- `id: UUID`
- `kind`
- `content`
- `status`
- `confidence`
- `importance`
- `createdAt`
- `updatedAt`
- `lastConfirmedAt: Date?`
- `expiresAt: Date?`
- optional subject/entity reference
- provenance reference(s)

## Confidence and provenance

Confidence is always explicit and bounded to `0.0 ... 1.0`.

The Brain must record where durable information came from. Provenance must distinguish at least:

- `explicitUser`
- `legacyImport`
- `toolResult`
- `systemSeed`
- `inference`
- `manualEdit`

A source record should carry:

- source type;
- timestamp;
- optional source identifier/reference;
- optional note describing the evidence without storing hidden chain-of-thought.

The system must never convert weak inference into a high-confidence active fact merely because it was persisted.

## Facts

Facts are structured assertions associated with an entity or the user/core profile.

Minimum model:

- `id: UUID`
- `subjectEntityId: UUID?`
- `predicate: String`
- `value: String`
- `status`
- `confidence`
- `createdAt`
- `updatedAt`
- `lastConfirmedAt: Date?`
- provenance reference(s)
- optional `supersedesFactId`

Example:

```text
subject = person UUID
predicate = "works_in_department"
value = "Financeiro"
```

Corrections must create a new active fact and mark the old fact `superseded` rather than silently overwriting its history.

## Relations

Relations represent graph edges between entities.

Minimum model:

- `id: UUID`
- `sourceEntityId: UUID`
- `relationType: String`
- `targetEntityId: UUID`
- `status`
- `confidence`
- timestamps
- provenance reference(s)

Examples:

```text
Person A --works_with--> Person B
Person A --works_at--> Organization C
Person A --seen_in--> Place D
```

Phase 1 does not need graph ranking or semantic traversal, only correct durable representation and basic CRUD/query by entity.

## Generic entities

To avoid hard-coding every future concept into PersonProfile, the Brain needs a generic entity record.

Minimum entity types:

- `user`
- `person`
- `organization`
- `place`
- `thing`
- `concept`

`PersonProfile` augments a `person` entity rather than replacing the generic entity layer.

## LearningEvent foundation

Phase 1 stores learning/audit events but does **not** implement the automatic Learning Engine policy.

`LearningEvent` must support at least:

- `id: UUID`
- event type
- target record/entity ID when applicable
- source/provenance
- timestamp
- before-state summary when applicable
- after-state summary when applicable
- reversible flag

Initial event types to reserve/support:

- `explicitCorrection`
- `explicitPreference`
- `confirmation`
- `aliasAdded`
- `merge`
- `forget`
- `legacyImport`
- `manualEdit`

The later Learning Engine will decide when and how to create these automatically. Brain Core only supplies safe persistence and APIs.

## Person aliases

Aliases are first-class rows associated with PersonProfile/entity UUIDs.

Minimum fields:

- `id: UUID`
- `personId: UUID`
- `alias`
- `normalizedAlias`
- `confidence`
- provenance
- timestamps

Do not automatically merge two people merely because normalized aliases match.

## Biometric references

Phase 1 does not migrate or redesign current face/speaker recognition storage unless required for compilation.

However, Brain Core must provide a future-safe reference model:

- biometric kind: `face` or `speaker`;
- person UUID;
- opaque storage reference;
- created/updated timestamps;
- confidence/quality metadata if available.

Raw embeddings must not be exposed through Obsidian projection or generic memory export APIs.

## Legacy memory migration

This is a load-bearing requirement.

### Source

Existing memories live in:

```text
SettingsManager.settings.memories: [String: String]
```

persisted inside `settings.json`.

### Behavior

On first successful initialization of Brain Core:

1. open/create the SQLite database;
2. run schema migrations;
3. inspect migration metadata to determine whether legacy memory import has already completed;
4. if not completed, read all existing key/value memories;
5. import each legacy memory as a structured durable memory/fact using provenance `legacyImport` and high confidence because it was previously treated as explicit persistent state;
6. preserve the legacy key as metadata/alias so existing tool/UI semantics can be bridged;
7. commit the entire import in one transaction;
8. mark migration as completed only after the transaction succeeds;
9. never duplicate imported rows on later launches.

### Failure rule

If import fails, `settings.json` remains untouched and the migration-complete marker must not be written.

Phase 1 must not delete the old dictionary automatically. Legacy data remains available as rollback safety until a later explicitly approved cleanup phase.

## Compatibility bridge

The new Brain becomes canonical, but Phase 1 must avoid breaking existing runtime behavior.

`MemoryTool` must be adapted to use `BrainService` for its existing public actions:

- remember
- get
- search
- list
- forget

The tool may continue accepting legacy-style `key` and `value` arguments so prompts/backend tool schemas remain compatible.

`MemoriesView` may either:

- be minimally adapted to read/write the Brain service using a simple compatibility view model; or
- remain legacy-backed only if the implementation plan proves that no user-facing inconsistency is possible during Phase 1.

Preferred outcome: adapt it in Phase 1 so the UI and voice tool observe the same canonical store.

No richer memory-review UI is required yet.

## BrainService API

`BrainService` is the only high-level runtime entry point for Phase 1 consumers.

It should expose async operations with typed inputs/results, including at least:

- initialize/migrate Brain;
- create/update/read/list/delete-or-forget memory;
- create/read/list PersonProfile;
- add/list aliases;
- create/list facts by subject;
- supersede a fact;
- create/list relations by entity;
- append/list LearningEvents;
- import legacy memories exactly once.

The exact Swift signatures belong in the implementation plan, but callers must not depend on SQL or database connection objects.

## Concurrency

Brain writes must be serialized through the storage/service boundary.

Requirements:

- no concurrent unsynchronized SQLite writes from UI, tools, and future background jobs;
- transactional multi-step operations;
- reads safe while writes occur;
- Brain APIs usable from async code without forcing all database work onto `MainActor`;
- UI publication/handoffs to SwiftUI happen on MainActor only where needed.

## Database schema v1

Schema v1 must include tables equivalent to:

```text
brain_metadata
entities
person_profiles
person_aliases
memories
facts
relations
provenance
record_provenance
learning_events
biometric_refs
```

### brain_metadata

Stores schema and migration/import flags. Must include a durable marker for legacy-memory import completion.

### Foreign keys

Use foreign keys for entity/profile/relation references. Deleting active records should normally use lifecycle status rather than cascading destructive deletion when auditability would be lost.

## Forget and deletion semantics

Phase 1 distinguishes normal forgetting from physical database erasure.

`forget` should:

- remove the record from active retrieval/listing;
- set status `forgotten` or perform a controlled tombstone operation;
- append an auditable event that does **not** retain more deleted content than necessary.

A future privacy UI may expose hard-delete/secure purge. That is outside Phase 1 unless required by existing `MemoryTool` compatibility.

For the legacy `MemoryTool.forget` behavior, the implementation plan must preserve the user's expectation that the forgotten value no longer appears in active memory APIs immediately.

## Local security

Phase 1 is local-first and must use the app sandbox plus iOS file protection.

Requirements:

- database stored outside user-visible Documents when practical, preferably Application Support;
- create directories with appropriate file-protection attributes;
- do not log memory contents, facts, aliases, biometric references, prompts, or user secrets;
- diagnostics may log operation IDs/counts/status only;
- no Brain database upload, telemetry payload, GitHub persistence, or Obsidian sync in Phase 1;
- API keys remain outside the Brain.

Database-level encryption beyond iOS data protection can be added in a dedicated later security phase if the selected SQLite integration cannot provide it without adding substantial dependency/complexity. The architecture must not prevent it.

## Logging

Allowed diagnostic examples:

```text
Brain initialized schema=1
Legacy import completed count=6
Memory created id=<uuid>
Fact superseded old=<uuid> new=<uuid>
```

Disallowed:

```text
Memory created: "user home address is ..."
Person voice embedding: [...]
```

## Startup integration

The app must initialize the Brain deterministically before operations that depend on persistent memory are allowed.

Initialization must be idempotent:

```text
open DB -> migrate -> legacy import if needed -> ready
```

If Brain initialization fails:

- the app must not crash solely because Brain storage is unavailable;
- memory operations return a controlled unavailable/error result;
- other non-memory JARVIS functions remain usable where practical;
- diagnostic logs record the technical error without sensitive contents.

## Seed profile migration

Existing `seedJarvisProfileIfNeeded` starter memories are part of current user-visible state.

The Phase 1 migration imports whatever is actually present in `settings.memories`; it must not recreate duplicate starter memories in SQLite every launch.

Longer term, new starter-profile seeding should move to Brain initialization, but that refactor is optional in Phase 1 if keeping the existing one-time seed avoids unnecessary scope.

## Search in Phase 1

Phase 1 requires only deterministic local search suitable for compatibility and tests:

- exact legacy-key lookup;
- case-insensitive text search over active memory content/legacy key;
- list active memories;
- queries by entity/person/fact/relation identifiers.

Do not add semantic embeddings or vector search yet.

FTS may be introduced only if implementation evidence shows it materially simplifies the compatibility search without expanding scope. It is not a requirement for schema v1.

## Future retrieval boundary

The schema must make future retrieval possible without changing canonical identifiers.

Future `MemoryRetriever` will score combinations of:

- semantic relevance;
- recency;
- confidence;
- importance;
- relationship strength.

Brain Core does not implement that scoring.

## Future Obsidian projection boundary

No Obsidian files are generated in Phase 1.

Future projection rules:

```text
SQLite canonical -> Markdown projection -> Obsidian
```

Human edits will later enter through a controlled PendingChange/LearningEvent path rather than directly mutating SQLite without validation.

The Brain Core schema must therefore expose stable UUIDs and provenance so exported Markdown can refer back to canonical records.

## Future sync boundary

No remote sync is implemented in Phase 1.

Records should nevertheless carry stable UUIDs and timestamps so a future event/sync layer can replicate changes without replacing the entire database file.

Do not introduce `deviceId`, remote version vectors, or server conflict logic until the dedicated Sync phase unless implementation proves they are required for local correctness.

## Integration with face and voice identity

No automatic identity wiring is required in Phase 1.

Future integration will map face/speaker recognition outputs to PersonProfile UUIDs. Existing face and Owner Voice Lock behavior must remain unchanged by Brain Core unless a later dedicated task explicitly integrates them.

## Error model

Brain APIs must return typed/recoverable errors instead of relying on `fatalError` or crashes.

Error categories should distinguish at least:

- database unavailable/open failure;
- migration failure;
- invalid input;
- not found;
- constraint/conflict;
- legacy import failure.

User-facing layers translate these into natural language; storage code does not embed UI copy.

## Tests

Phase 1 must have automated tests for the Brain subsystem independent of physical iPhone hardware wherever possible.

Minimum coverage:

1. schema creates successfully on a temporary database;
2. migrations are idempotent;
3. legacy key/value import imports all rows once and never duplicates them;
4. failed legacy import does not mark migration complete;
5. memory create/read/update/list/search works;
6. forgotten/superseded memory is excluded from active queries;
7. PersonProfile uses stable UUID identity independent of aliases;
8. duplicate aliases do not silently merge different PersonProfiles;
9. fact supersession leaves old fact historical and new fact active;
10. relation CRUD/query works with foreign keys;
11. provenance survives round-trip;
12. LearningEvent append/query works;
13. confidence bounds are validated;
14. multi-step correction/supersession operations are transactional;
15. existing legacy memory tool semantics remain compatible after the adapter is wired;
16. no runtime code outside the intended Brain/memory integration scope regresses in CI.

Physical iPhone testing is desirable for persistence/file-protection validation but Phase 1 must not require Ray-Ban hardware.

## CI and build expectations

- Existing portable/unit tests remain green.
- Add focused Brain tests to `JARVISTests` and/or `JARVISPureTests` according to dependency needs.
- Xcode project generation/build must succeed in CI.
- Do not bump the public app version/build merely for design documentation; implementation/release versioning follows the normal JARVIS release policy.

## Migration/rollback strategy

Phase 1 must be reversible during development:

- original `settings.json` memories are retained;
- SQLite import is additive and idempotent;
- no destructive cleanup of legacy storage;
- if the new Brain fails initialization, the app should remain operational outside memory features;
- a later migration-cleanup task may remove the legacy dictionary only after stable physical validation and explicit approval.

## Privacy boundaries

The Brain may eventually contain highly personal information. Phase 1 therefore establishes these invariants now:

- no Brain content in analytics/telemetry;
- no raw biometric vectors in Obsidian or generic exports;
- no Brain database committed to Git/GitHub;
- no hidden chain-of-thought persisted as provenance;
- no API credentials persisted as memory/facts;
- explicit user forget operations stop the content from participating in normal runtime recall immediately.

## Non-goals for Phase 1

Do not implement:

- automatic fact extraction from every conversation;
- autonomous preference inference;
- semantic/vector retrieval;
- PromptContextBuilder;
- full Learning Engine decision policy;
- automatic face-to-PersonProfile matching;
- automatic speaker-to-PersonProfile matching;
- PersonProfile merge heuristics;
- Obsidian projection/sync;
- remote/cloud sync;
- multi-device conflict resolution;
- server infrastructure;
- new memory review/undo UX beyond compatibility needs;
- model fine-tuning, weight updates, prompt self-modification, or code self-modification.

## Acceptance criteria

Brain Core Phase 1 is ready for review when all of the following are true:

- a structured SQLite Brain initializes locally and survives app restarts;
- schema v1 and migration framework exist;
- legacy `settings.memories` are imported once without loss or duplicates;
- the existing memory voice tool operates against the canonical Brain while retaining its external schema/behavior;
- the user-facing memories screen reads/writes the same canonical store, or an explicitly reviewed compatibility design proves equivalent behavior;
- UUID-backed entities and PersonProfiles exist;
- aliases, memories, facts, relations, provenance, learning events, and biometric references have durable representations;
- fact supersession and memory forgetting are auditable and exclude old/forgotten state from active queries;
- confidence/provenance/status are explicit;
- no semantic retrieval, cloud sync, or Obsidian dependency is introduced;
- existing face, voice, audio, Gemini, Meta DAT, and other runtime features remain behaviorally unchanged;
- automated Brain tests and existing relevant CI are green;
- no merge to `jarvis-dev` occurs without explicit human approval.

## Implementation sequencing after spec approval

After this written spec is approved, create a detailed Superpowers implementation plan. The plan should favor several reviewable tasks rather than one large patch, likely in this order:

1. domain models + validation;
2. SQLite database/migrations;
3. repositories/store/service;
4. legacy import;
5. MemoryTool compatibility adapter;
6. MemoriesView compatibility integration;
7. focused tests and startup wiring;
8. final review, CI, and physical persistence smoke test when available.

This ordering is guidance for planning, not permission to implement before the plan is reviewed.