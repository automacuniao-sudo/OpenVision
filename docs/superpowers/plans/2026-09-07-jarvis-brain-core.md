# JARVIS Brain Core Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build Phase 1 of the JARVIS runtime Second Brain as a local-first SQLite-backed, structured, auditable memory core that preserves all existing `settings.json` memories and keeps the current voice/UI memory behavior compatible.

**Architecture:** Add a focused `JARVIS/Services/Brain/` subsystem. `BrainService` is the runtime façade, `BrainStore` is the storage contract, and `SQLiteBrainStore` serializes all database access behind an actor using the system SQLite library. Existing key/value memories are imported exactly once and remain in `settings.json` as rollback safety; `MemoryTool` and `MemoriesView` switch to the new Brain as their canonical store.

**Tech Stack:** Swift 5.9, iOS 18+, Foundation, Swift Concurrency actors, system SQLite3 (`libsqlite3.tbd`), XCTest, XcodeGen, GitHub Actions.

**Spec:** `docs/superpowers/specs/2026-09-07-jarvis-brain-core-design.md`

## Global Constraints

- Stable product base is `jarvis-dev`; implementation work must be isolated in a task branch/worktree derived from the current `jarvis-dev` head.
- Do not merge into `jarvis-dev` or `main` without explicit human approval.
- SQLite is canonical for the runtime Brain; Obsidian and `settings.json` are not canonical stores.
- Phase 1 must work fully offline.
- Phase 1 must not add semantic/vector retrieval, automatic Learning Engine policy, Obsidian projection/sync, cloud sync, remote backup, or automatic face/voice identity merging.
- Existing `AppSettings.memories: [String: String]` content must be imported exactly once with no data loss and must remain untouched as rollback safety.
- No Brain database contents, memory text, facts, aliases, biometric references, prompts, tool arguments, API keys, or secrets may be emitted to telemetry or diagnostic logs.
- UUID is the primary durable identity for entities and people; names, aliases, legacy keys, face matches, and speaker matches are attributes/signals only.
- Confidence and importance values are constrained to `0.0 ... 1.0`.
- Durable memory lifecycle states are `candidate`, `active`, `superseded`, `forgotten`, and `conflictPending`.
- Durable memory kinds are `coreProfile`, `semantic`, `episodic`, and `preference`; working memory remains outside the Phase 1 database.
- Use the system SQLite engine directly; do not add a third-party database framework.
- Store the production database under Application Support with iOS file protection, not in user-visible Documents.
- Brain initialization is idempotent: open database → migrate schema → import legacy memories if needed → ready.
- Brain initialization failure must not crash the rest of the application.
- TDD is mandatory: each behavioral task starts with a failing XCTest, then minimal implementation, then passing tests.

---

## File Map

### New domain files

- `JARVIS/Services/Brain/Models/BrainTypes.swift` — shared enums, validation, legacy-key normalization, database-facing identifiers.
- `JARVIS/Services/Brain/Models/BrainEntity.swift` — generic entity model.
- `JARVIS/Services/Brain/Models/PersonProfile.swift` — person profile, alias, and biometric-reference models.
- `JARVIS/Services/Brain/Models/BrainMemory.swift` — durable memory model.
- `JARVIS/Services/Brain/Models/BrainFact.swift` — structured fact model.
- `JARVIS/Services/Brain/Models/BrainRelation.swift` — graph relation model.
- `JARVIS/Services/Brain/Models/BrainProvenance.swift` — provenance source/input/persisted provenance models.
- `JARVIS/Services/Brain/Models/LearningEvent.swift` — audit/learning-event model.

### New storage files

- `JARVIS/Services/Brain/Storage/BrainStore.swift` — async storage protocol consumed by `BrainService`.
- `JARVIS/Services/Brain/Storage/BrainDatabase.swift` — SQLite connection, prepared statements, transactions, Application Support path/file protection.
- `JARVIS/Services/Brain/Storage/BrainMigrations.swift` — schema v1 DDL and `user_version` migration runner.
- `JARVIS/Services/Brain/Storage/SQLiteBrainStore.swift` — actor implementing `BrainStore`.

### New service/migration files

- `JARVIS/Services/Brain/Migration/LegacyMemoryImporter.swift` — exactly-once import orchestration.
- `JARVIS/Services/Brain/BrainService.swift` — high-level runtime façade/readiness gate.

### Runtime adapters

- Modify `JARVIS/Services/NativeTools/MemoryTool.swift` — keep existing tool schema/actions but route operations through `BrainService`.
- Create `JARVIS/Views/Settings/MemoriesViewModel.swift` — MainActor adapter from SwiftUI to `BrainService`.
- Modify `JARVIS/Views/Settings/MemoriesView.swift` — display/edit/delete canonical Brain memories instead of `SettingsManager.settings.memories`.
- Modify `JARVIS/App/JARVISApp.swift` — initialize Brain on launch using a snapshot of the legacy dictionary.
- Modify `project.yml` — link system SQLite library.

### New tests

- `JARVISTests/BrainModelsTests.swift`
- `JARVISTests/BrainDatabaseTests.swift`
- `JARVISTests/SQLiteBrainStoreMemoryTests.swift`
- `JARVISTests/SQLiteBrainStoreGraphTests.swift`
- `JARVISTests/BrainServiceMigrationTests.swift`
- `JARVISTests/MemoryToolBrainTests.swift`
- `JARVISTests/MemoriesViewModelTests.swift`

---

### Task 1: Domain models, lifecycle, validation, and legacy-key normalization

**Files:**
- Create: `JARVIS/Services/Brain/Models/BrainTypes.swift`
- Create: `JARVIS/Services/Brain/Models/BrainEntity.swift`
- Create: `JARVIS/Services/Brain/Models/PersonProfile.swift`
- Create: `JARVIS/Services/Brain/Models/BrainMemory.swift`
- Create: `JARVIS/Services/Brain/Models/BrainFact.swift`
- Create: `JARVIS/Services/Brain/Models/BrainRelation.swift`
- Create: `JARVIS/Services/Brain/Models/BrainProvenance.swift`
- Create: `JARVIS/Services/Brain/Models/LearningEvent.swift`
- Test: `JARVISTests/BrainModelsTests.swift`

**Interfaces:**
- Consumes: Foundation `UUID`, `Date`, `Locale`.
- Produces:
  - `enum BrainRecordStatus: String, Codable, CaseIterable, Sendable`
  - `enum BrainMemoryKind: String, Codable, CaseIterable, Sendable`
  - `enum BrainEntityType: String, Codable, CaseIterable, Sendable`
  - `enum BrainProvenanceSource: String, Codable, CaseIterable, Sendable`
  - `enum LearningEventType: String, Codable, CaseIterable, Sendable`
  - `enum BiometricKind: String, Codable, CaseIterable, Sendable`
  - `enum BrainValidationError: Error, Equatable`
  - `enum BrainValidation { static func unitInterval(_ value: Double, field: String) throws -> Double }`
  - `enum BrainLegacyKey { static func normalize(_ raw: String) -> String; static func searchText(_ raw: String) -> String }`
  - `BrainEntity`, `PersonProfile`, `PersonAlias`, `BiometricReference`, `BrainMemory`, `BrainFact`, `BrainRelation`, `BrainProvenanceInput`, `BrainProvenance`, `LearningEvent`.

- [ ] **Step 1: Write failing model/validation tests**

Create `JARVISTests/BrainModelsTests.swift` with tests that lock the exact Phase 1 enum values, UUID identity, confidence validation, and legacy normalization:

```swift
import XCTest
@testable import JARVIS

final class BrainModelsTests: XCTestCase {
    func testLifecycleValuesAreStable() {
        XCTAssertEqual(BrainRecordStatus.allCases.map(\.rawValue), [
            "candidate", "active", "superseded", "forgotten", "conflict_pending"
        ])
        XCTAssertEqual(BrainMemoryKind.allCases.map(\.rawValue), [
            "core_profile", "semantic", "episodic", "preference"
        ])
    }

    func testConfidenceRejectsValuesOutsideUnitInterval() {
        XCTAssertNoThrow(try BrainValidation.unitInterval(0.0, field: "confidence"))
        XCTAssertNoThrow(try BrainValidation.unitInterval(1.0, field: "confidence"))
        XCTAssertThrowsError(try BrainValidation.unitInterval(-0.01, field: "confidence"))
        XCTAssertThrowsError(try BrainValidation.unitInterval(1.01, field: "confidence"))
    }

    func testLegacyKeyNormalizationMatchesExistingToolSemantics() {
        XCTAssertEqual(BrainLegacyKey.normalize(" João do Financeiro "), "joao_do_financeiro")
        XCTAssertEqual(BrainLegacyKey.normalize("USER-ROLE"), "user_role")
        XCTAssertEqual(BrainLegacyKey.normalize("___"), "")
    }

    func testSearchTextIsCaseAndDiacriticInsensitive() {
        XCTAssertEqual(BrainLegacyKey.searchText("Café São João"), "cafe sao joao")
    }

    func testPersonIdentityDoesNotDependOnDisplayName() {
        let id = UUID()
        let now = Date()
        let profile = PersonProfile(
            id: id,
            displayName: "João",
            createdAt: now,
            updatedAt: now,
            firstSeenAt: nil,
            lastSeenAt: nil,
            status: .active,
            confidence: 1.0
        )
        XCTAssertEqual(profile.id, id)
        XCTAssertEqual(profile.displayName, "João")
    }
}
```

