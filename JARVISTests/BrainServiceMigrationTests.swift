import XCTest
#if !JARVIS_PURE_TESTS
@testable import JARVIS
#endif

final class BrainServiceMigrationTests: XCTestCase {
    func testLegacyMemoriesImportExactlyOnce() async throws {
        let store = SQLiteBrainStore(location: .inMemory)
        let service = BrainService(store: store)
        let legacy = [
            "idioma_preferido": "Português brasileiro",
            "favorite_team": "Time A"
        ]

        try await service.initialize(legacyMemories: legacy)
        let firstImport = try await service.listActiveMemories(limit: 20)
        XCTAssertEqual(firstImport.count, 2)

        try await service.initialize(legacyMemories: legacy)
        let secondImport = try await service.listActiveMemories(limit: 20)
        XCTAssertEqual(secondImport.count, 2)

        let readiness = await service.readiness()
        XCTAssertEqual(readiness, .ready)
    }

    func testLegacyImportPreservesKeyContentAndProvenanceIntent() async throws {
        let store = SQLiteBrainStore(location: .inMemory)
        let service = BrainService(store: store)

        try await service.initialize(legacyMemories: [
            "projeto_principal": "Projeto JARVIS"
        ])

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

        _ = try await service.rememberLegacy(
            key: "temperature_unit",
            value: "Celsius",
            source: .explicitUser
        )
        _ = try await service.rememberLegacy(
            key: "temperature_unit",
            value: "Celsius sempre",
            source: .explicitUser
        )

        let memories = try await service.listActiveMemories(limit: 20)
        XCTAssertEqual(memories.count, 1)

        let stored = try await service.memory(legacyKey: "temperature_unit")
        XCTAssertEqual(stored?.content, "Celsius sempre")
    }
}
