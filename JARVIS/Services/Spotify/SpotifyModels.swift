import Foundation

struct SpotifyArtist: Codable, Equatable, Sendable {
    let name: String
}

struct SpotifyTrack: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let uri: String
    let artists: [SpotifyArtist]

    var artistNames: String {
        artists.map(\.name).joined(separator: ", ")
    }
}

struct SpotifyTrackPage: Codable, Equatable, Sendable {
    let items: [SpotifyTrack]
}

struct SpotifyTrackSearchResponse: Codable, Equatable, Sendable {
    let tracks: SpotifyTrackPage
}

struct SpotifyTokenResponse: Codable, Sendable {
    let accessToken: String
    let tokenType: String
    let expiresIn: Int
    let refreshToken: String?
    let scope: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case tokenType = "token_type"
        case expiresIn = "expires_in"
        case refreshToken = "refresh_token"
        case scope
    }
}

struct SpotifyTokenBundle: Codable, Sendable {
    let accessToken: String
    let refreshToken: String?
    let expiresAt: Date

    var needsRefresh: Bool {
        Date().addingTimeInterval(60) >= expiresAt
    }
}

struct SpotifyPendingAuthorization: Codable, Sendable {
    let state: String
    let codeVerifier: String
    let createdAt: Date
}

enum SpotifySearchSupport {
    static func bestTrack(in tracks: [SpotifyTrack], query: String) -> SpotifyTrack? {
        guard !tracks.isEmpty else { return nil }
        let normalizedQuery = normalize(query)
        guard !normalizedQuery.isEmpty else { return tracks.first }

        if let exact = tracks.first(where: { normalize($0.name) == normalizedQuery }) {
            return exact
        }

        if let containing = tracks.first(where: { normalize($0.name).contains(normalizedQuery) }) {
            return containing
        }

        return tracks.first
    }

    static func normalize(_ text: String) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "pt_BR"))
        let pieces = folded.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(String(scalar)) : " "
        }
        return String(pieces)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .lowercased()
    }
}