- [ ] **Step 2: Run the new tests and verify RED**

Run:

```bash
xcodegen generate
xcodebuild test -project JARVIS.xcodeproj -scheme JARVIS -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:JARVISTests/BrainModelsTests -skipPackagePluginValidation -skipMacroValidation
```

Expected: compile/test failure because the Brain model types do not exist.

- [ ] **Step 3: Implement shared enums, validation, and normalization**

Create `BrainTypes.swift` with these exact raw values and behavior:

```swift
import Foundation

enum BrainRecordStatus: String, Codable, CaseIterable, Sendable {
    case candidate
    case active
    case superseded
    case forgotten
    case conflictPending = "conflict_pending"
}

enum BrainMemoryKind: String, Codable, CaseIterable, Sendable {
    case coreProfile = "core_profile"
    case semantic
    case episodic
    case preference
}

enum BrainEntityType: String, Codable, CaseIterable, Sendable {
    case user, person, organization, place, thing, concept
}

enum BrainProvenanceSource: String, Codable, CaseIterable, Sendable {
    case explicitUser = "explicit_user"
    case legacyImport = "legacy_import"
    case toolResult = "tool_result"
    case systemSeed = "system_seed"
    case inference
    case manualEdit = "manual_edit"
}

enum LearningEventType: String, Codable, CaseIterable, Sendable {
    case explicitCorrection = "explicit_correction"
    case explicitPreference = "explicit_preference"
    case confirmation
    case aliasAdded = "alias_added"
    case merge
    case forget
    case legacyImport = "legacy_import"
    case manualEdit = "manual_edit"
}

enum BiometricKind: String, Codable, CaseIterable, Sendable {
    case face, speaker
}

enum BrainValidationError: Error, Equatable {
    case valueOutsideUnitInterval(field: String, value: Double)
}

enum BrainValidation {
    static func unitInterval(_ value: Double, field: String) throws -> Double {
        guard (0.0...1.0).contains(value) else {
            throw BrainValidationError.valueOutsideUnitInterval(field: field, value: value)
        }
        return value
    }
}

enum BrainLegacyKey {
    static func normalize(_ raw: String) -> String {
        let folded = raw
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "pt_BR"))
            .lowercased()
        let cleaned = folded
            .replacingOccurrences(of: "[^a-z0-9_]+", with: "_", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return String(cleaned.prefix(64))
    }

    static func searchText(_ raw: String) -> String {
        raw.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "pt_BR"))
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
```

- [ ] **Step 4: Implement domain structs with value semantics**

Use `struct`, `Codable`, `Equatable`, `Identifiable`, and `Sendable` where applicable. The persisted-facing properties are:

```swift
struct BrainEntity: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var type: BrainEntityType
    var displayName: String?
    var status: BrainRecordStatus
    var createdAt: Date
    var updatedAt: Date
}

struct PersonProfile: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var displayName: String?
    var createdAt: Date
    var updatedAt: Date
    var firstSeenAt: Date?
    var lastSeenAt: Date?
    var status: BrainRecordStatus
    var confidence: Double
}

struct PersonAlias: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let personId: UUID
    var alias: String
    var normalizedAlias: String
    var confidence: Double
    var createdAt: Date
    var updatedAt: Date
}

struct BiometricReference: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let personId: UUID
    var kind: BiometricKind
    var storageReference: String
    var quality: Double?
    var createdAt: Date
    var updatedAt: Date
}

struct BrainMemory: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var kind: BrainMemoryKind
    var content: String
    var legacyKey: String?
    var subjectEntityId: UUID?
    var status: BrainRecordStatus
    var confidence: Double
    var importance: Double
    var createdAt: Date
    var updatedAt: Date
    var lastConfirmedAt: Date?
    var expiresAt: Date?
}

struct BrainFact: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var subjectEntityId: UUID?
    var predicate: String
    var value: String
    var status: BrainRecordStatus
    var confidence: Double
    var createdAt: Date
    var updatedAt: Date
    var lastConfirmedAt: Date?
    var supersedesFactId: UUID?
}

struct BrainRelation: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let sourceEntityId: UUID
    var relationType: String
    let targetEntityId: UUID
    var status: BrainRecordStatus
    var confidence: Double
    var createdAt: Date
    var updatedAt: Date
}

struct BrainProvenanceInput: Codable, Equatable, Sendable {
    var source: BrainProvenanceSource
    var sourceIdentifier: String?
    var note: String?
    var timestamp: Date
}

struct BrainProvenance: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var source: BrainProvenanceSource
    var sourceIdentifier: String?
    var note: String?
    var timestamp: Date
}

struct LearningEvent: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var type: LearningEventType
    var targetRecordType: String?
    var targetRecordId: UUID?
    var source: BrainProvenanceSource
    var timestamp: Date
    var beforeSummary: String?
    var afterSummary: String?
    var reversible: Bool
}
```

Before persistence, confidence/importance/quality values are validated by service/store APIs with `BrainValidation.unitInterval`.

- [ ] **Step 5: Run model tests and verify GREEN**

Run the same `xcodebuild ... BrainModelsTests` command.

Expected: `BrainModelsTests` passes.

- [ ] **Step 6: Commit Task 1**

```bash
git add JARVIS/Services/Brain/Models JARVISTests/BrainModelsTests.swift
git commit -m "feat(brain): add structured brain domain models"
```

---

### Task 2: SQLite connection, protected storage path, schema v1, and migration runner

**Files:**
- Create: `JARVIS/Services/Brain/Storage/BrainStore.swift`
- Create: `JARVIS/Services/Brain/Storage/BrainDatabase.swift`
- Create: `JARVIS/Services/Brain/Storage/BrainMigrations.swift`
- Modify: `project.yml`
- Test: `JARVISTests/BrainDatabaseTests.swift`

**Interfaces:**
- Consumes: Task 1 model types.
- Produces:
  - `enum BrainDatabaseLocation: Sendable { case applicationSupport; case file(URL); case inMemory }`
  - `enum BrainStoreError: Error, Equatable`
  - `final class BrainDatabase` used only inside the storage actor.
  - `enum BrainMigrations { static let currentVersion = 1; static func migrate(_ database: BrainDatabase) throws }`
  - `protocol BrainStore: Sendable` with the complete async contract consumed by Tasks 3–5.

- [ ] **Step 1: Write failing database/migration tests**

Create `JARVISTests/BrainDatabaseTests.swift`:

```swift
import XCTest
@testable import JARVIS

final class BrainDatabaseTests: XCTestCase {
    func testInMemoryMigrationCreatesSchemaV1() throws {
        let db = try BrainDatabase(location: .inMemory)
        try BrainMigrations.migrate(db)
        XCTAssertEqual(try db.userVersion(), 1)
        XCTAssertEqual(try db.scalarInt("SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='memories'"), 1)
        XCTAssertEqual(try db.scalarInt("SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='person_profiles'"), 1)
        XCTAssertEqual(try db.scalarInt("SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='learning_events'"), 1)
    }

    func testForeignKeysAreEnabled() throws {
        let db = try BrainDatabase(location: .inMemory)
        XCTAssertEqual(try db.scalarInt("PRAGMA foreign_keys"), 1)
    }

    func testMigrationIsIdempotent() throws {
        let db = try BrainDatabase(location: .inMemory)
        try BrainMigrations.migrate(db)
        try BrainMigrations.migrate(db)
        XCTAssertEqual(try db.userVersion(), 1)
    }
}
```

- [ ] **Step 2: Link system SQLite and verify RED becomes a compile-path failure only**

Add this dependency to target `JARVIS` in `project.yml`:

