import Foundation

struct LegacyMemoryImporter: Sendable {
    let store: any BrainStore

    func importIfNeeded(_ memories: [String: String], at: Date) async throws -> Int {
        try await store.importLegacyMemories(memories, at: at)
    }
}
