import Foundation

struct BrainFact: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var subjectEntityId: UUID?
    var predicate: String
    var value: String
    var status: BrainRecordStatus
    var confidence: Double
    var createdAt: Date
    var updatedAt: Date
    var lastConfirmedAt: Date?
    var supersedesFactId: UUID?
}