```yaml
      - sdk: libsqlite3.tbd
```

Then run:

```bash
xcodegen generate
xcodebuild test -project JARVIS.xcodeproj -scheme JARVIS -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:JARVISTests/BrainDatabaseTests -skipPackagePluginValidation -skipMacroValidation
```

Expected: failure because `BrainDatabase`/`BrainMigrations` do not exist yet, not because `SQLite3` cannot be linked.

- [ ] **Step 3: Implement the database location, connection, prepared binding, and transactions**

`BrainDatabase.swift` must `import SQLite3` and implement:

```swift
enum BrainDatabaseLocation: Sendable {
    case applicationSupport
    case file(URL)
    case inMemory
}

enum BrainStoreError: Error, Equatable {
    case openFailed(String)
    case sqlite(code: Int32, message: String)
    case migrationUnsupported(found: Int32, supported: Int32)
    case invalidData(String)
    case notFound
    case notInitialized
    case initializationFailed
}
```

Production path resolution is exactly:

```swift
let support = try FileManager.default.url(
    for: .applicationSupportDirectory,
    in: .userDomainMask,
    appropriateFor: nil,
    create: true
)
let directory = support.appendingPathComponent("JARVISBrain", isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
try FileManager.default.setAttributes(
    [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
    ofItemAtPath: directory.path
)
return directory.appendingPathComponent("JARVIS-Brain.sqlite")
```

Open SQLite with `SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX`. Immediately execute:

```sql
PRAGMA foreign_keys = ON;
PRAGMA busy_timeout = 5000;
PRAGMA journal_mode = WAL;
```

For `.inMemory`, use the literal path `:memory:`; journal mode may remain `memory` and tests must not require WAL for in-memory databases.

Implement safe prepared-statement helpers rather than interpolating user data into SQL. The minimum binding enum is:

```swift
enum SQLiteBinding {
    case text(String)
    case double(Double)
    case int64(Int64)
    case null
}
```

Expose internal testable helpers:

```swift
func execute(_ sql: String, bindings: [SQLiteBinding] = []) throws
func scalarInt(_ sql: String, bindings: [SQLiteBinding] = []) throws -> Int64
func userVersion() throws -> Int32
func transaction<T>(_ body: () throws -> T) throws -> T
```

`transaction` executes `BEGIN IMMEDIATE`, commits on success, and executes `ROLLBACK` on any thrown error.

- [ ] **Step 4: Implement schema v1 in one explicit migration**

`BrainMigrations.migrate(_:)` reads `PRAGMA user_version`, rejects versions greater than `currentVersion`, and for version 0 creates the following tables inside one transaction before setting `PRAGMA user_version = 1`:

```sql
CREATE TABLE brain_metadata (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL,
    updated_at REAL NOT NULL
);

CREATE TABLE entities (
    id TEXT PRIMARY KEY,
    type TEXT NOT NULL,
    display_name TEXT,
    status TEXT NOT NULL,
    created_at REAL NOT NULL,
    updated_at REAL NOT NULL
);

CREATE TABLE person_profiles (
    entity_id TEXT PRIMARY KEY REFERENCES entities(id),
    first_seen_at REAL,
    last_seen_at REAL,
    confidence REAL NOT NULL CHECK(confidence >= 0.0 AND confidence <= 1.0)
);

CREATE TABLE person_aliases (
    id TEXT PRIMARY KEY,
    person_id TEXT NOT NULL REFERENCES person_profiles(entity_id),
    alias TEXT NOT NULL,
    normalized_alias TEXT NOT NULL,
    confidence REAL NOT NULL CHECK(confidence >= 0.0 AND confidence <= 1.0),
    created_at REAL NOT NULL,
    updated_at REAL NOT NULL
);
CREATE INDEX idx_person_aliases_normalized ON person_aliases(normalized_alias);

CREATE TABLE memories (
    id TEXT PRIMARY KEY,
    kind TEXT NOT NULL,
    content TEXT NOT NULL,
    legacy_key TEXT,
    search_text TEXT NOT NULL,
    subject_entity_id TEXT REFERENCES entities(id),
    status TEXT NOT NULL,
    confidence REAL NOT NULL CHECK(confidence >= 0.0 AND confidence <= 1.0),
    importance REAL NOT NULL CHECK(importance >= 0.0 AND importance <= 1.0),
    created_at REAL NOT NULL,
    updated_at REAL NOT NULL,
    last_confirmed_at REAL,
    expires_at REAL
);
CREATE UNIQUE INDEX idx_memories_legacy_key_active
ON memories(legacy_key)
WHERE legacy_key IS NOT NULL AND status IN ('candidate','active');
CREATE INDEX idx_memories_status_updated ON memories(status, updated_at DESC);
CREATE INDEX idx_memories_subject ON memories(subject_entity_id);
CREATE INDEX idx_memories_search ON memories(search_text);

CREATE TABLE facts (
    id TEXT PRIMARY KEY,
    subject_entity_id TEXT REFERENCES entities(id),
    predicate TEXT NOT NULL,
    value TEXT NOT NULL,
    status TEXT NOT NULL,
    confidence REAL NOT NULL CHECK(confidence >= 0.0 AND confidence <= 1.0),
    created_at REAL NOT NULL,
    updated_at REAL NOT NULL,
    last_confirmed_at REAL,
    supersedes_fact_id TEXT REFERENCES facts(id)
);
CREATE INDEX idx_facts_subject_status ON facts(subject_entity_id, status);

CREATE TABLE relations (
    id TEXT PRIMARY KEY,
    source_entity_id TEXT NOT NULL REFERENCES entities(id),
    relation_type TEXT NOT NULL,
    target_entity_id TEXT NOT NULL REFERENCES entities(id),
    status TEXT NOT NULL,
    confidence REAL NOT NULL CHECK(confidence >= 0.0 AND confidence <= 1.0),
    created_at REAL NOT NULL,
    updated_at REAL NOT NULL
);
CREATE INDEX idx_relations_source ON relations(source_entity_id, status);
CREATE INDEX idx_relations_target ON relations(target_entity_id, status);

CREATE TABLE provenance (
    id TEXT PRIMARY KEY,
    source TEXT NOT NULL,
    source_identifier TEXT,
    note TEXT,
    timestamp REAL NOT NULL
);

CREATE TABLE record_provenance (
    record_type TEXT NOT NULL,
    record_id TEXT NOT NULL,
    provenance_id TEXT NOT NULL REFERENCES provenance(id),
    PRIMARY KEY(record_type, record_id, provenance_id)
);
CREATE INDEX idx_record_provenance_record ON record_provenance(record_type, record_id);

CREATE TABLE learning_events (
    id TEXT PRIMARY KEY,
    event_type TEXT NOT NULL,
    target_record_type TEXT,
    target_record_id TEXT,
    source TEXT NOT NULL,
    timestamp REAL NOT NULL,
    before_summary TEXT,
    after_summary TEXT,
    reversible INTEGER NOT NULL CHECK(reversible IN (0,1))
);
CREATE INDEX idx_learning_events_target ON learning_events(target_record_type, target_record_id, timestamp DESC);

CREATE TABLE biometric_refs (
    id TEXT PRIMARY KEY,
    person_id TEXT NOT NULL REFERENCES person_profiles(entity_id),
    kind TEXT NOT NULL,
    storage_reference TEXT NOT NULL,
    quality REAL CHECK(quality IS NULL OR (quality >= 0.0 AND quality <= 1.0)),
    created_at REAL NOT NULL,
    updated_at REAL NOT NULL
);
```

- [ ] **Step 5: Define the complete `BrainStore` protocol now so later tasks cannot drift**

`BrainStore.swift` must declare:

