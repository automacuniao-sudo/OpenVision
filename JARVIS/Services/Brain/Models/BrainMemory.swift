import Foundation

struct BrainMemory: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var kind: BrainMemoryKind
    var content: String
    var legacyKey: String?
    var subjectEntityId: UUID?
    var status: BrainRecordStatus
    var confidence: Double
    var importance: Double
    var createdAt: Date
    var updatedAt: Date
    var lastConfirmedAt: Date?
    var expiresAt: Date?
}
