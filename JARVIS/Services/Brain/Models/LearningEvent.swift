import Foundation

struct LearningEvent: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var type: LearningEventType
    var targetRecordType: String?
    var targetRecordId: UUID?
    var source: BrainProvenanceSource
    var timestamp: Date
    var beforeSummary: String?
    var afterSummary: String?
    var reversible: Bool
}