```swift
protocol BrainStore: Sendable {
    func initialize() async throws

    func metadataValue(for key: String) async throws -> String?
    func setMetadataValue(_ value: String, for key: String, at: Date) async throws

    func createMemory(_ memory: BrainMemory, provenance: BrainProvenanceInput) async throws -> BrainMemory
    func updateMemoryContent(id: UUID, content: String, at: Date, provenance: BrainProvenanceInput) async throws -> BrainMemory
    func memory(id: UUID) async throws -> BrainMemory?
    func memory(legacyKey: String) async throws -> BrainMemory?
    func listMemories(statuses: Set<BrainRecordStatus>, limit: Int) async throws -> [BrainMemory]
    func searchMemories(query: String, statuses: Set<BrainRecordStatus>, limit: Int) async throws -> [BrainMemory]
    func forgetMemory(id: UUID, at: Date, provenance: BrainProvenanceInput) async throws -> Bool
    func forgetMemories(matching query: String, at: Date, provenance: BrainProvenanceInput) async throws -> Int
    func importLegacyMemories(_ memories: [String: String], at: Date) async throws -> Int

    func createEntity(_ entity: BrainEntity) async throws -> BrainEntity
    func entity(id: UUID) async throws -> BrainEntity?
    func createPersonProfile(_ profile: PersonProfile, entity: BrainEntity) async throws -> PersonProfile
    func personProfile(id: UUID) async throws -> PersonProfile?
    func listPersonProfiles(limit: Int) async throws -> [PersonProfile]
    func addAlias(_ alias: PersonAlias, provenance: BrainProvenanceInput) async throws -> PersonAlias
    func aliases(personId: UUID) async throws -> [PersonAlias]
    func addBiometricReference(_ reference: BiometricReference, provenance: BrainProvenanceInput) async throws -> BiometricReference
    func biometricReferences(personId: UUID) async throws -> [BiometricReference]

    func createFact(_ fact: BrainFact, provenance: BrainProvenanceInput) async throws -> BrainFact
    func facts(subjectEntityId: UUID?, statuses: Set<BrainRecordStatus>) async throws -> [BrainFact]
    func supersedeFact(oldFactId: UUID, with newFact: BrainFact, at: Date, provenance: BrainProvenanceInput) async throws -> BrainFact

    func createRelation(_ relation: BrainRelation, provenance: BrainProvenanceInput) async throws -> BrainRelation
    func relations(entityId: UUID, statuses: Set<BrainRecordStatus>) async throws -> [BrainRelation]

    func appendLearningEvent(_ event: LearningEvent) async throws -> LearningEvent
    func learningEvents(targetRecordId: UUID?, limit: Int) async throws -> [LearningEvent]
}
```

- [ ] **Step 6: Run database tests and verify GREEN**

Run the same `BrainDatabaseTests` command.

Expected: all database migration tests pass.

- [ ] **Step 7: Commit Task 2**

```bash
git add project.yml JARVIS/Services/Brain/Storage JARVISTests/BrainDatabaseTests.swift
git commit -m "feat(brain): add sqlite schema and migration foundation"
```

---

### Task 3: SQLiteBrainStore memory, provenance, search, and forget behavior

**Files:**
- Create: `JARVIS/Services/Brain/Storage/SQLiteBrainStore.swift`
- Test: `JARVISTests/SQLiteBrainStoreMemoryTests.swift`

**Interfaces:**
- Consumes: `BrainStore`, `BrainDatabase`, `BrainMigrations`, Task 1 models.
- Produces: `actor SQLiteBrainStore: BrainStore`, with `init(location: BrainDatabaseLocation)` and all memory/metadata/import methods needed by Task 5.

- [ ] **Step 1: Write failing memory-store tests**

Create tests using `.inMemory` and explicit dates/UUIDs so ordering is deterministic:

```swift
import XCTest
@testable import JARVIS

final class SQLiteBrainStoreMemoryTests: XCTestCase {
    private func makeStore() async throws -> SQLiteBrainStore {
        let store = SQLiteBrainStore(location: .inMemory)
        try await store.initialize()
        return store
    }

    func testCreateAndReadLegacyKeyMemory() async throws {
        let store = try await makeStore()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let memory = BrainMemory(
            id: UUID(), kind: .semantic, content: "Prefere Celsius.", legacyKey: "temperature_unit",
            subjectEntityId: nil, status: .active, confidence: 1.0, importance: 0.5,
            createdAt: now, updatedAt: now, lastConfirmedAt: now, expiresAt: nil
        )
        _ = try await store.createMemory(memory, provenance: .init(source: .explicitUser, sourceIdentifier: nil, note: nil, timestamp: now))
        XCTAssertEqual(try await store.memory(legacyKey: "temperature_unit")?.content, "Prefere Celsius.")
    }

    func testSearchIsCaseAndDiacriticInsensitive() async throws {
        let store = try await makeStore()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let memory = BrainMemory(
            id: UUID(), kind: .semantic, content: "Café sem açúcar em São Paulo", legacyKey: "cafe",
            subjectEntityId: nil, status: .active, confidence: 1, importance: 0.5,
            createdAt: now, updatedAt: now, lastConfirmedAt: now, expiresAt: nil
        )
        _ = try await store.createMemory(memory, provenance: .init(source: .explicitUser, sourceIdentifier: nil, note: nil, timestamp: now))
        XCTAssertEqual(try await store.searchMemories(query: "CAFE SAO", statuses: [.active], limit: 8).count, 1)
    }

    func testForgetHidesMemoryFromActiveQueriesWithoutDeletingAuditRow() async throws {
        let store = try await makeStore()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let memory = BrainMemory(
            id: UUID(), kind: .semantic, content: "Old fact", legacyKey: "old_fact",
            subjectEntityId: nil, status: .active, confidence: 1, importance: 0.5,
            createdAt: now, updatedAt: now, lastConfirmedAt: now, expiresAt: nil
        )
        _ = try await store.createMemory(memory, provenance: .init(source: .explicitUser, sourceIdentifier: nil, note: nil, timestamp: now))
        XCTAssertTrue(try await store.forgetMemory(id: memory.id, at: now.addingTimeInterval(10), provenance: .init(source: .explicitUser, sourceIdentifier: nil, note: nil, timestamp: now)))
        XCTAssertNil(try await store.memory(legacyKey: "old_fact"))
        XCTAssertEqual(try await store.memory(id: memory.id)?.status, .forgotten)
    }

    func testInvalidConfidenceIsRejectedBeforeSQLiteWrite() async throws {
        let store = try await makeStore()
        let now = Date()
        let memory = BrainMemory(
            id: UUID(), kind: .semantic, content: "bad", legacyKey: "bad",
            subjectEntityId: nil, status: .active, confidence: 1.2, importance: 0.5,
            createdAt: now, updatedAt: now, lastConfirmedAt: nil, expiresAt: nil
        )
        await XCTAssertThrowsErrorAsync {
            _ = try await store.createMemory(memory, provenance: .init(source: .explicitUser, sourceIdentifier: nil, note: nil, timestamp: now))
        }
    }
}
```

Add this test helper in the same file:

```swift
private func XCTAssertThrowsErrorAsync(
    _ expression: @escaping () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected error", file: file, line: line)
    } catch { }
}
```

- [ ] **Step 2: Run memory-store tests and verify RED**

Run:

```bash
xcodebuild test -project JARVIS.xcodeproj -scheme JARVIS -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:JARVISTests/SQLiteBrainStoreMemoryTests -skipPackagePluginValidation -skipMacroValidation
```

Expected: failure because `SQLiteBrainStore` is not implemented.

- [ ] **Step 3: Implement actor-owned database initialization and row mapping**

`SQLiteBrainStore` owns one optional `BrainDatabase` and is the only owner of that connection:

```swift
actor SQLiteBrainStore: BrainStore {
    private let location: BrainDatabaseLocation
    private var database: BrainDatabase?

    init(location: BrainDatabaseLocation = .applicationSupport) {
        self.location = location
    }

    func initialize() async throws {
        if database != nil { return }
        let db = try BrainDatabase(location: location)
        try BrainMigrations.migrate(db)
        database = db
    }

    private func requireDatabase() throws -> BrainDatabase {
        guard let database else { throw BrainStoreError.notInitialized }
        return database
    }
}
```

Map dates as Unix seconds (`Date.timeIntervalSince1970`) and UUIDs as lowercase UUID strings. Never serialize memory content into logs.

- [ ] **Step 4: Implement provenance insertion and record linkage as private storage helpers**

Use one provenance row per write/evidence input and link with `record_provenance`:

```swift
private func insertProvenance(
    _ input: BrainProvenanceInput,
    recordType: String,
    recordId: UUID,
    db: BrainDatabase
) throws -> UUID
```

The function inserts into `provenance`, then `record_provenance`, using prepared bindings only. `recordType` values used in Phase 1 are exactly `memory`, `fact`, `relation`, `person_alias`, and `biometric_ref`.

- [ ] **Step 5: Implement create/read/update/list/search memory operations**

Rules:

