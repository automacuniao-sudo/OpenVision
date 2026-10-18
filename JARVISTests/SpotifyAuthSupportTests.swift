import XCTest
@testable import JARVIS

final class SpotifyAuthSupportTests: XCTestCase {
    func testPKCEChallengeMatchesRFC7636Example() {
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        XCTAssertEqual(
            SpotifyAuthSupport.codeChallenge(for: verifier),
            "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
        )
    }

    func testOAuthStateRequiresExactMatch() {
        XCTAssertTrue(SpotifyAuthSupport.isValidState(expected: "abc-123", received: "abc-123"))
        XCTAssertFalse(SpotifyAuthSupport.isValidState(expected: "abc-123", received: "ABC-123"))
        XCTAssertFalse(SpotifyAuthSupport.isValidState(expected: "abc-123", received: nil))
    }

    func testGeneratedVerifierUsesPKCESafeAlphabetAndLength() {
        let verifier = SpotifyAuthSupport.makeCodeVerifier()
        XCTAssertGreaterThanOrEqual(verifier.count, 43)
        XCTAssertLessThanOrEqual(verifier.count, 128)
        XCTAssertNil(verifier.range(of: "[^A-Za-z0-9._~-]", options: .regularExpression))
    }
}
