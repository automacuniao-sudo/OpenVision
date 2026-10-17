import Foundation

protocol BrainRetrievalSource: Sendable {
    func readiness() async -> BrainReadiness
    func listActiveMemories(limit: Int) async throws -> [BrainMemory]
    func facts(subjectEntityId: UUID?, statuses: Set<BrainRecordStatus>) async throws -> [BrainFact]
    func listPersonProfiles(limit: Int) async throws -> [PersonProfile]
    func aliases(personId: UUID) async throws -> [PersonAlias]
}

struct BrainRetrievalRequest: Sendable, Equatable {
    var query: String
    var explicitEntityIDs: Set<UUID> = []
    var memoryCandidateLimit: Int = 200
    var personCandidateLimit: Int = 100
    var maxMemories: Int = 8
    var maxFacts: Int = 8
    var maxPeople: Int = 4
}

struct ScoredBrainMemory: Equatable, Sendable {
    let memory: BrainMemory
    let score: Double
}

struct ScoredBrainFact: Equatable, Sendable {
    let fact: BrainFact
    let score: Double
}

struct MatchedPerson: Equatable, Sendable {
    let profile: PersonProfile
    let matchedAlias: PersonAlias?
}

struct BrainRetrievalResult: Equatable, Sendable {
    let memories: [ScoredBrainMemory]
    let facts: [ScoredBrainFact]
    let people: [MatchedPerson]
    let brainAvailable: Bool
    let memoryCandidateCount: Int
    let factCandidateCount: Int
    let personCandidateCount: Int

    static let unavailable = BrainRetrievalResult(
        memories: [],
        facts: [],
        people: [],
        brainAvailable: false,
        memoryCandidateCount: 0,
        factCandidateCount: 0,
        personCandidateCount: 0
    )
}
