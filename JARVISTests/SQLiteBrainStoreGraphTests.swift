import XCTest
#if !JARVIS_PURE_TESTS
@testable import JARVIS
#endif

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
        let entity = BrainEntity(
            id: id,
            type: .person,
            displayName: "João",
            status: .active,
            createdAt: now,
            updatedAt: now
        )
        let profile = PersonProfile(
            id: id,
            displayName: "João",
            createdAt: now,
            updatedAt: now,
            firstSeenAt: now,
            lastSeenAt: now,
            status: .active,
            confidence: 1
        )

        _ = try await store.createPersonProfile(profile, entity: entity)
        _ = try await store.addAlias(
            .init(
                id: UUID(),
                personId: id,
                alias: "João",
                normalizedAlias: "joao",
                confidence: 1,
                createdAt: now,
                updatedAt: now
            ),
            provenance: .init(
                source: .explicitUser,
                sourceIdentifier: nil,
                note: nil,
                timestamp: now
            )
        )
        _ = try await store.addAlias(
            .init(
                id: UUID(),
                personId: id,
                alias: "João do Financeiro",
                normalizedAlias: "joao do financeiro",
                confidence: 1,
                createdAt: now,
                updatedAt: now
            ),
            provenance: .init(
                source: .explicitUser,
                sourceIdentifier: nil,
                note: nil,
                timestamp: now
            )
        )

        let aliases = try await store.aliases(personId: id)
        let storedProfile = try await store.personProfile(id: id)
        XCTAssertEqual(aliases.count, 2)
        XCTAssertEqual(storedProfile?.id, id)
    }

    func testSupersedeFactKeepsOldHistoryAndActivatesNewFact() async throws {
        let store = try await makeStore()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let personId = UUID()
        let entity = BrainEntity(
            id: personId,
            type: .person,
            displayName: "João",
            status: .active,
            createdAt: now,
            updatedAt: now
        )
        _ = try await store.createEntity(entity)

        let old = BrainFact(
            id: UUID(),
            subjectEntityId: personId,
            predicate: "department",
            value: "TI",
            status: .active,
            confidence: 1,
            createdAt: now,
            updatedAt: now,
            lastConfirmedAt: now,
            supersedesFactId: nil
        )
        _ = try await store.createFact(
            old,
            provenance: .init(
                source: .explicitUser,
                sourceIdentifier: nil,
                note: nil,
                timestamp: now
            )
        )

        let replacement = BrainFact(
            id: UUID(),
            subjectEntityId: personId,
            predicate: "department",
            value: "Financeiro",
            status: .active,
            confidence: 1,
            createdAt: now,
            updatedAt: now,
            lastConfirmedAt: now,
            supersedesFactId: old.id
        )
        _ = try await store.supersedeFact(
            oldFactId: old.id,
            with: replacement,
            at: now.addingTimeInterval(60),
            provenance: .init(
                source: .explicitUser,
                sourceIdentifier: nil,
                note: nil,
                timestamp: now
            )
        )

        let active = try await store.facts(subjectEntityId: personId, statuses: [.active])
        let superseded = try await store.facts(subjectEntityId: personId, statuses: [.superseded])
        XCTAssertEqual(active.map(\.value), ["Financeiro"])
        XCTAssertEqual(superseded.map(\.value), ["TI"])
    }

    func testRelationAndBiometricReferencePointToStablePersonUUID() async throws {
        let store = try await makeStore()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let personId = UUID()
        let orgId = UUID()

        _ = try await store.createPersonProfile(
            .init(
                id: personId,
                displayName: "João",
                createdAt: now,
                updatedAt: now,
                firstSeenAt: nil,
                lastSeenAt: nil,
                status: .active,
                confidence: 1
            ),
            entity: .init(
                id: personId,
                type: .person,
                displayName: "João",
                status: .active,
                createdAt: now,
                updatedAt: now
            )
        )
        _ = try await store.createEntity(
            .init(
                id: orgId,
                type: .organization,
                displayName: "Cresol",
                status: .active,
                createdAt: now,
                updatedAt: now
            )
        )
        _ = try await store.createRelation(
            .init(
                id: UUID(),
                sourceEntityId: personId,
                relationType: "works_at",
                targetEntityId: orgId,
                status: .active,
                confidence: 1,
                createdAt: now,
                updatedAt: now
            ),
            provenance: .init(
                source: .explicitUser,
                sourceIdentifier: nil,
                note: nil,
                timestamp: now
            )
        )
        _ = try await store.addBiometricReference(
            .init(
                id: UUID(),
                personId: personId,
                kind: .face,
                storageReference: "secure://face/abc",
                quality: 0.9,
                createdAt: now,
                updatedAt: now
            ),
            provenance: .init(
                source: .toolResult,
                sourceIdentifier: "face-recognition",
                note: nil,
                timestamp: now
            )
        )

        let relations = try await store.relations(entityId: personId, statuses: [.active])
        let biometricReferences = try await store.biometricReferences(personId: personId)
        XCTAssertEqual(relations.count, 1)
        XCTAssertEqual(biometricReferences.first?.personId, personId)
    }
}
