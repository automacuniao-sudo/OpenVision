import Foundation

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

    func readiness() -> BrainReadiness {
        state
    }

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

    func rememberLegacy(
        key: String,
        value: String,
        source: BrainProvenanceSource
    ) async throws -> BrainMemory {
        try requireReady()
        let normalizedKey = BrainLegacyKey.normalize(key)
        guard !normalizedKey.isEmpty else {
            throw BrainStoreError.invalidData("empty legacy key")
        }

        let now = Date()
        let provenance = BrainProvenanceInput(
            source: source,
            sourceIdentifier: nil,
            note: nil,
            timestamp: now
        )

        if let existing = try await store.memory(legacyKey: normalizedKey) {
            return try await store.updateMemoryContent(
                id: existing.id,
                content: value,
                at: now,
                provenance: provenance
            )
        }

        let memory = BrainMemory(
            id: UUID(),
            kind: .semantic,
            content: value,
            legacyKey: normalizedKey,
            subjectEntityId: nil,
            status: .active,
            confidence: 1.0,
            importance: 0.5,
            createdAt: now,
            updatedAt: now,
            lastConfirmedAt: now,
            expiresAt: nil
        )
        return try await store.createMemory(memory, provenance: provenance)
    }

    func memory(legacyKey: String) async throws -> BrainMemory? {
        try requireReady()
        return try await store.memory(legacyKey: legacyKey)
    }

    func searchActiveMemories(query: String, limit: Int) async throws -> [BrainMemory] {
        try requireReady()
        return try await store.searchMemories(query: query, statuses: [.active], limit: limit)
    }

    func listActiveMemories(limit: Int) async throws -> [BrainMemory] {
        try requireReady()
        return try await store.listMemories(statuses: [.active], limit: limit)
    }

    func updateMemoryContent(
        id: UUID,
        content: String,
        source: BrainProvenanceSource
    ) async throws -> BrainMemory {
        try requireReady()
        let now = Date()
        return try await store.updateMemoryContent(
            id: id,
            content: content,
            at: now,
            provenance: BrainProvenanceInput(
                source: source,
                sourceIdentifier: nil,
                note: nil,
                timestamp: now
            )
        )
    }

    func forgetMemory(id: UUID, source: BrainProvenanceSource) async throws -> Bool {
        try requireReady()
        let now = Date()
        return try await store.forgetMemory(
            id: id,
            at: now,
            provenance: BrainProvenanceInput(
                source: source,
                sourceIdentifier: nil,
                note: nil,
                timestamp: now
            )
        )
    }

    func forgetLegacy(key: String, source: BrainProvenanceSource) async throws -> Bool {
        try requireReady()
        guard let existing = try await store.memory(legacyKey: key) else { return false }
        return try await forgetMemory(id: existing.id, source: source)
    }

    func forgetMemories(
        matching query: String,
        source: BrainProvenanceSource
    ) async throws -> Int {
        try requireReady()
        let now = Date()
        return try await store.forgetMemories(
            matching: query,
            at: now,
            provenance: BrainProvenanceInput(
                source: source,
                sourceIdentifier: nil,
                note: nil,
                timestamp: now
            )
        )
    }

    func createEntity(_ entity: BrainEntity) async throws -> BrainEntity {
        try requireReady()
        return try await store.createEntity(entity)
    }

    func entity(id: UUID) async throws -> BrainEntity? {
        try requireReady()
        return try await store.entity(id: id)
    }

    func createPersonProfile(_ profile: PersonProfile, entity: BrainEntity) async throws -> PersonProfile {
        try requireReady()
        return try await store.createPersonProfile(profile, entity: entity)
    }

    func personProfile(id: UUID) async throws -> PersonProfile? {
        try requireReady()
        return try await store.personProfile(id: id)
    }

    func listPersonProfiles(limit: Int) async throws -> [PersonProfile] {
        try requireReady()
        return try await store.listPersonProfiles(limit: limit)
    }

    func addAlias(_ alias: PersonAlias, provenance: BrainProvenanceInput) async throws -> PersonAlias {
        try requireReady()
        return try await store.addAlias(alias, provenance: provenance)
    }

    func aliases(personId: UUID) async throws -> [PersonAlias] {
        try requireReady()
        return try await store.aliases(personId: personId)
    }

    func addBiometricReference(
        _ reference: BiometricReference,
        provenance: BrainProvenanceInput
    ) async throws -> BiometricReference {
        try requireReady()
        return try await store.addBiometricReference(reference, provenance: provenance)
    }

    func biometricReferences(personId: UUID) async throws -> [BiometricReference] {
        try requireReady()
        return try await store.biometricReferences(personId: personId)
    }

    func createFact(_ fact: BrainFact, provenance: BrainProvenanceInput) async throws -> BrainFact {
        try requireReady()
        return try await store.createFact(fact, provenance: provenance)
    }

    func facts(
        subjectEntityId: UUID?,
        statuses: Set<BrainRecordStatus>
    ) async throws -> [BrainFact] {
        try requireReady()
        return try await store.facts(subjectEntityId: subjectEntityId, statuses: statuses)
    }

    func supersedeFact(
        oldFactId: UUID,
        with newFact: BrainFact,
        at: Date,
        provenance: BrainProvenanceInput
    ) async throws -> BrainFact {
        try requireReady()
        return try await store.supersedeFact(
            oldFactId: oldFactId,
            with: newFact,
            at: at,
            provenance: provenance
        )
    }

    func createRelation(
        _ relation: BrainRelation,
        provenance: BrainProvenanceInput
    ) async throws -> BrainRelation {
        try requireReady()
        return try await store.createRelation(relation, provenance: provenance)
    }

    func relations(
        entityId: UUID,
        statuses: Set<BrainRecordStatus>
    ) async throws -> [BrainRelation] {
        try requireReady()
        return try await store.relations(entityId: entityId, statuses: statuses)
    }

    func appendLearningEvent(_ event: LearningEvent) async throws -> LearningEvent {
        try requireReady()
        return try await store.appendLearningEvent(event)
    }

    func learningEvents(targetRecordId: UUID?, limit: Int) async throws -> [LearningEvent] {
        try requireReady()
        return try await store.learningEvents(targetRecordId: targetRecordId, limit: limit)
    }

    private func requireReady() throws {
        guard state == .ready else {
            throw BrainStoreError.notInitialized
        }
    }
}
