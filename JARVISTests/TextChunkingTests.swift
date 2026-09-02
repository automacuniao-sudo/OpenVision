// JARVIS - TextChunkingTests.swift

import XCTest
#if !JARVIS_PURE_TESTS
@testable import JARVIS
#endif

final class TextChunkingTests: XCTestCase {
    private func boundaryOffset(_ s: String) -> Int? {
        guard let idx = TextChunking.lastSentenceBoundary(in: s) else { return nil }
        return s.distance(from: s.startIndex, to: idx)
    }

    func testSimpleSentence() {
        XCTAssertEqual(boundaryOffset("Hello there."), 12)
    }

    func testPicksLastCompletedSentence() {
        let s = "First. Second. Trailing fragment"
        XCTAssertEqual(boundaryOffset(s), 14)
    }

    func testDecimalNumberIsNotABoundary() {
        XCTAssertNil(boundaryOffset("The value is 2"))
        XCTAssertEqual(boundaryOffset("The value is 2.5 today."), 23)
    }

    func testNewlineIsABoundary() {
        XCTAssertEqual(boundaryOffset("line one\nmore"), 9)
    }

    func testNoBoundaryInFragment() {
        XCTAssertNil(boundaryOffset("still streaming with no end yet"))
    }

    func testQuestionAndExclamation() {
        XCTAssertEqual(boundaryOffset("Really? Yes! And then"), 12)
    }

    func testSentencesSplitsOnTerminators() {
        XCTAssertEqual(TextChunking.sentences("First. Second! Third?"), ["First.", "Second!", "Third?"])
    }

    func testSentencesKeepsTrailingFragment() {
        XCTAssertEqual(TextChunking.sentences("Done. And one more thing"), ["Done.", "And one more thing"])
    }

    func testSentencesDoesNotSplitDecimals() {
        XCTAssertEqual(TextChunking.sentences("It is 2.5 meters tall. Impressive."), ["It is 2.5 meters tall.", "Impressive."])
    }

    func testSentencesSplitsOnNewlines() {
        XCTAssertEqual(TextChunking.sentences("line one\nline two"), ["line one", "line two"])
    }

    func testSentencesDropsEmptiesAndTrims() {
        XCTAssertEqual(TextChunking.sentences("  Hello.   \n\n  World.  "), ["Hello.", "World."])
        XCTAssertEqual(TextChunking.sentences(""), [])
        XCTAssertEqual(TextChunking.sentences("   \n  "), [])
    }

    func testSentencesSingleFragment() {
        XCTAssertEqual(TextChunking.sentences("no terminator here"), ["no terminator here"])
    }
}
