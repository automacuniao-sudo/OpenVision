import Foundation

struct BrainRetriever: Sendable {
    let source: any BrainRetrievalSource

    init(source: any BrainRetrievalSource) {
        self.source = source
    }

    func retrieve(_ request: BrainRetrievalRequest) async throws -> BrainRetrievalResult {
        guard await source.readiness() == .ready else {
            return .unavailable
        }

        let queryNormalized = BrainTextNormalizer.normalized(request.query)
        let queryTokens = BrainTextNormalizer.tokens(request.query)

        let peopleCandidates = try await source.listPersonProfiles(limit: request.personCandidateLimit)
        let matchedPeople = try await matchPeople(
            peopleCandidates,
            queryNormalized: queryNormalized,
            queryTokens: queryTokens,
            maxPeople: request.maxPeople
        )

        var matchedEntityIDs = request.explicitEntityIDs
        matchedEntityIDs.formUnion(matchedPeople.map(\.profile.id))

        let memoryCandidates = try await source.listActiveMemories(limit: request.memoryCandidateLimit)
        let memories = scoreMemories(
            memoryCandidates,
            request: request,
            queryNormalized: queryNormalized,
            queryTokens: queryTokens,
            matchedEntityIDs: matchedEntityIDs
        )

        let factCandidates = try await source.facts(subjectEntityId: nil, statuses: [.active])
        let facts = scoreFacts(
            factCandidates,
            queryTokens: queryTokens,
            matchedEntityIDs: matchedEntityIDs,
            maxFacts: request.maxFacts
        )

        return BrainRetrievalResult(
            memories: memories,
            facts: facts,
            people: matchedPeople,
            brainAvailable: true,
            memoryCandidateCount: memoryCandidates.count,
            factCandidateCount: factCandidates.count,
            personCandidateCount: peopleCandidates.count
        )
    }

    private func matchPeople(
        _ candidates: [PersonProfile],
        queryNormalized: String,
        queryTokens: Set<String>,
        maxPeople: Int
    ) async throws -> [MatchedPerson] {
        var matches: [MatchedPerson] = []

        for profile in candidates where profile.status == .active {
            let aliases = try await source.aliases(personId: profile.id)
            let matchingAlias = aliases
                .filter { matchesText($0.alias, queryNormalized: queryNormalized, queryTokens: queryTokens) }
                .sorted { lhs, rhs in
                    if lhs.confidence != rhs.confidence { return lhs.confidence > rhs.confidence }
                    if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
                    return lhs.id.uuidString < rhs.id.uuidString
                }
                .first

            let displayNameMatches = profile.displayName.map {
                matchesText($0, queryNormalized: queryNormalized, queryTokens: queryTokens)
            } ?? false

            if matchingAlias != nil || displayNameMatches {
                matches.append(MatchedPerson(profile: profile, matchedAlias: matchingAlias))
            }
        }

        return Array(
            matches.sorted { lhs, rhs in
                if lhs.profile.updatedAt != rhs.profile.updatedAt {
                    return lhs.profile.updatedAt > rhs.profile.updatedAt
                }
                return lhs.profile.id.uuidString < rhs.profile.id.uuidString
            }.prefix(maxPeople)
        )
    }

    private func scoreMemories(
        _ candidates: [BrainMemory],
        request: BrainRetrievalRequest,
        queryNormalized: String,
        queryTokens: Set<String>,
        matchedEntityIDs: Set<UUID>
    ) -> [ScoredBrainMemory] {
        let active = candidates.filter { $0.status == .active }
        let dates = active.map { $0.lastConfirmedAt ?? $0.updatedAt }
        let oldest = dates.min()
        let newest = dates.max()

        let scored = active.compactMap { memory -> ScoredBrainMemory? in
            let memoryTokens = BrainTextNormalizer.tokens(memory.content)
            let sharedTokenCount = queryTokens.intersection(memoryTokens).count
            let normalizedContent = BrainTextNormalizer.normalized(memory.content)
            let normalizedLegacyKey = memory.legacyKey.map(BrainTextNormalizer.normalized)

            let legacyContainment = normalizedLegacyKey.map {
                !$0.isEmpty && (queryNormalized.contains($0) || $0.contains(queryNormalized))
            } ?? false
            let contentContainment = !queryNormalized.isEmpty && (
                normalizedContent.contains(queryNormalized) || queryNormalized.contains(normalizedContent)
            )
            let entityRelevant = memory.subjectEntityId.map(matchedEntityIDs.contains) ?? false
            let lexicalRelevant = sharedTokenCount > 0 || legacyContainment || contentContainment

            guard memory.kind == .coreProfile || lexicalRelevant || entityRelevant else {
                return nil
            }

            var score = Double(sharedTokenCount * 40)
            if legacyContainment { score += 35 }
            if contentContainment { score += 30 }
            if memory.kind == .coreProfile { score += 20 }
            score += memory.confidence * 10
            score += memory.importance * 10
            score += recencyContribution(
                memory.lastConfirmedAt ?? memory.updatedAt,
                oldest: oldest,
                newest: newest
            )

            return ScoredBrainMemory(memory: memory, score: score)
        }

        return Array(
            scored.sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                let lhsDate = lhs.memory.lastConfirmedAt ?? lhs.memory.updatedAt
                let rhsDate = rhs.memory.lastConfirmedAt ?? rhs.memory.updatedAt
                if lhsDate != rhsDate { return lhsDate > rhsDate }
                return lhs.memory.id.uuidString < rhs.memory.id.uuidString
            }.prefix(request.maxMemories)
        )
    }

    private func scoreFacts(
        _ candidates: [BrainFact],
        queryTokens: Set<String>,
        matchedEntityIDs: Set<UUID>,
        maxFacts: Int
    ) -> [ScoredBrainFact] {
        let scored = candidates.compactMap { fact -> ScoredBrainFact? in
            guard fact.status == .active else { return nil }

            let factTokens = BrainTextNormalizer.tokens("\(fact.predicate) \(fact.value)")
            let sharedTokenCount = queryTokens.intersection(factTokens).count
            let subjectMatches = fact.subjectEntityId.map(matchedEntityIDs.contains) ?? false

            guard sharedTokenCount > 0 || subjectMatches else { return nil }

            var score = Double(sharedTokenCount * 40)
            if subjectMatches { score += 50 }
            score += fact.confidence * 10

            return ScoredBrainFact(fact: fact, score: score)
        }

        return Array(
            scored.sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                if lhs.fact.updatedAt != rhs.fact.updatedAt { return lhs.fact.updatedAt > rhs.fact.updatedAt }
                return lhs.fact.id.uuidString < rhs.fact.id.uuidString
            }.prefix(maxFacts)
        )
    }

    private func matchesText(
        _ candidate: String,
        queryNormalized: String,
        queryTokens: Set<String>
    ) -> Bool {
        let candidateNormalized = BrainTextNormalizer.normalized(candidate)
        guard !candidateNormalized.isEmpty else { return false }

        if queryNormalized.contains(candidateNormalized) || candidateNormalized.contains(queryNormalized) {
            return true
        }

        let candidateTokens = BrainTextNormalizer.tokens(candidate)
        return !queryTokens.intersection(candidateTokens).isEmpty
    }

    private func recencyContribution(_ date: Date, oldest: Date?, newest: Date?) -> Double {
        guard let oldest, let newest, newest > oldest else { return 0 }
        let span = newest.timeIntervalSince(oldest)
        let offset = date.timeIntervalSince(oldest)
        return min(5, max(0, (offset / span) * 5))
    }
}

extension BrainService: BrainRetrievalSource {}
