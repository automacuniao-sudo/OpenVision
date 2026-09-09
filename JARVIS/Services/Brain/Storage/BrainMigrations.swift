import Foundation

enum BrainMigrations {
    static let currentVersion: Int32 = 1

    static func migrate(_ database: BrainDatabase) throws {
        let foundVersion = try database.userVersion()

        guard foundVersion <= currentVersion else {
            throw BrainStoreError.migrationUnsupported(
                found: foundVersion,
                supported: currentVersion
            )
        }

        guard foundVersion < currentVersion else {
            return
        }

        if foundVersion == 0 {
            try database.transaction {
                for statement in schemaV1 {
                    try database.execute(statement)
                }
                try database.execute("PRAGMA user_version = 1")
            }
        }
    }

    private static let schemaV1: [String] = [
        """
        CREATE TABLE brain_metadata (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL,
            updated_at REAL NOT NULL
        )
        """,
        """
        CREATE TABLE entities (
            id TEXT PRIMARY KEY,
            type TEXT NOT NULL,
            display_name TEXT,
            status TEXT NOT NULL,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL
        )
        """,
        """
        CREATE TABLE person_profiles (
            entity_id TEXT PRIMARY KEY REFERENCES entities(id),
            first_seen_at REAL,
            last_seen_at REAL,
            confidence REAL NOT NULL CHECK(confidence >= 0.0 AND confidence <= 1.0)
        )
        """,
        """
        CREATE TABLE person_aliases (
            id TEXT PRIMARY KEY,
            person_id TEXT NOT NULL REFERENCES person_profiles(entity_id),
            alias TEXT NOT NULL,
            normalized_alias TEXT NOT NULL,
            confidence REAL NOT NULL CHECK(confidence >= 0.0 AND confidence <= 1.0),
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL
        )
        """,
        "CREATE INDEX idx_person_aliases_normalized ON person_aliases(normalized_alias)",
        """
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
        )
        """,
        """
        CREATE UNIQUE INDEX idx_memories_legacy_key_active
        ON memories(legacy_key)
        WHERE legacy_key IS NOT NULL AND status IN ('candidate','active')
        """,
        "CREATE INDEX idx_memories_status_updated ON memories(status, updated_at DESC)",
        "CREATE INDEX idx_memories_subject ON memories(subject_entity_id)",
        "CREATE INDEX idx_memories_search ON memories(search_text)",
        """
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
        )
        """,
        "CREATE INDEX idx_facts_subject_status ON facts(subject_entity_id, status)",
        """
        CREATE TABLE relations (
            id TEXT PRIMARY KEY,
            source_entity_id TEXT NOT NULL REFERENCES entities(id),
            relation_type TEXT NOT NULL,
            target_entity_id TEXT NOT NULL REFERENCES entities(id),
            status TEXT NOT NULL,
            confidence REAL NOT NULL CHECK(confidence >= 0.0 AND confidence <= 1.0),
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL
        )
        """,
        "CREATE INDEX idx_relations_source ON relations(source_entity_id, status)",
        "CREATE INDEX idx_relations_target ON relations(target_entity_id, status)",
        """
        CREATE TABLE provenance (
            id TEXT PRIMARY KEY,
            source TEXT NOT NULL,
            source_identifier TEXT,
            note TEXT,
            timestamp REAL NOT NULL
        )
        """,
        """
        CREATE TABLE record_provenance (
            record_type TEXT NOT NULL,
            record_id TEXT NOT NULL,
            provenance_id TEXT NOT NULL REFERENCES provenance(id),
            PRIMARY KEY(record_type, record_id, provenance_id)
        )
        """,
        "CREATE INDEX idx_record_provenance_record ON record_provenance(record_type, record_id)",
        """
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
        )
        """,
        "CREATE INDEX idx_learning_events_target ON learning_events(target_record_type, target_record_id, timestamp DESC)",
        """
        CREATE TABLE biometric_refs (
            id TEXT PRIMARY KEY,
            person_id TEXT NOT NULL REFERENCES person_profiles(entity_id),
            kind TEXT NOT NULL,
            storage_reference TEXT NOT NULL,
            quality REAL CHECK(quality IS NULL OR (quality >= 0.0 AND quality <= 1.0)),
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL
        )
        """
    ]
}
