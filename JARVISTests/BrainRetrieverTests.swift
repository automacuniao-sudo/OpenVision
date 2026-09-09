import XCTest

final class BrainRetrieverTests: XCTestCase {
    func testTextNormalizerFoldsCaseAndDiacritics() {
        XCTAssertEqual(
            BrainTextNormalizer.tokens("  Café em SÃO Paulo!  "),
            Set(["cafe", "sao", "paulo"])
        )
    }

    func testTextNormalizerDropsLightweightPortugueseStopWords() {
        XCTAssertEqual(
            BrainTextNormalizer.tokens("qual é o meu café favorito"),
            Set(["cafe", "favorito"])
        )
    }
}
