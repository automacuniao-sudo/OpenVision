import XCTest
@testable import JARVIS

final class SpotifyModelsTests: XCTestCase {
    func testDecodesTrackSearchResponse() throws {
        let json = #"{"tracks":{"items":[{"id":"1","name":"Sweet Child O' Mine","uri":"spotify:track:1","artists":[{"name":"Guns N' Roses"}]}]}}"#
        let response = try JSONDecoder().decode(SpotifyTrackSearchResponse.self, from: Data(json.utf8))

        XCTAssertEqual(response.tracks.items.count, 1)
        XCTAssertEqual(response.tracks.items[0].name, "Sweet Child O' Mine")
        XCTAssertEqual(response.tracks.items[0].uri, "spotify:track:1")
        XCTAssertEqual(response.tracks.items[0].artistNames, "Guns N' Roses")
    }

    func testBestTrackPrefersExactNormalizedTitle() {
        let tracks = [
            SpotifyTrack(id: "1", name: "Sweet Child O' Mine - Live", uri: "spotify:track:1", artists: [SpotifyArtist(name: "Guns N' Roses")]),
            SpotifyTrack(id: "2", name: "Sweet Child O' Mine", uri: "spotify:track:2", artists: [SpotifyArtist(name: "Guns N' Roses")])
        ]

        XCTAssertEqual(SpotifySearchSupport.bestTrack(in: tracks, query: "sweet child o mine")?.id, "2")
    }
}
