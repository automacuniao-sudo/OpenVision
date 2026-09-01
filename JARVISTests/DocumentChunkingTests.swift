// JARVIS - DocumentChunkingTests.swift
// Pure text math behind the document store (RAG): chunking, cosine similarity, keyword bonus.

import XCTest
#if !JARVIS_PURE_TESTS
@testable import JARVIS
#endif

final class DocumentChunkingTests: XCTestCase {
    func testShortTextIsOneChunk() {
        let chunks = DocumentChunking.chunks("A short paragraph.")
        XCTAssertEqual(chunks, ["A short paragraph."])
    }

    func testEmptyTextYieldsNoChunks() {
        XCTAssertEqual(DocumentChunking.chunks(""), [])
        XCTAssertEqual(DocumentChunking.chunks("  \n\n  "), [])
    }

    func testParagraphsPackIntoTargetSizedChunks() {
        let paragraph = String(repeating: "Some sentence here. ", count: 20)
        let text = [paragraph, paragraph, paragraph].joined(separator: "\n\n")
        let chunks = DocumentChunking.chunks(text, targetSize: 900)
        XCTAssertGreaterThan(chunks.count, 1)
        for chunk in chunks { XCTAssertLessThan(chunk.count, 1100) }
    }

    func testOversizedParagraphSplitsOnSentences() {
        let big = String(repeating: "This is sentence number one of the manual. ", count: 40)
        let chunks = DocumentChunking.chunks(big, targetSize: 500)
        XCTAssertGreaterThan(chunks.count, 2)
        for chunk in chunks.dropLast() { XCTAssertTrue(chunk.hasSuffix(".")) }
    }

    func testAllTextIsPreserved() {
        let text = (1...30).map { "Fact number \($0) lives here." }.joined(separator: "\n\n")
        let chunks = DocumentChunking.chunks(text, targetSize: 200)
        let joined = chunks.joined(separator: " ")
        for i in 1...30 { XCTAssertTrue(joined.contains("Fact number \(i)")) }
    }

    func testCosineIdenticalVectorsIsOne() {
        XCTAssertEqual(DocumentChunking.cosineSimilarity([1, 2, 3], [1, 2, 3]), 1.0, accuracy: 1e-9)
    }

    func testCosineOrthogonalVectorsIsZero() {
        XCTAssertEqual(DocumentChunking.cosineSimilarity([1, 0], [0, 1]), 0.0, accuracy: 1e-9)
    }

    func testCosineOppositeVectorsIsMinusOne() {
        XCTAssertEqual(DocumentChunking.cosineSimilarity([1, 1], [-1, -1]), -1.0, accuracy: 1e-9)
    }

    func testCosineMismatchedOrEmptyIsZero() {
        XCTAssertEqual(DocumentChunking.cosineSimilarity([1, 2], [1, 2, 3]), 0)
        XCTAssertEqual(DocumentChunking.cosineSimilarity([], []), 0)
        XCTAssertEqual(DocumentChunking.cosineSimilarity([0, 0], [1, 2]), 0)
    }

    func testKeywordBonusCountsMatchedTerms() {
        XCTAssertEqual(DocumentChunking.keywordBonus(query: "router error blinking", text: "If the router shows a blinking light…"), 0.10, accuracy: 1e-9)
    }

    func testKeywordBonusIsCapped() {
        let text = "alpha bravo charlie delta echo foxtrot"
        XCTAssertEqual(DocumentChunking.keywordBonus(query: "alpha bravo charlie delta echo", text: text), 0.15, accuracy: 1e-9)
    }

    func testKeywordBonusIgnoresShortWords() {
        XCTAssertEqual(DocumentChunking.keywordBonus(query: "the of a is", text: "the of a is everywhere"), 0.0, accuracy: 1e-9)
    }

    func testKeywordBonusCaseInsensitive() {
        XCTAssertEqual(DocumentChunking.keywordBonus(query: "ROUTER", text: "my router is fine"), 0.05, accuracy: 1e-9)
    }

    private let titles = ["TP-Link Router Manual", "Grandma's Lasagna Recipe", "Authorization Letter 2026"]

    func testTitleMatchFindsByKeyword() {
        XCTAssertEqual(DocumentChunking.bestTitleMatch(query: "router manual", titles: titles), 0)
        XCTAssertEqual(DocumentChunking.bestTitleMatch(query: "the lasagna recipe", titles: titles), 1)
        XCTAssertEqual(DocumentChunking.bestTitleMatch(query: "authorization letter", titles: titles), 2)
    }

    func testTitleMatchIsCaseInsensitive() {
        XCTAssertEqual(DocumentChunking.bestTitleMatch(query: "ROUTER", titles: titles), 0)
    }

    func testTitleMatchPartialTokens() {
        XCTAssertEqual(DocumentChunking.bestTitleMatch(query: "open the authorization", titles: titles), 2)
    }

    func testTitleMatchNoOverlapIsNil() {
        XCTAssertNil(DocumentChunking.bestTitleMatch(query: "tax return", titles: titles))
        XCTAssertNil(DocumentChunking.bestTitleMatch(query: "", titles: titles))
        XCTAssertNil(DocumentChunking.bestTitleMatch(query: "router", titles: []))
    }

    func testTitleMatchPrefersMoreOverlap() {
        let ambiguous = ["Router Setup Guide", "Router Manual TP-Link"]
        XCTAssertEqual(DocumentChunking.bestTitleMatch(query: "router manual", titles: ambiguous), 1)
    }

    func testWindowKeepsKeywordSentenceBeyondPrefix() {
        let boilerplate = String(repeating: "Header line with address details. ", count: 20)
        let text = boilerplate + "I hereby authorize Mansi Kumari to collect the belongings."
        let window = DocumentChunking.relevantWindow(text: text, query: "is Mansi authorized", limit: 300)
        XCTAssertTrue(window.contains("authorize Mansi Kumari"))
        XCTAssertLessThan(window.count, 320)
    }

    func testWindowShortTextUnchanged() {
        XCTAssertEqual(DocumentChunking.relevantWindow(text: "Short text.", query: "anything", limit: 450), "Short text.")
    }

    func testWindowNoKeywordFallsBackToHead() {
        let text = "First sentence here. " + String(repeating: "More filler content. ", count: 40)
        let window = DocumentChunking.relevantWindow(text: text, query: "zebra", limit: 100)
        XCTAssertTrue(window.hasPrefix("First sentence here."))
        XCTAssertLessThanOrEqual(window.count, 110)
    }

    func testWindowMarksTruncationWithEllipses() {
        let text = String(repeating: "Padding sentence. ", count: 30) + "The keyword target lives here." + String(repeating: " Trailing sentence.", count: 30)
        let window = DocumentChunking.relevantWindow(text: text, query: "keyword", limit: 200)
        XCTAssertTrue(window.contains("keyword target"))
        XCTAssertTrue(window.hasPrefix("…"))
        XCTAssertTrue(window.hasSuffix("…"))
    }
}
