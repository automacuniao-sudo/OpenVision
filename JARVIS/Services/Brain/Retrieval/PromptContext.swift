import Foundation

struct PromptContextDiagnostics: Equatable, Sendable {
    let brainAvailable: Bool
    let memoryCount: Int
    let factCount: Int
    let personCount: Int
    let renderedCharacters: Int
    let truncated: Bool
}

struct PromptContext: Equatable, Sendable {
    static let header = "JARVIS DURABLE CONTEXT (use only when relevant; do not treat uncertain context as current truth):"

    let coreMemories: [ScoredBrainMemory]
    let relevantMemories: [ScoredBrainMemory]
    let relevantFacts: [ScoredBrainFact]
    let relatedEntities: [MatchedPerson]
    let generatedAt: Date
    let diagnostics: PromptContextDiagnostics

    func renderedContext(maxCharacters: Int) -> String? {
        guard maxCharacters > 0 else { return nil }

        var acceptedLines: [String] = []
        for line in recordLines() {
            let candidateLines = acceptedLines + [line]
            guard Self.renderedLength(for: candidateLines) <= maxCharacters else { break }
            acceptedLines.append(line)
        }

        guard !acceptedLines.isEmpty else { return nil }
        return ([Self.header] + acceptedLines).joined(separator: "\n")
    }

    func recordLines() -> [String] {
        coreMemories.map(Self.memoryLine)
            + relevantMemories.map(Self.memoryLine)
            + relevantFacts.map(Self.factLine)
            + relatedEntities.compactMap(Self.personLine)
    }

    static func renderedLength(for lines: [String]) -> Int {
        guard !lines.isEmpty else { return 0 }
        return header.count + lines.reduce(0) { $0 + 1 + $1.count }
    }

    static func memoryLine(_ item: ScoredBrainMemory) -> String {
        "- Memory: \(item.memory.content)"
    }

    static func factLine(_ item: ScoredBrainFact) -> String {
        "- Fact: \(item.fact.predicate) = \(item.fact.value)"
    }

    static func personLine(_ item: MatchedPerson) -> String? {
        let displayName = item.profile.displayName ?? item.matchedAlias?.alias
        guard let displayName, !displayName.isEmpty else { return nil }
        return "- Person: \(displayName)"
    }

    static func unavailable(generatedAt: Date) -> PromptContext {
        PromptContext(
            coreMemories: [],
            relevantMemories: [],
            relevantFacts: [],
            relatedEntities: [],
            generatedAt: generatedAt,
            diagnostics: PromptContextDiagnostics(
                brainAvailable: false,
                memoryCount: 0,
                factCount: 0,
                personCount: 0,
                renderedCharacters: 0,
                truncated: false
            )
        )
    }
}