- Normalize non-nil legacy keys with `BrainLegacyKey.normalize`; reject an empty normalized key with `BrainStoreError.invalidData("empty legacy key")`.
- Generate `search_text` as `BrainLegacyKey.searchText([legacyKey, content].compactMap { $0 }.joined(separator: " "))`.
- Validate confidence and importance with `BrainValidation.unitInterval` before any SQL write.
- `memory(legacyKey:)` returns only `candidate` or `active` records.
- `listMemories` orders by `updated_at DESC, id ASC` and enforces `max(1, min(limit, 500))`.
- `searchMemories` normalizes the query with `BrainLegacyKey.searchText` and uses `search_text LIKE '%' || ? || '%'`; because the stored value is already folded/lowercase, matching remains Unicode-safe for the Portuguese cases covered by tests.
- `updateMemoryContent` updates content, `search_text`, and `updated_at`, then adds provenance in the same transaction.

- [ ] **Step 6: Implement forget semantics and metadata getters/setters**

`forgetMemory` sets status to `forgotten`, updates `updated_at`, and appends provenance in one transaction. It does not delete content or provenance rows. `forgetMemories(matching:)` first finds active/candidate matching IDs, then marks all forgotten in one transaction and returns the count. `metadataValue`/`setMetadataValue` operate only on `brain_metadata`.

- [ ] **Step 7: Run memory-store tests and verify GREEN**

Expected: all `SQLiteBrainStoreMemoryTests` pass.

- [ ] **Step 8: Commit Task 3**

```bash
git add JARVIS/Services/Brain/Storage/SQLiteBrainStore.swift JARVISTests/SQLiteBrainStoreMemoryTests.swift
git commit -m "feat(brain): persist memories in sqlite store"
```

---

### Task 4: Person profiles, aliases, entities, facts, relations, biometric references, and learning events

**Files:**
- Modify: `JARVIS/Services/Brain/Storage/SQLiteBrainStore.swift`
- Test: `JARVISTests/SQLiteBrainStoreGraphTests.swift`

**Interfaces:**
- Consumes: Task 3 initialized `SQLiteBrainStore` and Task 1 models.
- Produces: remaining `BrainStore` graph/audit methods with transactional correction semantics.

- [ ] **Step 1: Write failing graph/audit tests**

Create `SQLiteBrainStoreGraphTests.swift` with these core behaviors:

```swift
import XCTest
@testable import JARVIS

final class SQLiteBrainStoreGraphTests: XCTestCase {
    private func makeStore() async throws -> SQLiteBrainStore {
        let store = SQLiteBrainStore(location: .inMemory)
        try await store.initialize()
        return store
    }

    func testPersonUsesEntityUUIDAndSupportsMultipleAliases() async throws {
        let store = try await makeStore()
        let id = UUID()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let entity = BrainEntity(id: id, type: .person, displayName: "João", status: .active, createdAt: now, updatedAt: now)
        let profile = PersonProfile(id: id, displayName: "João", createdAt: now, updatedAt: now, firstSeenAt: now, lastSeenAt: now, status: .active, confidence: 1)
        _ = try await store.createPersonProfile(profile, entity: entity)
        _ = try await store.addAlias(.init(id: UUID(), personId: id, alias: "João", normalizedAlias: "joao", confidence: 1, createdAt: now, updatedAt: now), provenance: .init(source: .explicitUser, sourceIdentifier: nil, note: nil, timestamp: now))
        _ = try await store.addAlias(.init(id: UUID(), personId: id, alias: "João do Financeiro", normalizedAlias: "joao do financeiro", confidence: 1, createdAt: now, updatedAt: now), provenance: .init(source: .explicitUser, sourceIdentifier: nil, note: nil, timestamp: now))
        XCTAssertEqual(try await store.aliases(personId: id).count, 2)
        XCTAssertEqual(try await store.personProfile(id: id)?.id, id)
    }

    func testSupersedeFactKeepsOldHistoryAndActivatesNewFact() async throws {
        let store = try await makeStore()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let personId = UUID()
        let entity = BrainEntity(id: personId, type: .person, displayName: "João", status: .active, createdAt: now, updatedAt: now)
        _ = try await store.createEntity(entity)
        let old = BrainFact(id: UUID(), subjectEntityId: personId, predicate: "department", value: "TI", status: .active, confidence: 1, createdAt: now, updatedAt: now, lastConfirmedAt: now, supersedesFactId: nil)
        _ = try await store.createFact(old, provenance: .init(source: .explicitUser, sourceIdentifier: nil, note: nil, timestamp: now))
        let replacement = BrainFact(id: UUID(), subjectEntityId: personId, predicate: "department", value: "Financeiro", status: .active, confidence: 1, createdAt: now, updatedAt: now, lastConfirmedAt: now, supersedesFactId: old.id)
        _ = try await store.supersedeFact(oldFactId: old.id, with: replacement, at: now.addingTimeInterval(60), provenance: .init(source: .explicitUser, sourceIdentifier: nil, note: nil, timestamp: now))
        XCTAssertEqual(try await store.facts(subjectEntityId: personId, statuses: [.active]).map(\.value), ["Financeiro"])
        XCTAssertEqual(try await store.facts(subjectEntityId: personId, statuses: [.superseded]).map(\.value), ["TI"])
    }

    func testRelationAndBiometricReferencePointToStablePersonUUID() async throws {
        let store = try await makeStore()
        let now = Date()
        let personId = UUID()
        let orgId = UUID()
        _ = try await store.createPersonProfile(
            .init(id: personId, displayName: "João", createdAt: now, updatedAt: now, firstSeenAt: nil, lastSeenAt: nil, status: .active, confidence: 1),
            entity: .init(id: personId, type: .person, displayName: "João", status: .active, createdAt: now, updatedAt: now)
        )
        _ = try await store.createEntity(.init(id: orgId, type: .organization, displayName: "Cresol", status: .active, createdAt: now, updatedAt: now))
        _ = try await store.createRelation(.init(id: UUID(), sourceEntityId: personId, relationType: "works_at", targetEntityId: orgId, status: .active, confidence: 1, createdAt: now, updatedAt: now), provenance: .init(source: .explicitUser, sourceIdentifier: nil, note: nil, timestamp: now))
        _ = try await store.addBiometricReference(.init(id: UUID(), personId: personId, kind: .face, storageReference: "secure://face/abc", quality: 0.9, createdAt: now, updatedAt: now), provenance: .init(source: .toolResult, sourceIdentifier: "face-recognition", note: nil, timestamp: now))
        XCTAssertEqual(try await store.relations(entityId: personId, statuses: [.active]).count, 1)
        XCTAssertEqual(try await store.biometricReferences(personId: personId).first?.personId, personId)
    }
}
```

- [ ] **Step 2: Run graph tests and verify RED**

Expected: failures because the remaining protocol methods still throw/are absent.

- [ ] **Step 3: Implement entity and person/profile APIs**

`createPersonProfile` must use one transaction: insert the `entities` row with `type = person`, then the `person_profiles` row using the same UUID. Reject a mismatched `profile.id != entity.id` or `entity.type != .person` with `BrainStoreError.invalidData`.

`listPersonProfiles(limit:)` joins `person_profiles` with `entities`, returning `displayName/status/createdAt/updatedAt` from the entity row and person-specific fields from `person_profiles`.

- [ ] **Step 4: Implement aliases and biometric references**

For aliases:

- ignore the caller-provided `normalizedAlias` and recompute it with `BrainLegacyKey.searchText(alias.alias)` so storage normalization is deterministic;
- validate confidence;
- add provenance in the same transaction;
- never merge people based on alias equality.

For biometric references:

- validate optional quality if non-nil;
- store only opaque `storageReference` text;
- never log or return any raw embedding data because raw embeddings are not part of this model.

- [ ] **Step 5: Implement facts and transactional supersession**

`createFact` validates confidence and inserts provenance atomically.

`supersedeFact` executes one transaction that:

1. verifies the old fact exists and is active/candidate;
2. updates old fact status to `superseded` and `updated_at`;
3. forces `newFact.supersedesFactId = oldFactId` and `newFact.status = active`;
4. inserts the new fact;
5. links provenance to the new fact;
6. returns the new fact.

No UPDATE may overwrite the old fact's `predicate` or `value`.

- [ ] **Step 6: Implement relations and learning events**

`relations(entityId:statuses:)` returns edges where the entity is either source or target, ordered by `updated_at DESC`.

`appendLearningEvent` stores summaries as supplied but callers are responsible for not putting secrets/hidden reasoning into them. `learningEvents(targetRecordId:limit:)` orders newest-first and clamps the limit to `1...500`.

- [ ] **Step 7: Run graph/audit tests and verify GREEN**

Expected: all `SQLiteBrainStoreGraphTests` pass.

- [ ] **Step 8: Commit Task 4**

