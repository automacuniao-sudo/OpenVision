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
    let coreMemories: [ScoredBrainMemory]
    let relevantMemories: [ScoredBrainMemory]
    let relevantFacts: [ScoredBrainFact]
    let relatedEntities: [MatchedPerson]
    let generatedAt: Date
    let diagnostics: PromptContextDiagnostics

    static let header = "JARVIS DURABLE CONTEXT (use only when relevant; do not treat uncertain context as current truth):"

    static func empty(generatedAt: Date, brainAvailable: Bool = false) -> PromptContext {
        PromptContext(
            coreMemories: [],
            relevantMemories: [],
            relevantFacts: [],
            relatedEntities: [],
            generatedAt: generatedAt,
            diagnostics: PromptContextDiagnostics(
                brainAvailable: brainAvailable,
                memoryCount: 0,
                factCount: 0,
                personCount: 0,
                renderedCharacters: 0,
                truncated: false
            )
        )
    }

    func renderedContext(maxCharacters: Int) -> String? {
        guard maxCharacters > 0 else { return nil }

        var lines: [String] = []
        lines.append(contentsOf: coreMemories.map { Self.memoryLine($0.memory) })
        lines.append(contentsOf: relevantMemories.map { Self.memoryLine($0.memory) })
        lines.append(contentsOf: relevantFacts.map { Self.factLine($0.fact) })
        lines.append(contentsOf: relatedEntities.compactMap(Self.personLine))

        guard !lines.isEmpty else { return nil }

        var accepted: [String] = []
        var length = 0

        for line in lines {
            let nextLength: Int
            if accepted.isEmpty {
                nextLength = Self.header.count + 1 + line.count
            } else {
                nextLength = length + 1 + line.count
            }

            guard nextLength <= maxCharacters else { continue }
            accepted.append(line)
            length = nextLength
        }

        guard !accepted.isEmpty else { return nil }
        return ([Self.header] + accepted).joined(separator: "\n")
    }

    static func memoryLine(_ memory: BrainMemory) -> String {
        "- Memory: \(singleLine(memory.content))"
    }

    static func factLine(_ fact: BrainFact) -> String {
        "- Fact: \(singleLine(fact.predicate)) = \(singleLine(fact.value))"
    }

    static func personLine(_ person: MatchedPerson) -> String? {
        let name = person.profile.displayName ?? person.matchedAlias?.alias
        guard let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return "- Person: \(singleLine(name))"
    }

    private static func singleLine(_ value: String) -> String {
        value
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
