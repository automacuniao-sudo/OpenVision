import Foundation
import SQLite3

actor SQLiteBrainStore: BrainStore {
    private let location: BrainDatabaseLocation
    private var database: BrainDatabase?

    private static let memoryColumns = """
        id, kind, content, legacy_key, subject_entity_id, status,
        confidence, importance, created_at, updated_at, last_confirmed_at, expires_at
        """
    private static let entityColumns = "id, type, display_name, status, created_at, updated_at"
    private static let personColumns = """
        e.id, e.display_name, e.created_at, e.updated_at,
        p.first_seen_at, p.last_seen_at, e.status, p.confidence
        """
    private static let aliasColumns = """
        id, person_id, alias, normalized_alias, confidence, created_at, updated_at
        """
    private static let biometricColumns = """
        id, person_id, kind, storage_reference, quality, created_at, updated_at
        """
    private static let factColumns = """
        id, subject_entity_id, predicate, value, status, confidence,
        created_at, updated_at, last_confirmed_at, supersedes_fact_id
        """
    private static let relationColumns = """
        id, source_entity_id, relation_type, target_entity_id, status,
        confidence, created_at, updated_at
        """
    private static let learningEventColumns = """
        id, event_type, target_record_type, target_record_id, source,
        timestamp, before_summary, after_summary, reversible
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

    // Task 5 owns exactly-once legacy import.
    func importLegacyMemories(_ memories: [String: String], at: Date) async throws -> Int {
        throw Self.notImplemented("importLegacyMemories")
    }

    func createEntity(_ entity: BrainEntity) async throws -> BrainEntity {
        let db = try requireDatabase()
        try Self.insertEntity(entity, db: db)
        return entity
    }

    func entity(id: UUID) async throws -> BrainEntity? {
        let db = try requireDatabase()
        return try db.query(
            "SELECT \(Self.entityColumns) FROM entities WHERE id = ? LIMIT 1",
            bindings: [.text(Self.uuid(id))],
            mapRow: Self.decodeEntity
        ).first
    }

    func createPersonProfile(
        _ profile: PersonProfile,
        entity: BrainEntity
    ) async throws -> PersonProfile {
        guard profile.id == entity.id else {
            throw BrainStoreError.invalidData("person profile/entity id mismatch")
        }
        guard entity.type == .person else {
            throw BrainStoreError.invalidData("person profile requires person entity")
        }
        _ = try BrainValidation.unitInterval(profile.confidence, field: "confidence")

        let db = try requireDatabase()
        try db.transaction {
            try Self.insertEntity(entity, db: db)
            try db.execute(
                """
                INSERT INTO person_profiles(entity_id, first_seen_at, last_seen_at, confidence)
                VALUES (?, ?, ?, ?)
                """,
                bindings: [
                    .text(Self.uuid(profile.id)),
                    Self.optionalDate(profile.firstSeenAt),
                    Self.optionalDate(profile.lastSeenAt),
                    .double(profile.confidence)
                ]
            )
        }

        return PersonProfile(
            id: entity.id,
            displayName: entity.displayName,
            createdAt: entity.createdAt,
            updatedAt: entity.updatedAt,
            firstSeenAt: profile.firstSeenAt,
            lastSeenAt: profile.lastSeenAt,
            status: entity.status,
            confidence: profile.confidence
        )
    }

    func personProfile(id: UUID) async throws -> PersonProfile? {
        let db = try requireDatabase()
        return try db.query(
            """
            SELECT \(Self.personColumns)
            FROM person_profiles p
            JOIN entities e ON e.id = p.entity_id
            WHERE p.entity_id = ?
            LIMIT 1
            """,
            bindings: [.text(Self.uuid(id))],
            mapRow: Self.decodePersonProfile
        ).first
    }

    func listPersonProfiles(limit: Int) async throws -> [PersonProfile] {
        let db = try requireDatabase()
        let safeLimit = max(1, min(limit, 500))
        return try db.query(
            """
            SELECT \(Self.personColumns)
            FROM person_profiles p
            JOIN entities e ON e.id = p.entity_id
            ORDER BY e.updated_at DESC, e.id ASC
            LIMIT ?
            """,
            bindings: [.int64(Int64(safeLimit))],
            mapRow: Self.decodePersonProfile
        )
    }

    func addAlias(
        _ alias: PersonAlias,
        provenance: BrainProvenanceInput
    ) async throws -> PersonAlias {
        _ = try BrainValidation.unitInterval(alias.confidence, field: "confidence")
        var stored = alias
        stored.normalizedAlias = BrainLegacyKey.searchText(alias.alias)

        let db = try requireDatabase()
        try db.transaction {
            try db.execute(
                """
                INSERT INTO person_aliases(
                    id, person_id, alias, normalized_alias, confidence, created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                bindings: [
                    .text(Self.uuid(stored.id)),
                    .text(Self.uuid(stored.personId)),
                    .text(stored.alias),
                    .text(stored.normalizedAlias),
                    .double(stored.confidence),
                    .double(stored.createdAt.timeIntervalSince1970),
                    .double(stored.updatedAt.timeIntervalSince1970)
                ]
            )
            _ = try Self.insertProvenance(
                provenance,
                recordType: "person_alias",
                recordId: stored.id,
                db: db
            )
        }
        return stored
    }

    func aliases(personId: UUID) async throws -> [PersonAlias] {
        let db = try requireDatabase()
        return try db.query(
            """
            SELECT \(Self.aliasColumns)
            FROM person_aliases
            WHERE person_id = ?
            ORDER BY updated_at DESC, id ASC
            """,
            bindings: [.text(Self.uuid(personId))],
            mapRow: Self.decodeAlias
        )
    }

    func addBiometricReference(
        _ reference: BiometricReference,
        provenance: BrainProvenanceInput
    ) async throws -> BiometricReference {
        if let quality = reference.quality {
            _ = try BrainValidation.unitInterval(quality, field: "quality")
        }

        let db = try requireDatabase()
        try db.transaction {
            try db.execute(
                """
                INSERT INTO biometric_refs(
                    id, person_id, kind, storage_reference, quality, created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                bindings: [
                    .text(Self.uuid(reference.id)),
                    .text(Self.uuid(reference.personId)),
                    .text(reference.kind.rawValue),
                    .text(reference.storageReference),
                    Self.optionalDouble(reference.quality),
                    .double(reference.createdAt.timeIntervalSince1970),
                    .double(reference.updatedAt.timeIntervalSince1970)
                ]
            )
            _ = try Self.insertProvenance(
                provenance,
                recordType: "biometric_ref",
                recordId: reference.id,
                db: db
            )
        }
        return reference
    }

    func biometricReferences(personId: UUID) async throws -> [BiometricReference] {
        let db = try requireDatabase()
        return try db.query(
            """
            SELECT \(Self.biometricColumns)
            FROM biometric_refs
            WHERE person_id = ?
            ORDER BY updated_at DESC, id ASC
            """,
            bindings: [.text(Self.uuid(personId))],
            mapRow: Self.decodeBiometricReference
        )
    }

    func createFact(
        _ fact: BrainFact,
        provenance: BrainProvenanceInput
    ) async throws -> BrainFact {
        _ = try BrainValidation.unitInterval(fact.confidence, field: "confidence")
        let db = try requireDatabase()
        try db.transaction {
            try Self.insertFact(fact, db: db)
            _ = try Self.insertProvenance(
                provenance,
                recordType: "fact",
                recordId: fact.id,
                db: db
            )
        }
        return fact
    }

    func facts(
        subjectEntityId: UUID?,
        statuses: Set<BrainRecordStatus>
    ) async throws -> [BrainFact] {
        guard !statuses.isEmpty else { return [] }
        let db = try requireDatabase()
        let filter = Self.statusFilter(statuses)

        if let subjectEntityId {
            return try db.query(
                """
                SELECT \(Self.factColumns)
                FROM facts
                WHERE subject_entity_id = ? AND status IN (\(filter.placeholders))
                ORDER BY updated_at DESC, id ASC
                """,
                bindings: [.text(Self.uuid(subjectEntityId))] + filter.bindings,
                mapRow: Self.decodeFact
            )
        }

        return try db.query(
            """
            SELECT \(Self.factColumns)
            FROM facts
            WHERE status IN (\(filter.placeholders))
            ORDER BY updated_at DESC, id ASC
            """,
            bindings: filter.bindings,
            mapRow: Self.decodeFact
        )
    }

    func supersedeFact(
        oldFactId: UUID,
        with newFact: BrainFact,
        at: Date,
        provenance: BrainProvenanceInput
    ) async throws -> BrainFact {
        _ = try BrainValidation.unitInterval(newFact.confidence, field: "confidence")
        let db = try requireDatabase()
        var stored = newFact
        stored.status = .active
        stored.supersedesFactId = oldFactId

        return try db.transaction {
            guard let old = try Self.fetchFact(id: oldFactId, db: db),
                  old.status == .active || old.status == .candidate else {
                throw BrainStoreError.notFound
            }

            try db.execute(
                """
                UPDATE facts
                SET status = 'superseded', updated_at = ?
                WHERE id = ? AND status IN ('candidate', 'active')
                """,
                bindings: [
                    .double(at.timeIntervalSince1970),
                    .text(Self.uuid(oldFactId))
                ]
            )
            guard try db.scalarInt("SELECT changes()") == 1 else {
                throw BrainStoreError.notFound
            }

            try Self.insertFact(stored, db: db)
            _ = try Self.insertProvenance(
                provenance,
                recordType: "fact",
                recordId: stored.id,
                db: db
            )
            return stored
        }
    }

    func createRelation(
        _ relation: BrainRelation,
        provenance: BrainProvenanceInput
    ) async throws -> BrainRelation {
        _ = try BrainValidation.unitInterval(relation.confidence, field: "confidence")
        let db = try requireDatabase()
        try db.transaction {
            try db.execute(
                """
                INSERT INTO relations(
                    id, source_entity_id, relation_type, target_entity_id,
                    status, confidence, created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
                bindings: [
                    .text(Self.uuid(relation.id)),
                    .text(Self.uuid(relation.sourceEntityId)),
                    .text(relation.relationType),
                    .text(Self.uuid(relation.targetEntityId)),
                    .text(relation.status.rawValue),
                    .double(relation.confidence),
                    .double(relation.createdAt.timeIntervalSince1970),
                    .double(relation.updatedAt.timeIntervalSince1970)
                ]
            )
            _ = try Self.insertProvenance(
                provenance,
                recordType: "relation",
                recordId: relation.id,
                db: db
            )
        }
        return relation
    }

    func relations(
        entityId: UUID,
        statuses: Set<BrainRecordStatus>
    ) async throws -> [BrainRelation] {
        guard !statuses.isEmpty else { return [] }
        let db = try requireDatabase()
        let filter = Self.statusFilter(statuses)
        return try db.query(
            """
            SELECT \(Self.relationColumns)
            FROM relations
            WHERE (source_entity_id = ? OR target_entity_id = ?)
              AND status IN (\(filter.placeholders))
            ORDER BY updated_at DESC, id ASC
            """,
            bindings: [
                .text(Self.uuid(entityId)),
                .text(Self.uuid(entityId))
            ] + filter.bindings,
            mapRow: Self.decodeRelation
        )
    }

    func appendLearningEvent(_ event: LearningEvent) async throws -> LearningEvent {
        let db = try requireDatabase()
        try db.execute(
            """
            INSERT INTO learning_events(
                id, event_type, target_record_type, target_record_id, source,
                timestamp, before_summary, after_summary, reversible
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            bindings: [
                .text(Self.uuid(event.id)),
                .text(event.type.rawValue),
                Self.optionalText(event.targetRecordType),
                Self.optionalUUID(event.targetRecordId),
                .text(event.source.rawValue),
                .double(event.timestamp.timeIntervalSince1970),
                Self.optionalText(event.beforeSummary),
                Self.optionalText(event.afterSummary),
                .int64(event.reversible ? 1 : 0)
            ]
        )
        return event
    }

    func learningEvents(targetRecordId: UUID?, limit: Int) async throws -> [LearningEvent] {
        let db = try requireDatabase()
        let safeLimit = max(1, min(limit, 500))

        if let targetRecordId {
            return try db.query(
                """
                SELECT \(Self.learningEventColumns)
                FROM learning_events
                WHERE target_record_id = ?
                ORDER BY timestamp DESC, id ASC
                LIMIT ?
                """,
                bindings: [
                    .text(Self.uuid(targetRecordId)),
                    .int64(Int64(safeLimit))
                ],
                mapRow: Self.decodeLearningEvent
            )
        }

        return try db.query(
            """
            SELECT \(Self.learningEventColumns)
            FROM learning_events
            ORDER BY timestamp DESC, id ASC
            LIMIT ?
            """,
            bindings: [.int64(Int64(safeLimit))],
            mapRow: Self.decodeLearningEvent
        )
    }

    private func requireDatabase() throws -> BrainDatabase {
        guard let database else {
            throw BrainStoreError.notInitialized
        }
        return database
    }

    private static func insertEntity(_ entity: BrainEntity, db: BrainDatabase) throws {
        try db.execute(
            """
            INSERT INTO entities(id, type, display_name, status, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?)
            """,
            bindings: [
                .text(uuid(entity.id)),
                .text(entity.type.rawValue),
                optionalText(entity.displayName),
                .text(entity.status.rawValue),
                .double(entity.createdAt.timeIntervalSince1970),
                .double(entity.updatedAt.timeIntervalSince1970)
            ]
        )
    }

    private static func insertFact(_ fact: BrainFact, db: BrainDatabase) throws {
        try db.execute(
            """
            INSERT INTO facts(
                id, subject_entity_id, predicate, value, status, confidence,
                created_at, updated_at, last_confirmed_at, supersedes_fact_id
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            bindings: [
                .text(uuid(fact.id)),
                optionalUUID(fact.subjectEntityId),
                .text(fact.predicate),
                .text(fact.value),
                .text(fact.status.rawValue),
                .double(fact.confidence),
                .double(fact.createdAt.timeIntervalSince1970),
                .double(fact.updatedAt.timeIntervalSince1970),
                optionalDate(fact.lastConfirmedAt),
                optionalUUID(fact.supersedesFactId)
            ]
        )
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

    private static func fetchFact(id: UUID, db: BrainDatabase) throws -> BrainFact? {
        try db.query(
            """
            SELECT \(factColumns)
            FROM facts
            WHERE id = ?
            LIMIT 1
            """,
            bindings: [.text(uuid(id))],
            mapRow: decodeFact
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
        let id = try requiredUUID(statement, column: 0, field: "memories.id")
        let kindText = try requiredText(statement, column: 1, field: "memories.kind")
        let content = try requiredText(statement, column: 2, field: "memories.content")
        let legacyKey = optionalText(statement, column: 3)
        let subjectEntityId = try optionalUUID(statement, column: 4, field: "memories.subject_entity_id")
        let statusText = try requiredText(statement, column: 5, field: "memories.status")

        guard let kind = BrainMemoryKind(rawValue: kindText) else {
            throw BrainStoreError.invalidData("invalid memory kind")
        }
        guard let status = BrainRecordStatus(rawValue: statusText) else {
            throw BrainStoreError.invalidData("invalid memory status")
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

    private static func decodeEntity(_ statement: OpaquePointer) throws -> BrainEntity {
        let id = try requiredUUID(statement, column: 0, field: "entities.id")
        let typeText = try requiredText(statement, column: 1, field: "entities.type")
        let statusText = try requiredText(statement, column: 3, field: "entities.status")
        guard let type = BrainEntityType(rawValue: typeText) else {
            throw BrainStoreError.invalidData("invalid entity type")
        }
        guard let status = BrainRecordStatus(rawValue: statusText) else {
            throw BrainStoreError.invalidData("invalid entity status")
        }
        return BrainEntity(
            id: id,
            type: type,
            displayName: optionalText(statement, column: 2),
            status: status,
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4)),
            updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5))
        )
    }

    private static func decodePersonProfile(_ statement: OpaquePointer) throws -> PersonProfile {
        let id = try requiredUUID(statement, column: 0, field: "person_profiles.entity_id")
        let statusText = try requiredText(statement, column: 6, field: "entities.status")
        guard let status = BrainRecordStatus(rawValue: statusText) else {
            throw BrainStoreError.invalidData("invalid person status")
        }
        return PersonProfile(
            id: id,
            displayName: optionalText(statement, column: 1),
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
            updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)),
            firstSeenAt: optionalDate(statement, column: 4),
            lastSeenAt: optionalDate(statement, column: 5),
            status: status,
            confidence: sqlite3_column_double(statement, 7)
        )
    }

    private static func decodeAlias(_ statement: OpaquePointer) throws -> PersonAlias {
        PersonAlias(
            id: try requiredUUID(statement, column: 0, field: "person_aliases.id"),
            personId: try requiredUUID(statement, column: 1, field: "person_aliases.person_id"),
            alias: try requiredText(statement, column: 2, field: "person_aliases.alias"),
            normalizedAlias: try requiredText(statement, column: 3, field: "person_aliases.normalized_alias"),
            confidence: sqlite3_column_double(statement, 4),
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5)),
            updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 6))
        )
    }

    private static func decodeBiometricReference(_ statement: OpaquePointer) throws -> BiometricReference {
        let kindText = try requiredText(statement, column: 2, field: "biometric_refs.kind")
        guard let kind = BiometricKind(rawValue: kindText) else {
            throw BrainStoreError.invalidData("invalid biometric kind")
        }
        return BiometricReference(
            id: try requiredUUID(statement, column: 0, field: "biometric_refs.id"),
            personId: try requiredUUID(statement, column: 1, field: "biometric_refs.person_id"),
            kind: kind,
            storageReference: try requiredText(statement, column: 3, field: "biometric_refs.storage_reference"),
            quality: optionalDouble(statement, column: 4),
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5)),
            updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 6))
        )
    }

    private static func decodeFact(_ statement: OpaquePointer) throws -> BrainFact {
        let statusText = try requiredText(statement, column: 4, field: "facts.status")
        guard let status = BrainRecordStatus(rawValue: statusText) else {
            throw BrainStoreError.invalidData("invalid fact status")
        }
        return BrainFact(
            id: try requiredUUID(statement, column: 0, field: "facts.id"),
            subjectEntityId: try optionalUUID(statement, column: 1, field: "facts.subject_entity_id"),
            predicate: try requiredText(statement, column: 2, field: "facts.predicate"),
            value: try requiredText(statement, column: 3, field: "facts.value"),
            status: status,
            confidence: sqlite3_column_double(statement, 5),
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 6)),
            updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 7)),
            lastConfirmedAt: optionalDate(statement, column: 8),
            supersedesFactId: try optionalUUID(statement, column: 9, field: "facts.supersedes_fact_id")
        )
    }

    private static func decodeRelation(_ statement: OpaquePointer) throws -> BrainRelation {
        let statusText = try requiredText(statement, column: 4, field: "relations.status")
        guard let status = BrainRecordStatus(rawValue: statusText) else {
            throw BrainStoreError.invalidData("invalid relation status")
        }
        return BrainRelation(
            id: try requiredUUID(statement, column: 0, field: "relations.id"),
            sourceEntityId: try requiredUUID(statement, column: 1, field: "relations.source_entity_id"),
            relationType: try requiredText(statement, column: 2, field: "relations.relation_type"),
            targetEntityId: try requiredUUID(statement, column: 3, field: "relations.target_entity_id"),
            status: status,
            confidence: sqlite3_column_double(statement, 5),
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 6)),
            updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 7))
        )
    }

    private static func decodeLearningEvent(_ statement: OpaquePointer) throws -> LearningEvent {
        let typeText = try requiredText(statement, column: 1, field: "learning_events.event_type")
        let sourceText = try requiredText(statement, column: 4, field: "learning_events.source")
        guard let type = LearningEventType(rawValue: typeText) else {
            throw BrainStoreError.invalidData("invalid learning event type")
        }
        guard let source = BrainProvenanceSource(rawValue: sourceText) else {
            throw BrainStoreError.invalidData("invalid learning event source")
        }
        return LearningEvent(
            id: try requiredUUID(statement, column: 0, field: "learning_events.id"),
            type: type,
            targetRecordType: optionalText(statement, column: 2),
            targetRecordId: try optionalUUID(statement, column: 3, field: "learning_events.target_record_id"),
            source: source,
            timestamp: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5)),
            beforeSummary: optionalText(statement, column: 6),
            afterSummary: optionalText(statement, column: 7),
            reversible: sqlite3_column_int64(statement, 8) != 0
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

    private static func optionalDouble(_ value: Double?) -> SQLiteBinding {
        value.map(SQLiteBinding.double) ?? .null
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

    private static func requiredUUID(
        _ statement: OpaquePointer,
        column: Int32,
        field: String
    ) throws -> UUID {
        let text = try requiredText(statement, column: column, field: field)
        guard let id = UUID(uuidString: text) else {
            throw BrainStoreError.invalidData("invalid \(field)")
        }
        return id
    }

    private static func optionalUUID(
        _ statement: OpaquePointer,
        column: Int32,
        field: String
    ) throws -> UUID? {
        guard let text = optionalText(statement, column: column) else { return nil }
        guard let id = UUID(uuidString: text) else {
            throw BrainStoreError.invalidData("invalid \(field)")
        }
        return id
    }

    private static func optionalDate(_ statement: OpaquePointer, column: Int32) -> Date? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else {
            return nil
        }
        return Date(timeIntervalSince1970: sqlite3_column_double(statement, column))
    }

    private static func optionalDouble(_ statement: OpaquePointer, column: Int32) -> Double? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else {
            return nil
        }
        return sqlite3_column_double(statement, column)
    }

    private static func notImplemented(_ operation: String) -> BrainStoreError {
        .invalidData("\(operation) is not implemented in this task")
    }
}