```bash
git add JARVIS/Services/Brain/Storage/SQLiteBrainStore.swift JARVISTests/SQLiteBrainStoreGraphTests.swift
git commit -m "feat(brain): add people facts relations and audit storage"
```

---

### Task 5: BrainService readiness gate and exactly-once legacy migration

**Files:**
- Create: `JARVIS/Services/Brain/Migration/LegacyMemoryImporter.swift`
- Create: `JARVIS/Services/Brain/BrainService.swift`
- Modify: `JARVIS/Services/Brain/Storage/SQLiteBrainStore.swift`
- Test: `JARVISTests/BrainServiceMigrationTests.swift`

**Interfaces:**
- Consumes: complete `BrainStore` implementation.
- Produces:
  - `enum BrainReadiness: Equatable, Sendable { case notInitialized; case ready; case failed }`
  - `actor BrainService`
  - `static let BrainService.shared`
  - compatibility methods used by Task 6/7.

- [ ] **Step 1: Write failing exactly-once migration and service readiness tests**

Create `BrainServiceMigrationTests.swift`:

```swift
import XCTest
@testable import JARVIS

final class BrainServiceMigrationTests: XCTestCase {
    func testLegacyMemoriesImportExactlyOnce() async throws {
        let store = SQLiteBrainStore(location: .inMemory)
        let service = BrainService(store: store)
        let legacy = ["idioma_preferido": "Português brasileiro", "favorite_team": "Time A"]
        try await service.initialize(legacyMemories: legacy)
        XCTAssertEqual(try await service.listActiveMemories(limit: 20).count, 2)
        try await service.initialize(legacyMemories: legacy)
        XCTAssertEqual(try await service.listActiveMemories(limit: 20).count, 2)
        XCTAssertEqual(await service.readiness(), .ready)
    }

    func testLegacyImportPreservesKeyContentAndProvenanceIntent() async throws {
        let store = SQLiteBrainStore(location: .inMemory)
        let service = BrainService(store: store)
        try await service.initialize(legacyMemories: ["projeto_principal": "Projeto JARVIS"])
        let memory = try await service.memory(legacyKey: "projeto_principal")
        XCTAssertEqual(memory?.legacyKey, "projeto_principal")
        XCTAssertEqual(memory?.content, "Projeto JARVIS")
        XCTAssertEqual(memory?.confidence, 1.0)
        XCTAssertEqual(memory?.status, .active)
    }

    func testExplicitRememberUpsertsLegacyKeyInsteadOfDuplicating() async throws {
        let store = SQLiteBrainStore(location: .inMemory)
        let service = BrainService(store: store)
        try await service.initialize(legacyMemories: [:])
        _ = try await service.rememberLegacy(key: "temperature_unit", value: "Celsius", source: .explicitUser)
        _ = try await service.rememberLegacy(key: "temperature_unit", value: "Celsius sempre", source: .explicitUser)
        XCTAssertEqual(try await service.listActiveMemories(limit: 20).count, 1)
        XCTAssertEqual(try await service.memory(legacyKey: "temperature_unit")?.content, "Celsius sempre")
    }
}
```

- [ ] **Step 2: Run migration tests and verify RED**

Expected: failures because `BrainService` and import orchestration do not exist.

- [ ] **Step 3: Implement atomic `SQLiteBrainStore.importLegacyMemories`**

Use metadata key exactly:

```text
legacy_memory_import_v1
```

Inside one store-actor transaction:

1. return `0` immediately if the metadata value is `completed`;
2. sort input keys for deterministic tests;
3. for each key/value create an active `.semantic` memory with `confidence = 1.0`, `importance = 0.5`, `lastConfirmedAt = importedAt`, `legacyKey = normalized key`;
4. use provenance source `.legacyImport`, source identifier `settings.json`, timestamp `importedAt`;
5. insert a `LearningEvent(type: .legacyImport, targetRecordType: "memory", targetRecordId: memory.id, source: .legacyImport, timestamp: importedAt, beforeSummary: nil, afterSummary: nil, reversible: false)` without copying the memory content into the event summary;
6. only after every row succeeds, set `brain_metadata['legacy_memory_import_v1'] = 'completed'`;
7. commit.

Any error rolls back memories, provenance, events, and metadata marker together.

- [ ] **Step 4: Implement `LegacyMemoryImporter` as a small policy wrapper**

```swift
struct LegacyMemoryImporter: Sendable {
    let store: any BrainStore

    func importIfNeeded(_ memories: [String: String], at: Date) async throws -> Int {
        try await store.importLegacyMemories(memories, at: at)
    }
}
```

The importer never mutates `SettingsManager`, `AppSettings`, or `settings.json`.

- [ ] **Step 5: Implement `BrainService` readiness and compatibility API**

Use an actor so future tool/UI/background callers share one serialization boundary:

```swift
enum BrainReadiness: Equatable, Sendable {
    case notInitialized
    case ready
    case failed
}

actor BrainService {
    static let shared = BrainService(store: SQLiteBrainStore(location: .applicationSupport))

    private let store: any BrainStore
    private var state: BrainReadiness = .notInitialized

    init(store: any BrainStore) {
        self.store = store
    }

    func readiness() -> BrainReadiness { state }

    func initialize(legacyMemories: [String: String]) async throws {
        if state == .ready { return }
        do {
            try await store.initialize()
            _ = try await LegacyMemoryImporter(store: store).importIfNeeded(legacyMemories, at: Date())
            state = .ready
        } catch {
            state = .failed
            throw error
        }
    }
}
```

Every public data method calls a private `requireReady()` first. Add exact compatibility methods:

```swift
func rememberLegacy(key: String, value: String, source: BrainProvenanceSource) async throws -> BrainMemory
func memory(legacyKey: String) async throws -> BrainMemory?
func searchActiveMemories(query: String, limit: Int) async throws -> [BrainMemory]
func listActiveMemories(limit: Int) async throws -> [BrainMemory]
func updateMemoryContent(id: UUID, content: String, source: BrainProvenanceSource) async throws -> BrainMemory
func forgetMemory(id: UUID, source: BrainProvenanceSource) async throws -> Bool
func forgetLegacy(key: String, source: BrainProvenanceSource) async throws -> Bool
func forgetMemories(matching query: String, source: BrainProvenanceSource) async throws -> Int
```

`rememberLegacy` normalizes the key. If an active/candidate memory with that key exists, update that record's content instead of inserting a duplicate. New explicit memories use `.semantic`, `.active`, confidence `1.0`, importance `0.5`.

Also expose typed wrappers for person/entity/alias/fact/relation/learning-event methods from the spec so future consumers call `BrainService`, not `BrainStore` directly.

- [ ] **Step 6: Run migration/service tests and verify GREEN**

Expected: all `BrainServiceMigrationTests` pass.

- [ ] **Step 7: Commit Task 5**

```bash
git add JARVIS/Services/Brain/Migration JARVIS/Services/Brain/BrainService.swift JARVIS/Services/Brain/Storage/SQLiteBrainStore.swift JARVISTests/BrainServiceMigrationTests.swift
git commit -m "feat(brain): add brain service and legacy migration"
```

---

### Task 6: Route the existing voice MemoryTool through BrainService without changing its public schema

**Files:**
- Modify: `JARVIS/Services/NativeTools/MemoryTool.swift`
- Test: `JARVISTests/MemoryToolBrainTests.swift`

**Interfaces:**
- Consumes: Task 5 `BrainService` compatibility methods.
- Produces: existing tool actions `remember`, `get`, `search`, `list`, `forget` with the same argument names and user-facing semantics.

- [ ] **Step 1: Make MemoryTool injectable for tests and write failing compatibility tests**

Change only construction, not the tool name/schema:

```swift
struct MemoryTool: NativeTool {
    private let brain: BrainService

    init(brain: BrainService = .shared) {
        self.brain = brain
    }
    // existing name, description, parametersSchema remain
}
```

Create `MemoryToolBrainTests.swift`:

