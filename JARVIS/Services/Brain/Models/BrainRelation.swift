import Foundation

struct BrainRelation: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let sourceEntityId: UUID
    var relationType: String
    let targetEntityId: UUID
    var status: BrainRecordStatus
    var confidence: Double
    var createdAt: Date
    var updatedAt: Date
}
