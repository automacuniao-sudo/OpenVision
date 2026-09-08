import Foundation

struct PersonProfile: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    var displayName: String?
    var createdAt: Date
    var updatedAt: Date
    var firstSeenAt: Date?
    var lastSeenAt: Date?
    var status: BrainRecordStatus
    var confidence: Double

    init(
        id: UUID = UUID(),
        displayName: String?,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        firstSeenAt: Date? = nil,
        lastSeenAt: Date? = nil,
        status: BrainRecordStatus = .active,
        confidence: Double = 1.0
    ) {
        precondition((0.0...1.0).contains(confidence), "confidence must be between 0 and 1")
        self.id = id
        self.displayName = displayName
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.firstSeenAt = firstSeenAt
        self.lastSeenAt = lastSeenAt
        self.status = status
        self.confidence = confidence
    }
}