```swift
import XCTest
@testable import JARVIS

final class MemoryToolBrainTests: XCTestCase {
    func testRememberGetSearchAndForgetUseBrainService() async throws {
        let brain = BrainService(store: SQLiteBrainStore(location: .inMemory))
        try await brain.initialize(legacyMemories: [:])
        let tool = MemoryTool(brain: brain)

        XCTAssertTrue(try await tool.execute(args: ["action": "remember", "key": "favorite_drink", "value": "Café"]).contains("Memória salva"))
        XCTAssertTrue(try await tool.execute(args: ["action": "get", "key": "favorite_drink"]).contains("Café"))
        XCTAssertTrue(try await tool.execute(args: ["action": "search", "query": "cafe"]).contains("favorite_drink"))
        XCTAssertTrue(try await tool.execute(args: ["action": "forget", "key": "favorite_drink"]).contains("apagada"))
        XCTAssertTrue(try await tool.execute(args: ["action": "get", "key": "favorite_drink"]).contains("Não encontrei"))
    }

    func testToolNeverNeedsSettingsManagerMemoryDictionary() async throws {
        let brain = BrainService(store: SQLiteBrainStore(location: .inMemory))
        try await brain.initialize(legacyMemories: ["source": "brain"])
        let tool = MemoryTool(brain: brain)
        XCTAssertTrue(try await tool.execute(args: ["action": "get", "key": "source"]).contains("brain"))
    }
}
```

- [ ] **Step 2: Run tool tests and verify RED**

Expected: failure until `MemoryTool` is routed through `BrainService`.

- [ ] **Step 3: Replace SettingsManager access with BrainService calls**

Keep the existing `parametersSchema` unchanged. Preserve the current Portuguese response shape as closely as possible. Map actions exactly:

```text
remember -> brain.rememberLegacy(... source: .explicitUser)
get      -> brain.memory(legacyKey:)
search   -> brain.searchActiveMemories(query:limit: 8)
list     -> brain.listActiveMemories(limit: 12)
forget key   -> brain.forgetLegacy(key:source: .explicitUser)
forget query -> brain.forgetMemories(matching:source: .explicitUser)
```

Format memory lines with `memory.legacyKey ?? memory.id.uuidString` as the key label.

On `BrainStoreError.notInitialized` or failed readiness, return a controlled message such as `"A memória persistente está temporariamente indisponível."` rather than crashing or falling back to the stale legacy dictionary.

Do not log values. If a diagnostic is needed, log only operation and result count/record UUID.

- [ ] **Step 4: Remove duplicate key-normalization logic from MemoryTool**

Delete private `cleanKey` and use `BrainLegacyKey.normalize`. Keep `timestampKey()` only if the tool still needs to generate a missing key; preferred behavior is:

```swift
if normalizedKey.isEmpty {
    key = "memoria_" + Self.timestampKey()
}
```

and then pass the generated key to `BrainService`.

- [ ] **Step 5: Run tool tests and existing NativeTool tests**

Run:

```bash
xcodebuild test -project JARVIS.xcodeproj -scheme JARVIS -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:JARVISTests/MemoryToolBrainTests -only-testing:JARVISTests/NativeToolSupportTests -skipPackagePluginValidation -skipMacroValidation
```

Expected: both suites pass.

- [ ] **Step 6: Commit Task 6**

```bash
git add JARVIS/Services/NativeTools/MemoryTool.swift JARVISTests/MemoryToolBrainTests.swift
git commit -m "feat(brain): route memory tool through brain service"
```

---

### Task 7: Switch Memories UI to canonical BrainService through a MainActor view model

**Files:**
- Create: `JARVIS/Views/Settings/MemoriesViewModel.swift`
- Modify: `JARVIS/Views/Settings/MemoriesView.swift`
- Test: `JARVISTests/MemoriesViewModelTests.swift`

**Interfaces:**
- Consumes: `BrainService` from Task 5.
- Produces: `@MainActor final class MemoriesViewModel: ObservableObject` and a UI that no longer reads/writes `SettingsManager.settings.memories`.

- [ ] **Step 1: Write failing view-model tests**

Create `MemoriesViewModelTests.swift`:

```swift
import XCTest
@testable import JARVIS

@MainActor
final class MemoriesViewModelTests: XCTestCase {
    func testLoadSaveEditAndForgetUseCanonicalBrain() async throws {
        let brain = BrainService(store: SQLiteBrainStore(location: .inMemory))
        try await brain.initialize(legacyMemories: [:])
        let vm = MemoriesViewModel(brain: brain)

        await vm.reload()
        XCTAssertTrue(vm.memories.isEmpty)

        await vm.saveNew(key: "favorite_color", value: "Azul")
        XCTAssertEqual(vm.memories.first?.legacyKey, "favorite_color")

        let memory = try XCTUnwrap(vm.memories.first)
        await vm.update(memory: memory, value: "Verde")
        XCTAssertEqual(vm.memories.first?.content, "Verde")

        await vm.forget(memory: try XCTUnwrap(vm.memories.first))
        XCTAssertTrue(vm.memories.isEmpty)
    }
}
```

- [ ] **Step 2: Run view-model tests and verify RED**

Expected: compile failure because `MemoriesViewModel` does not exist.

- [ ] **Step 3: Implement MainActor view model**

Use this state/API:

```swift
@MainActor
final class MemoriesViewModel: ObservableObject {
    @Published private(set) var memories: [BrainMemory] = []
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?

    private let brain: BrainService

    init(brain: BrainService = .shared) {
        self.brain = brain
    }

    func reload() async
    func saveNew(key: String, value: String) async
    func update(memory: BrainMemory, value: String) async
    func forget(memory: BrainMemory) async
}
```

`saveNew` uses provenance source `.manualEdit`; `update` uses `updateMemoryContent`; `forget` uses `forgetMemory`. Every mutation finishes by reloading active memories. Errors set a generic user-facing message and must not include memory content or raw SQLite error text.

- [ ] **Step 4: Refactor MemoriesView to use the view model**

Replace `@EnvironmentObject var settingsManager` memory access with:

```swift
@StateObject private var viewModel = MemoriesViewModel()
```

Add `.task { await viewModel.reload() }`.

List `viewModel.memories`. For labels use:

```swift
let label = memory.legacyKey ?? "memory_\(memory.id.uuidString.prefix(8).lowercased())"
```

Editor input becomes `BrainMemory?` rather than `(key,value)`. Existing records keep their key/derived identifier disabled and allow content editing. New records require a key and content. Delete/forget calls the view model asynchronously.

Do not expose provenance, biometric references, or audit history in this Phase 1 UI.

- [ ] **Step 5: Run view-model tests and compile the full app**

Run:

```bash
xcodebuild test -project JARVIS.xcodeproj -scheme JARVIS -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:JARVISTests/MemoriesViewModelTests -skipPackagePluginValidation -skipMacroValidation
xcodebuild build -project JARVIS.xcodeproj -scheme JARVIS -destination 'generic/platform=iOS Simulator' -skipPackagePluginValidation -skipMacroValidation
```

Expected: tests pass and app target compiles.

- [ ] **Step 6: Commit Task 7**

```bash
git add JARVIS/Views/Settings/MemoriesViewModel.swift JARVIS/Views/Settings/MemoriesView.swift JARVISTests/MemoriesViewModelTests.swift
git commit -m "feat(brain): move memories UI to canonical brain"
```

---

### Task 8: App startup initialization, failure isolation, privacy logging check, and full regression validation

**Files:**
- Modify: `JARVIS/App/JARVISApp.swift`
- Modify only if necessary for compile integration: `JARVIS/Managers/SettingsManager.swift`
- Test: `JARVISTests/BrainServiceMigrationTests.swift`
- Validate: all Brain tests + existing JARVIS tests + build configuration.

**Interfaces:**
- Consumes: `BrainService.shared` and the existing legacy dictionary snapshot.
- Produces: deterministic launch-time initialization without deleting or dual-writing `settings.json` memories.

- [ ] **Step 1: Add a regression test that initialization does not mutate the supplied legacy dictionary**

Append to `BrainServiceMigrationTests.swift`:

```swift
func testInitializationDoesNotMutateLegacySourceDictionary() async throws {
    let store = SQLiteBrainStore(location: .inMemory)
    let service = BrainService(store: store)
    var legacy = ["stable": "value"]
    let before = legacy
    try await service.initialize(legacyMemories: legacy)
    XCTAssertEqual(legacy, before)
}
```

Run the migration suite; it should already pass if Task 5 respected the boundary.

- [ ] **Step 2: Initialize Brain in the root app task before memory-dependent user actions**

In the existing root `.task` in `JARVISApp.body`, initialize Brain before restoring metrics:

```swift
.task {
    let legacySnapshot = SettingsManager.shared.settings.memories
    do {
        try await BrainService.shared.initialize(legacyMemories: legacySnapshot)
        DiagnosticLogger.shared.log("Brain", "Initialized schema=1")
    } catch {
        DiagnosticLogger.shared.log("Brain", "Initialization failed")
    }

    MetricsCollector.shared.restoreAtLaunch()
}
```

Do not log `error.localizedDescription` here because database errors may eventually contain path or SQL context; diagnostics only need the operation outcome.

