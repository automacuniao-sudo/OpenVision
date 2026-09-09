import XCTest
#if !JARVIS_PURE_TESTS
@testable import JARVIS
#endif

@MainActor
final class MemoriesViewModelTests: XCTestCase {
    func testLoadSaveEditAndForgetUseCanonicalBrain() async throws {
        let brain = BrainService(store: SQLiteBrainStore(location: .inMemory))
        try await brain.initialize(legacyMemories: [:])
        let viewModel = MemoriesViewModel(brain: brain)

        await viewModel.reload()
        XCTAssertTrue(viewModel.memories.isEmpty)

        await viewModel.saveNew(key: "favorite_color", value: "Azul")
        XCTAssertEqual(viewModel.memories.first?.legacyKey, "favorite_color")

        let memory = try XCTUnwrap(viewModel.memories.first)
        await viewModel.update(memory: memory, value: "Verde")
        XCTAssertEqual(viewModel.memories.first?.content, "Verde")

        await viewModel.forget(memory: try XCTUnwrap(viewModel.memories.first))
        XCTAssertTrue(viewModel.memories.isEmpty)
    }
}