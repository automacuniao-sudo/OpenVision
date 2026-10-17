import XCTest
#if !JARVIS_PURE_TESTS
@testable import JARVIS
#endif

final class BrainPromptIntegrationTests: XCTestCase {
    func testGeminiPromptAdapterAppendsBrainContextExactlyOnce() {
        let base = "BASE SYSTEM PROMPT"
        let brainContext = "JARVIS DURABLE CONTEXT:\n- Memory: café sem açúcar"

        let prompt = GeminiPromptContextAdapter.makePrompt(
            basePrompt: base,
            brainContext: brainContext
        )

        XCTAssertTrue(prompt.hasPrefix(base))
        XCTAssertEqual(prompt.components(separatedBy: brainContext).count - 1, 1)
    }

    func testGeminiPromptAdapterLeavesBasePromptUnchangedWithoutBrainContext() {
        let base = "BASE SYSTEM PROMPT"

        XCTAssertEqual(
            GeminiPromptContextAdapter.makePrompt(basePrompt: base, brainContext: nil),
            base
        )
        XCTAssertEqual(
            GeminiPromptContextAdapter.makePrompt(basePrompt: base, brainContext: "   \n"),
            base
        )
    }

    func testGeminiLiveSetupBuildsBoundedBrainSessionSnapshot() throws {
        let source = try geminiLiveSource()

        XCTAssertTrue(source.contains("PromptContextBuilder.shared"))
        XCTAssertTrue(source.contains("buildSessionSnapshot("))
        XCTAssertTrue(source.contains("GeminiPromptContextAdapter.makePrompt"))
    }

    func testGeminiLiveNoLongerReadsLegacySettingsMemoryDictionary() throws {
        let source = try geminiLiveSource()

        XCTAssertFalse(source.contains("SettingsManager.shared.settings.memories"))
    }

    private func geminiLiveSource() throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = repositoryRoot
            .appendingPathComponent("JARVIS")
            .appendingPathComponent("Services")
            .appendingPathComponent("GeminiLive")
            .appendingPathComponent("GeminiLiveService.swift")

        return try String(contentsOf: sourceURL, encoding: .utf8)
    }
}
