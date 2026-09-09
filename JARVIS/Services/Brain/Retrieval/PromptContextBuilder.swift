import Foundation

struct PromptContextBuilder: Sendable {
    static let shared = PromptContextBuilder(source: BrainService.shared)

    private let source: any BrainRetrievalSource

    init(source: any BrainRetrievalSource) {
        self.source = source
    }

    func build(
        for query: String,
        explicitEntityIDs: Set<UUID> = [],
        maxCharacters: Int = 1800,
        generatedAt: Date = Date()
    ) async -> PromptContext {
        guard await source.readiness() == .ready else {
            return .unavailable(generatedAt: generatedAt)
        }

        do {
            let request = BrainRetrievalRequest(
                query: query,
                explicitEntityIDs: explicitEntityIDs
            )
            let result = try await BrainRetriever(source: source).retrieve(request)
            guard result.brainAvailable else {
                return .unavailable(generatedAt: generatedAt)
            }

            let coreMemories = result.memories.filter { $0.memory.kind == .coreProfile }
            let relevantMemories = result.memories.filter { $0.memory.kind != .coreProfile }

            return makeContext(
                coreMemories: coreMemories,
                relevantMemories: relevantMemories,
                relevantFacts: result.facts,
                relatedEntities: result.people,
                maxCharacters: maxCharacters,
                generatedAt: generatedAt,
                brainAvailable: true,
                initiallyTruncated: false
            )
        } catch {
            return .unavailable(generatedAt: generatedAt)
        }
    }

    func buildSessionSnapshot(
        maxCharacters: Int = 1600,
        generatedAt: Date = Date()
    ) async -> PromptContext {
        guard await source.readiness() == .ready else {
            return .unavailable(generatedAt: generatedAt)
        }

        do {
            let activeMemories = try await source.listActiveMemories(limit: 200)
                .filter { $0.status == .active }

            let sorted = activeMemories.sorted(by: sessionMemoryPrecedes)
            let coreCandidates = sorted.filter { $0.kind == .coreProfile }
            let fallbackCandidates = sorted.filter { $0.kind != .coreProfile }

            let selectedCore = Array(coreCandidates.prefix(3)).map(scoredSessionMemory)
            let selectedFallback = Array(fallbackCandidates.prefix(5)).map(scoredSessionMemory)
            let recordLimitTruncated = coreCandidates.count > selectedCore.count
                || fallbackCandidates.count > selectedFallback.count

            return makeContext(
                coreMemories: selectedCore,
                relevantMemories: selectedFallback,
                relevantFacts: [],
                relatedEntities: [],
                maxCharacters: maxCharacters,
                generatedAt: generatedAt,
                brainAvailable: true,
                initiallyTruncated: recordLimitTruncated
            )
        } catch {
            return .unavailable(generatedAt: generatedAt)
        }
    }

    private func makeContext(
        coreMemories: [ScoredBrainMemory],
        relevantMemories: [ScoredBrainMemory],
        relevantFacts: [ScoredBrainFact],
        relatedEntities: [MatchedPerson],
        maxCharacters: Int,
        generatedAt: Date,
        brainAvailable: Bool,
        initiallyTruncated: Bool
    ) -> PromptContext {
        var selectedCore: [ScoredBrainMemory] = []
        var selectedMemories: [ScoredBrainMemory] = []
        var selectedFacts: [ScoredBrainFact] = []
        var selectedPeople: [MatchedPerson] = []
        var renderedLines: [String] = []
        var truncated = initiallyTruncated

        func fits(_ line: String) -> Bool {
            PromptContext.renderedLength(for: renderedLines + [line]) <= maxCharacters
        }

        for item in coreMemories {
            let line = PromptContext.memoryLine(item)
            guard fits(line) else {
                truncated = true
                break
            }
            selectedCore.append(item)
            renderedLines.append(line)
        }

        if selectedCore.count == coreMemories.count {
            for item in relevantMemories {
                let line = PromptContext.memoryLine(item)
                guard fits(line) else {
                    truncated = true
                    break
                }
                selectedMemories.append(item)
                renderedLines.append(line)
            }
        } else if !relevantMemories.isEmpty {
            truncated = true
        }

        if selectedMemories.count == relevantMemories.count {
            for item in relevantFacts {
                let line = PromptContext.factLine(item)
                guard fits(line) else {
                    truncated = true
                    break
                }
                selectedFacts.append(item)
                renderedLines.append(line)
            }
        } else if !relevantFacts.isEmpty {
            truncated = true
        }

        if selectedFacts.count == relevantFacts.count {
            for item in relatedEntities {
                guard let line = PromptContext.personLine(item) else { continue }
                guard fits(line) else {
                    truncated = true
                    break
                }
                selectedPeople.append(item)
                renderedLines.append(line)
            }
        } else if !relatedEntities.isEmpty {
            truncated = true
        }

        let renderedCharacters = renderedLines.isEmpty
            ? 0
            : PromptContext.renderedLength(for: renderedLines)

        return PromptContext(
            coreMemories: selectedCore,
            relevantMemories: selectedMemories,
            relevantFacts: selectedFacts,
            relatedEntities: selectedPeople,
            generatedAt: generatedAt,
            diagnostics: PromptContextDiagnostics(
                brainAvailable: brainAvailable,
                memoryCount: selectedCore.count + selectedMemories.count,
                factCount: selectedFacts.count,
                personCount: selectedPeople.count,
                renderedCharacters: renderedCharacters,
                truncated: truncated
            )
        )
    }

    private func sessionMemoryPrecedes(_ lhs: BrainMemory, _ rhs: BrainMemory) -> Bool {
        if lhs.importance != rhs.importance { return lhs.importance > rhs.importance }
        if lhs.confidence != rhs.confidence { return lhs.confidence > rhs.confidence }

        let lhsDate = lhs.lastConfirmedAt ?? lhs.updatedAt
        let rhsDate = rhs.lastConfirmedAt ?? rhs.updatedAt
        if lhsDate != rhsDate { return lhsDate > rhsDate }

        return lhs.id.uuidString < rhs.id.uuidString
    }

    private func scoredSessionMemory(_ memory: BrainMemory) -> ScoredBrainMemory {
        ScoredBrainMemory(
            memory: memory,
            score: (memory.importance * 10) + (memory.confidence * 10)
        )
    }
}
