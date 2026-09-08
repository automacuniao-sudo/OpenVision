import Foundation
import XCTest
#if !JARVIS_PURE_TESTS
@testable import JARVIS
#endif

#if JARVIS_PURE_TESTS
protocol NativeTool {
    var name: String { get }
    var description: String { get }
    var parametersSchema: [String: Any] { get }
    func execute(args: [String: Any]) async throws -> String
}

struct PureTestSettings {
    var memories: [String: String] = [:]
}

@MainActor
final class SettingsManager {
    static let shared = SettingsManager()
    var settings = PureTestSettings()

    func setMemory(key: String, value: String) {
        settings.memories[key] = value
    }

    func deleteMemory(key: String) {
        settings.memories.removeValue(forKey: key)
    }

    func saveNow() {}
}

@MainActor
final class DiagnosticLogger {
    static let shared = DiagnosticLogger()
    func log(_ category: String, _ message: String) {}
}
#endif

final class MemoryToolBrainTests: XCTestCase {
    func testRememberGetSearchAndForgetUseBrainService() async throws {
        let brain = BrainService(store: SQLiteBrainStore(location: .inMemory))
        try await brain.initialize(legacyMemories: [:])
        let tool = MemoryTool(brain: brain)

        let remembered = try await tool.execute(args: [
            "action": "remember",
            "key": "favorite_drink",
            "value": "Café"
        ])
        XCTAssertTrue(remembered.contains("Memória salva"))

        let fetched = try await tool.execute(args: [
            "action": "get",
            "key": "favorite_drink"
        ])
        XCTAssertTrue(fetched.contains("Café"))

        let searched = try await tool.execute(args: [
            "action": "search",
            "query": "cafe"
        ])
        XCTAssertTrue(searched.contains("favorite_drink"))

        let forgotten = try await tool.execute(args: [
            "action": "forget",
            "key": "favorite_drink"
        ])
        XCTAssertTrue(forgotten.contains("apagada"))

        let missing = try await tool.execute(args: [
            "action": "get",
            "key": "favorite_drink"
        ])
        XCTAssertTrue(missing.contains("Não encontrei"))
    }

    func testToolNeverNeedsSettingsManagerMemoryDictionary() async throws {
        let brain = BrainService(store: SQLiteBrainStore(location: .inMemory))
        try await brain.initialize(legacyMemories: ["source": "brain"])
        let tool = MemoryTool(brain: brain)

        let result = try await tool.execute(args: [
            "action": "get",
            "key": "source"
        ])
        XCTAssertTrue(result.contains("brain"))
    }

    func testUnavailableBrainReturnsControlledMessage() async throws {
        let brain = BrainService(store: SQLiteBrainStore(location: .inMemory))
        let tool = MemoryTool(brain: brain)

        let result = try await tool.execute(args: ["action": "list"])
        XCTAssertEqual(result, "A memória persistente está temporariamente indisponível.")
    }
}
