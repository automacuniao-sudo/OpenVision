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
