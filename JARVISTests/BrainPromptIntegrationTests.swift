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
}