Non-memory app functionality remains available even when initialization fails. `MemoryTool` and `MemoriesViewModel` already provide controlled failure behavior.

- [ ] **Step 3: Keep legacy settings memory code as rollback-only compatibility data**

Do not delete `AppSettings.memories` or the current starter seed in this phase. Do not call `SettingsManager.setMemory/deleteMemory/renameMemory` from new Brain runtime paths. Add a concise comment above those legacy helper methods if they remain referenced only by rollback/old data:

```swift
// Legacy rollback/migration surface. Runtime memory is canonical in BrainService after Brain initialization.
```

Do not migrate API keys, auth tokens, telemetry secrets, userPrompt, or unrelated settings into the Brain.

- [ ] **Step 4: Add a source-level privacy regression check**

Run:

```bash
rg -n 'DiagnosticLogger.*(content|value|alias|storageReference|beforeSummary|afterSummary)|print\(.*(content|value|alias|storageReference)' JARVIS/Services/Brain JARVIS/Services/NativeTools/MemoryTool.swift JARVIS/Views/Settings/MemoriesViewModel.swift
```

Expected: no matches that interpolate user memory/fact/alias/biometric content. Operation IDs/counts are allowed.

Also run:

```bash
rg -n 'SettingsManager\.shared\.(setMemory|deleteMemory|renameMemory)|settings\.memories' JARVIS/Services/NativeTools/MemoryTool.swift JARVIS/Views/Settings/MemoriesView.swift JARVIS/Views/Settings/MemoriesViewModel.swift
```

Expected: no matches. These runtime adapters must use the canonical Brain only.

- [ ] **Step 5: Run every new Brain test suite**

Run:

```bash
xcodebuild test -project JARVIS.xcodeproj -scheme JARVIS -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:JARVISTests/BrainModelsTests \
  -only-testing:JARVISTests/BrainDatabaseTests \
  -only-testing:JARVISTests/SQLiteBrainStoreMemoryTests \
  -only-testing:JARVISTests/SQLiteBrainStoreGraphTests \
  -only-testing:JARVISTests/BrainServiceMigrationTests \
  -only-testing:JARVISTests/MemoryToolBrainTests \
  -only-testing:JARVISTests/MemoriesViewModelTests \
  -skipPackagePluginValidation -skipMacroValidation
```

Expected: all new tests pass.

- [ ] **Step 6: Run the existing regression suite and simulator build**

Run:

```bash
xcodebuild test -project JARVIS.xcodeproj -scheme JARVIS -destination 'platform=iOS Simulator,name=iPhone 16' -skipPackagePluginValidation -skipMacroValidation
xcodebuild build -project JARVIS.xcodeproj -scheme JARVIS -destination 'generic/platform=iOS Simulator' -skipPackagePluginValidation -skipMacroValidation
```

Expected: all existing tests remain green and the app builds.

If the project CI uses a different simulator/runtime, preserve CI as the authoritative build signal and record the local mismatch rather than weakening tests.

- [ ] **Step 7: Verify scope against `jarvis-dev`**

Run:

```bash
git diff --name-only origin/jarvis-dev...HEAD
```

Expected file set is limited to:

```text
JARVIS/Services/Brain/**
JARVIS/Services/NativeTools/MemoryTool.swift
JARVIS/Views/Settings/MemoriesView.swift
JARVIS/Views/Settings/MemoriesViewModel.swift
JARVIS/App/JARVISApp.swift
JARVIS/Managers/SettingsManager.swift   # only if legacy comment is needed
JARVISTests/Brain*.swift
JARVISTests/SQLiteBrainStore*.swift
JARVISTests/MemoryToolBrainTests.swift
JARVISTests/MemoriesViewModelTests.swift
project.yml
docs/superpowers/specs/2026-09-07-jarvis-brain-core-design.md
docs/superpowers/plans/2026-09-07-jarvis-brain-core.md
```

No audio, camera, Meta DAT, Gemini, OpenClaw, router, TTS, speaker-verification, or unrelated UI code belongs in this feature.

- [ ] **Step 8: Commit Task 8**

```bash
git add JARVIS/App/JARVISApp.swift JARVIS/Managers/SettingsManager.swift JARVISTests/BrainServiceMigrationTests.swift
git commit -m "feat(brain): initialize brain safely at app launch"
```

- [ ] **Step 9: Push feature branch and let CI validate before PR approval**

Push the implementation branch, open/update a PR targeting `jarvis-dev`, and wait for the repository's authoritative CI. Do not merge. Record:

```text
head commit SHA
CI run URL/ID
build/test result
artifact if produced
```

A physical iPhone smoke test is required before merge because the production Brain path/file-protection behavior cannot be fully proven by simulator tests. Minimum physical smoke test:

1. Install a build containing an existing legacy memory in `settings.json`.
2. Launch once and verify that memory appears in Memories UI.
3. Ask JARVIS to read/search that memory through `MemoryTool`.
4. Add a new memory by voice and confirm it appears in the UI.
5. Edit it in UI and confirm voice `get/search` sees the edited value.
6. Forget it by voice and confirm it disappears from active UI/list/search.
7. Relaunch and confirm no duplicate legacy memories were created.
8. Confirm unrelated voice/audio/camera functions still start normally.

The QA verdict for a green CI build without this device check is `PHYSICAL_TEST_REQUIRED`, not final `PASS`.

---

## Cross-Task Review Gates

After each task, an independent reviewer must inspect the task diff against both this plan and the spec before the next task starts. Reviewers must reject:

- direct SQL outside the Brain storage files;
- writes to `settings.json` as part of Brain canonical operations;
- any memory-content logging;
- name/alias as a person primary key;
- missing provenance on memory/fact/relation/alias/biometric writes;
- destructive overwrite of corrected facts;
- duplicate legacy import behavior;
- runtime changes outside the approved Brain/memory surfaces;
- new third-party database/vector dependencies;
- Obsidian/cloud/sync functionality sneaking into Phase 1.

## Definition of Done

Brain Core Phase 1 is ready for human merge approval only when all of the following are evidenced:

- schema v1 migrates cleanly and idempotently;
- existing memories import exactly once without changing `settings.json`;
- `MemoryTool` public actions keep working against SQLite canonical state;
- Memories UI and voice tool observe the same canonical data;
- UUID-based PersonProfile/entities/aliases are persisted;
- facts support explicit supersession without history loss;
- relations, provenance, LearningEvents, and opaque biometric references persist and query correctly;
- confidence/importance checks reject values outside `0...1`;
- forgotten memories disappear immediately from active APIs while preserving audit state;
- Brain unavailable state is controlled and does not crash unrelated app functionality;
- sensitive Brain values are absent from logs/telemetry;
- all new Brain tests pass;
- existing regression tests pass;
- authoritative CI is green;
- physical iPhone smoke test passes;
- PR targets `jarvis-dev` and remains unmerged pending explicit human approval.

## Self-Review Record

### Spec coverage

- Local-first SQLite canonical storage: Tasks 2–5.
- UUID entity/person identity: Tasks 1 and 4.
- Memory classes/lifecycle/confidence/importance: Tasks 1 and 3.
- Provenance: Tasks 3 and 4.
- Facts with supersession: Task 4.
- Relations: Task 4.
- LearningEvent persistence without automatic learning policy: Task 4.
- Person aliases and future-safe biometric refs: Task 4.
- Exactly-once legacy import and rollback-safe `settings.json`: Task 5 and Task 8.
- Existing MemoryTool compatibility: Task 6.
- Existing Memories UI canonicalization: Task 7.
- Concurrency serialization: `SQLiteBrainStore` actor in Task 3 plus `BrainService` actor in Task 5.
- Application Support/file protection: Task 2.
- Startup failure isolation: Task 8.
- No semantic retrieval/Obsidian/cloud scope creep: Global Constraints and review gates.
- Physical-device verification: Task 8.

### Placeholder scan

The plan contains no `TODO`, `TBD`, unspecified "handle errors" steps, or unnamed test requirements. Every task defines concrete files, interfaces, commands, expected behavior, and commit boundaries.

### Type consistency

The plan uses the same names across tasks: `BrainService`, `BrainStore`, `SQLiteBrainStore`, `BrainDatabaseLocation`, `BrainMemory`, `BrainFact`, `BrainRelation`, `PersonProfile`, `PersonAlias`, `BrainProvenanceInput`, `LearningEvent`, `BrainReadiness`, and `BrainLegacyKey`. Runtime adapters consume only the Task 5 `BrainService` API; they do not depend on SQLite internals.
