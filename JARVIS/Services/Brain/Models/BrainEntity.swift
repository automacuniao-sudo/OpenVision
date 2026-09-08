import Foundation

struct BrainEntity: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var type: BrainEntityType
    var displayName: String?
    var status: BrainRecordStatus
    var createdAt: Date
    var updatedAt: Date
}
