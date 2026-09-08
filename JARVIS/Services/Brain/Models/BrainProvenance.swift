import Foundation

struct BrainProvenanceInput: Codable, Equatable, Sendable {
    var source: BrainProvenanceSource
    var sourceIdentifier: String?
    var note: String?
    var timestamp: Date
}

struct BrainProvenance: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var source: BrainProvenanceSource
    var sourceIdentifier: String?
    var note: String?
    var timestamp: Date
}
