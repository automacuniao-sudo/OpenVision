import XCTest
@testable import JARVIS

final class SpotifyToolSupportTests: XCTestCase {
    func testRecognizesSupportedActions() {
        XCTAssertEqual(SpotifyToolSupport.action(from: ["action": "open"]), .open)
        XCTAssertEqual(SpotifyToolSupport.action(from: ["action": "play"]), .play)
        XCTAssertEqual(SpotifyToolSupport.action(from: ["action": "pause"]), .pause)
        XCTAssertEqual(SpotifyToolSupport.action(from: ["action": "resume"]), .resume)
        XCTAssertEqual(SpotifyToolSupport.action(from: ["action": "next"]), .next)
        XCTAssertEqual(SpotifyToolSupport.action(from: ["action": "previous"]), .previous)
        XCTAssertEqual(SpotifyToolSupport.action(from: ["action": "seek"]), .seek)
        XCTAssertEqual(SpotifyToolSupport.action(from: ["action": "shuffle"]), .shuffle)
        XCTAssertEqual(SpotifyToolSupport.action(from: ["action": "status"]), .status)
        XCTAssertEqual(SpotifyToolSupport.action(from: ["action": "connect"]), .connect)
        XCTAssertNil(SpotifyToolSupport.action(from: ["action": "volume"] ))
    }

    func testPlayQueryIsTrimmedAndBlankQueryIsRejected() {
        XCTAssertEqual(SpotifyToolSupport.query(from: ["query": "  Sweet Child O' Mine  "]), "Sweet Child O' Mine")
        XCTAssertNil(SpotifyToolSupport.query(from: ["query": "   "]))
        XCTAssertNil(SpotifyToolSupport.query(from: [:]))
    }

    func testSeekSecondsAcceptsIntegerAndDouble() {
        XCTAssertEqual(SpotifyToolSupport.seekSeconds(from: ["seconds": 30]), 30)
        XCTAssertEqual(SpotifyToolSupport.seekSeconds(from: ["seconds": -12.5]), -12.5)
        XCTAssertNil(SpotifyToolSupport.seekSeconds(from: [:]))
    }

    func testShuffleRequiresBoolean() {
        XCTAssertEqual(SpotifyToolSupport.shuffleEnabled(from: ["enabled": true]), true)
        XCTAssertEqual(SpotifyToolSupport.shuffleEnabled(from: ["enabled": false]), false)
        XCTAssertNil(SpotifyToolSupport.shuffleEnabled(from: ["enabled": "yes"]))
    }
}
