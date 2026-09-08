import Foundation
import SQLite3

actor SQLiteBrainStore: BrainStore {
    private let location: BrainDatabaseLocation
    private var database: BrainDatabase?

    private static let memoryColumns = """
        id, kind, content, legacy_key, subject_entity_id, status,
        confidence, importance, created_at, updated_at, last_confirmed_at, expires_at
        """

    init(location: BrainDatabaseLocation = .applicationSupport) {
        self.location = location
    }

    func initialize() async throws {
        if database != nil { return }
        let db = try BrainDatabase(location: location)
        try BrainMigrations.migrate(db)
        database = db
    }

    func metadataValue(for key: String) async throws -> String? {
        let db = try requireDatabase()
        return try db.query(
            "SELECT value FROM brain_metadata WHERE key = ? LIMIT 1",
            bindings: [.text(key)]
        ) { statement in
            try Self.requiredText(statement, column: 0, field: "brain_metadata.value")
        }.first
    }

    func setMetadataValue(_ value: String, for key: String, at: Date) async throws {
        let db = try requireDatabase()
        try db.execute(
            """
            INSERT INTO brain_metadata(key, value, updated_at)
            VALUES (?, ?, ?)
            ON CONFLICT(key) DO UPDATE SET
                value = excluded.value,
                updated_at = excluded.updated_at
            """,
            bindings: [.text(key), .text(value), .double(at.timeIntervalSince1970)]
        )
    }

    func createMemory(
        _ memory: BrainMemory,
        provenance: BrainProvenanceInput
    ) async throws -> BrainMemory {
        let db = try requireDatabase()
        _ = try BrainValidation.unitInterval(memory.confidence, field: "confidence")
        _ = try BrainValidation.unitInterval(memory.importance, field: "importance")

        var stored = memory
        stored.legacyKey = try Self.normalizedLegacyKey(memory.legacyKey)
        let searchText = Self.searchText(legacyKey: stored.legacyKey, content: stored.content)

        try db.transaction {
            try db.execute(
                """
                INSERT INTO memories(
                    id, kind, content, legacy_key, search_text, subject_entity_id,
                    status, confidence, importance, created_at, updated_at,
                    last_confirmed_at, expires_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                bindings: [
                    .text(Self.uuid(stored.id)),
                    .text(stored.kind.rawValue),
                    .text(stored.content),
                    Self.optionalText(stored.legacyKey),
                    .text(searchText),
                    Self.optionalUUID(stored.subjectEntityId),
                    .text(stored.status.rawValue),
                    .double(stored.confidence),
                    .double(stored.importance),
                    .double(stored.createdAt.timeIntervalSince1970),
                    .double(stored.updatedAt.timeIntervalSince1970),
                    Self.optionalDate(stored.lastConfirmedAt),
                    Self.optionalDate(stored.expiresAt)
                ]
            )
            _ = try Self.insertProvenance(
                provenance,
                recordType: "memory",
                recordId: stored.id,
                db: db
            )
        }

        return stored
    }

    func updateMemoryContent(
        id: UUID,
        content: String,
        at: Date,
        provenance: BrainProvenanceInput
    ) async throws -> BrainMemory {
        let db = try requireDatabase()
        guard var stored = try Self.fetchMemory(id: id, db: db) else {
            throw BrainStoreError.notFound
        }

        stored.content = content
        stored.updatedAt = at
        let searchText = Self.searchText(legacyKey: stored.legacyKey, content: content)

        try db.transaction {
            try db.execute(
                """
                UPDATE memories
                SET content = ?, search_text = ?, updated_at = ?
                WHERE id = ?
                """,
                bindings: [
                    .text(content),
                    .text(searchText),
                    .double(at.timeIntervalSince1970),
                    .text(Self.uuid(id))
                ]
            )
            guard try db.scalarInt("SELECT changes()") == 1 else {
                throw BrainStoreError.notFound
            }
            _ = try Self.insertProvenance(
                provenance,
                recordType: "memory",
                recordId: id,
                db: db
            )
        }

        return stored
    }

    func memory(id: UUID) async throws -> BrainMemory? {
        let db = try requireDatabase()
        return try Self.fetchMemory(id: id, db: db)
    }

    func memory(legacyKey: String) async throws -> BrainMemory? {
        let db = try requireDatabase()
        let normalized = BrainLegacyKey.normalize(legacyKey)
        guard !normalized.isEmpty else { return nil }

        return try db.query(
            """
            SELECT \(Self.memoryColumns)
            FROM memories
            WHERE legacy_key = ? AND status IN ('candidate', 'active')
            ORDER BY updated_at DESC, id ASC
            LIMIT 1
            """,
            bindings: [.text(normalized)],
            mapRow: Self.decodeMemory
        ).first
    }

    func listMemories(
        statuses: Set<BrainRecordStatus>,
        limit: Int
    ) async throws -> [BrainMemory] {
        guard !statuses.isEmpty else { return [] }
        let db = try requireDatabase()
        let filter = Self.statusFilter(statuses)
        let safeLimit = max(1, min(limit, 500))

        return try db.query(
            """
            SELECT \(Self.memoryColumns)
            FROM memories
            WHERE status IN (\(filter.placeholders))
            ORDER BY updated_at DESC, id ASC
            LIMIT ?
            """,
            bindings: filter.bindings + [.int64(Int64(safeLimit))],
            mapRow: Self.decodeMemory
        )
    }

    func searchMemories(
        query: String,
        statuses: Set<BrainRecordStatus>,
        limit: Int
    ) async throws -> [BrainMemory] {
        guard !statuses.isEmpty else { return [] }
        let normalizedQuery = BrainLegacyKey.searchText(query)
        guard !normalizedQuery.isEmpty else { return [] }
        let likePattern = Self.likeSearchPattern(normalizedQuery)

        let db = try requireDatabase()
        let filter = Self.statusFilter(statuses)
        let safeLimit = max(1, min(limit, 500))

        return try db.query(
            """
            SELECT \(Self.memoryColumns)
            FROM memories
            WHERE status IN (\(filter.placeholders))
              AND search_text LIKE '%' || ? || '%'
            ORDER BY updated_at DESC, id ASC
            LIMIT ?
            """,
            bindings: filter.bindings + [
                .text(likePattern),
                .int64(Int64(safeLimit))
            ],
            mapRow: Self.decodeMemory
        )
    }

    func forgetMemory(
        id: UUID,
        at: Date,
        provenance: BrainProvenanceInput
    ) async throws -> Bool {
        let db = try requireDatabase()

        return try db.transaction {
            try db.execute(
                """
                UPDATE memories
                SET status = 'forgotten', updated_at = ?
                WHERE id = ? AND status IN ('candidate', 'active')
                """,
                bindings: [
                    .double(at.timeIntervalSince1970),
                    .text(Self.uuid(id))
                ]
            )
            guard try db.scalarInt("SELECT changes()") == 1 else {
                return false
            }
            _ = try Self.insertProvenance(
                provenance,
                recordType: "memory",
                recordId: id,
                db: db
            )
            return true
        }
    }

    func forgetMemories(
        matching query: String,
        at: Date,
        provenance: BrainProvenanceInput
    ) async throws -> Int {
        let normalizedQuery = BrainLegacyKey.searchText(query)
        guard !normalizedQuery.isEmpty else { return 0 }
        let likePattern = Self.likeSearchPattern(normalizedQuery)

        let db = try requireDatabase()
        let ids = try db.query(
            """
            SELECT id
            FROM memories
            WHERE status IN ('candidate', 'active')
              AND search_text LIKE '%' || ? || '%'
            ORDER BY updated_at DESC, id ASC
            """,
            bindings: [.text(likePattern)]
        ) { statement in
            let text = try Self.requiredText(statement, column: 0, field: "memories.id")
            guard let id = UUID(uuidString: text) else {
                throw BrainStoreError.invalidData("invalid memory id")
            }
            return id
        }

        guard !ids.isEmpty else { return 0 }

        return try db.transaction {
            var forgottenCount = 0
            for id in ids {
                try db.execute(
                    """
                    UPDATE memories
                    SET status = 'forgotten', updated_at = ?
                    WHERE id = ? AND status IN ('candidate', 'active')
                    """,
                    bindings: [
                        .double(at.timeIntervalSince1970),
                        .text(Self.uuid(id))
                    ]
                )
                if try db.scalarInt("SELECT changes()") == 1 {
                    _ = try Self.insertProvenance(
                        provenance,
                        recordType: "memory",
                        recordId: id,
                        db: db
                    )
                    forgottenCount += 1
                }
            }
            return forgottenCount
        }
    }

    // Task 5 owns exactly-once legacy import. Keeping this as an explicit stub prevents scope drift.
    func importLegacyMemories(_ memories: [String: String], at: Date) async throws -> Int {
        throw Self.notImplemented("importLegacyMemories")
    }

    // Task 4 owns graph/person/fact/relation/audit persistence. These stubs preserve the Task 2
    // BrainStore contract while ensuring future tests still begin RED for the intended reason.
    func createEntity(_ entity: BrainEntity) async throws -> BrainEntity {
        throw Self.notImplemented("createEntity")
    }

    func entity(id: UUID) async throws -> BrainEntity? {
        throw Self.notImplemented("entity")
    }

    func createPersonProfile(
        _ profile: PersonProfile,
        entity: BrainEntity
    ) async throws -> PersonProfile {
        throw Self.notImplemented("createPersonProfile")
    }

    func personProfile(id: UUID) async throws -> PersonProfile? {
        throw Self.notImplemented("personProfile")
    }

    func listPersonProfiles(limit: Int) async throws -> [PersonProfile] {
        throw Self.notImplemented("listPersonProfiles")
    }

    func addAlias(
        _ alias: PersonAlias,
        provenance: BrainProvenanceInput
    ) async throws -> PersonAlias {
        throw Self.notImplemented("addAlias")
    }

    func aliases(personId: UUID) async throws -> [PersonAlias] {
        throw Self.notImplemented("aliases")
    }

    func addBiometricReference(
        _ reference: BiometricReference,
        provenance: BrainProvenanceInput
    ) async throws -> BiometricReference {
        throw Self.notImplemented("addBiometricReference")
    }

    func biometricReferences(personId: UUID) async throws -> [BiometricReference] {
        throw Self.notImplemented("biometricReferences")
    }

    func createFact(
        _ fact: BrainFact,
        provenance: BrainProvenanceInput
    ) async throws -> BrainFact {
        throw Self.notImplemented("createFact")
    }

    func facts(
        subjectEntityId: UUID?,
        statuses: Set<BrainRecordStatus>
    ) async throws -> [BrainFact] {
        throw Self.notImplemented("facts")
    }

    func supersedeFact(
        oldFactId: UUID,
        with newFact: BrainFact,
        at: Date,
        provenance: BrainProvenanceInput
    ) async throws -> BrainFact {
        throw Self.notImplemented("supersedeFact")
    }

    func createRelation(
        _ relation: BrainRelation,
        provenance: BrainProvenanceInput
    ) async throws -> BrainRelation {
        throw Self.notImplemented("createRelation")
    }

    func relations(
        entityId: UUID,
        statuses: Set<BrainRecordStatus>
    ) async throws -> [BrainRelation] {
        throw Self.notImplemented("relations")
    }

    func appendLearningEvent(_ event: LearningEvent) async throws -> LearningEvent {
        throw Self.notImplemented("appendLearningEvent")
    }

    func learningEvents(targetRecordId: UUID?, limit: Int) async throws -> [LearningEvent] {
        throw Self.notImplemented("learningEvents")
    }

    private func requireDatabase() throws -> BrainDatabase {
        guard let database else {
            throw BrainStoreError.notInitialized
        }
        return database
    }

    private static func fetchMemory(id: UUID, db: BrainDatabase) throws -> BrainMemory? {
        try db.query(
            """
            SELECT \(memoryColumns)
            FROM memories
            WHERE id = ?
            LIMIT 1
            """,
            bindings: [.text(uuid(id))],
            mapRow: decodeMemory
        ).first
    }

    private static func insertProvenance(
        _ input: BrainProvenanceInput,
        recordType: String,
        recordId: UUID,
        db: BrainDatabase
    ) throws -> UUID {
        let provenanceId = UUID()
        try db.execute(
            """
            INSERT INTO provenance(id, source, source_identifier, note, timestamp)
            VALUES (?, ?, ?, ?, ?)
            """,
            bindings: [
                .text(uuid(provenanceId)),
                .text(input.source.rawValue),
                optionalText(input.sourceIdentifier),
                optionalText(input.note),
                .double(input.timestamp.timeIntervalSince1970)
            ]
        )
        try db.execute(
            """
            INSERT INTO record_provenance(record_type, record_id, provenance_id)
            VALUES (?, ?, ?)
            """,
            bindings: [
                .text(recordType),
                .text(uuid(recordId)),
                .text(uuid(provenanceId))
            ]
        )
        return provenanceId
    }

    private static func decodeMemory(_ statement: OpaquePointer) throws -> BrainMemory {
        let idText = try requiredText(statement, column: 0, field: "memories.id")
        let kindText = try requiredText(statement, column: 1, field: "memories.kind")
        let content = try requiredText(statement, column: 2, field: "memories.content")
        let legacyKey = optionalText(statement, column: 3)
        let subjectIdText = optionalText(statement, column: 4)
        let statusText = try requiredText(statement, column: 5, field: "memories.status")

        guard let id = UUID(uuidString: idText) else {
            throw BrainStoreError.invalidData("invalid memory id")
        }
        guard let kind = BrainMemoryKind(rawValue: kindText) else {
            throw BrainStoreError.invalidData("invalid memory kind")
        }
        guard let status = BrainRecordStatus(rawValue: statusText) else {
            throw BrainStoreError.invalidData("invalid memory status")
        }

        let subjectEntityId: UUID?
        if let subjectIdText {
            guard let parsed = UUID(uuidString: subjectIdText) else {
                throw BrainStoreError.invalidData("invalid memory subject id")
            }
            subjectEntityId = parsed
        } else {
            subjectEntityId = nil
        }

        return BrainMemory(
            id: id,
            kind: kind,
            content: content,
            legacyKey: legacyKey,
            subjectEntityId: subjectEntityId,
            status: status,
            confidence: sqlite3_column_double(statement, 6),
            importance: sqlite3_column_double(statement, 7),
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 8)),
            updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 9)),
            lastConfirmedAt: optionalDate(statement, column: 10),
            expiresAt: optionalDate(statement, column: 11)
        )
    }

    private static func normalizedLegacyKey(_ legacyKey: String?) throws -> String? {
        guard let legacyKey else { return nil }
        let normalized = BrainLegacyKey.normalize(legacyKey)
        guard !normalized.isEmpty else {
            throw BrainStoreError.invalidData("empty legacy key")
        }
        return normalized
    }

    private static func searchText(legacyKey: String?, content: String) -> String {
        BrainLegacyKey.searchText([legacyKey, content].compactMap { $0 }.joined(separator: " "))
    }

    private static func likeSearchPattern(_ normalizedQuery: String) -> String {
        normalizedQuery
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .joined(separator: "%")
    }

    private static func statusFilter(
        _ statuses: Set<BrainRecordStatus>
    ) -> (placeholders: String, bindings: [SQLiteBinding]) {
        let values = statuses.map(\.rawValue).sorted()
        let placeholders = Array(repeating: "?", count: values.count).joined(separator: ", ")
        return (placeholders, values.map { SQLiteBinding.text($0) })
    }

    private static func uuid(_ id: UUID) -> String {
        id.uuidString.lowercased()
    }

    private static func optionalUUID(_ id: UUID?) -> SQLiteBinding {
        id.map { .text(uuid($0)) } ?? .null
    }

    private static func optionalText(_ value: String?) -> SQLiteBinding {
        value.map(SQLiteBinding.text) ?? .null
    }

    private static func optionalDate(_ value: Date?) -> SQLiteBinding {
        value.map { .double($0.timeIntervalSince1970) } ?? .null
    }

    private static func requiredText(
        _ statement: OpaquePointer,
        column: Int32,
        field: String
    ) throws -> String {
        guard let text = sqlite3_column_text(statement, column) else {
            throw BrainStoreError.invalidData("missing \(field)")
        }
        return String(cString: text)
    }

    private static func optionalText(_ statement: OpaquePointer, column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL,
              let text = sqlite3_column_text(statement, column) else {
            return nil
        }
        return String(cString: text)
    }

    private static func optionalDate(_ statement: OpaquePointer, column: Int32) -> Date? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else {
            return nil
        }
        return Date(timeIntervalSince1970: sqlite3_column_double(statement, column))
    }

    private static func notImplemented(_ operation: String) -> BrainStoreError {
        .invalidData("\(operation) is not implemented in this task")
    }
}
