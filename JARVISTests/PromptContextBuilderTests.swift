import XCTest
#if !JARVIS_PURE_TESTS
@testable import JARVIS
#endif

final class PromptContextBuilderTests: XCTestCase {
    func testBuilderReturnsEmptyContextWhenBrainUnavailable() async {
        let source = PromptContextFakeSource(readiness: .notInitialized)
        let builder = PromptContextBuilder(source: source)

        let context = await builder.build(
            for: "qual meu café favorito",
            maxCharacters: 1800,
            generatedAt: Date(timeIntervalSince1970: 500)
        )

        XCTAssertFalse(context.diagnostics.brainAvailable)
        XCTAssertTrue(context.coreMemories.isEmpty)
        XCTAssertTrue(context.relevantMemories.isEmpty)
        XCTAssertTrue(context.relevantFacts.isEmpty)
        XCTAssertTrue(context.relatedEntities.isEmpty)
        XCTAssertNil(context.renderedContext(maxCharacters: 1800))
    }

    func testBuilderRespectsRecordAndCharacterBudgets() async {
        let first = makeMemory(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000301")!,
            content: "Café espresso curto e forte",
            importance: 1.0
        )
        let second = makeMemory(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000302")!,
            content: "Café coado sem açúcar durante a manhã",
            importance: 0.8
        )
        let third = makeMemory(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000303")!,
            content: "Café gelado apenas em dias quentes",
            importance: 0.6
        )
        let source = PromptContextFakeSource(memories: [first, second, third])
        let builder = PromptContextBuilder(source: source)

        let context = await builder.build(
            for: "café",
            maxCharacters: 135,
            generatedAt: Date(timeIntervalSince1970: 500)
        )
        let rendered = context.renderedContext(maxCharacters: 135)

        XCTAssertLessThanOrEqual(rendered?.count ?? 0, 135)
        XCTAssertLessThan(context.relevantMemories.count, 3)
        XCTAssertTrue(context.diagnostics.truncated)
        XCTAssertEqual(context.diagnostics.renderedCharacters, rendered?.count ?? 0)
    }

    func testBuilderUsesStableWholeRecordTruncation() async {
        let first = makeMemory(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000311")!,
            content: "Café espresso",
            importance: 1.0
        )
        let second = makeMemory(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000312")!,
            content: "Café coado com leite",
            importance: 0.5
        )
        let source = PromptContextFakeSource(memories: [first, second])
        let builder = PromptContextBuilder(source: source)
        let generatedAt = Date(timeIntervalSince1970: 500)

        let a = await builder.build(for: "café", maxCharacters: 120, generatedAt: generatedAt)
        let b = await builder.build(for: "café", maxCharacters: 120, generatedAt: generatedAt)
        let renderedA = a.renderedContext(maxCharacters: 120)
        let renderedB = b.renderedContext(maxCharacters: 120)

        XCTAssertEqual(a, b)
        XCTAssertEqual(renderedA, renderedB)
        XCTAssertFalse(renderedA?.contains("Café coad") == true)
        XCTAssertFalse(renderedA?.hasSuffix("Café") == true)
    }

    func testSessionSnapshotIncludesBoundedCoreAndTopActiveFallbackMemories() async {
        let core = (0..<5).map { index in
            makeMemory(
                id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", 400 + index))!,
                kind: .coreProfile,
                content: "Perfil principal \(index)",
                importance: Double(10 - index) / 10.0
            )
        }
        let fallback = (0..<8).map { index in
            makeMemory(
                id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", 500 + index))!,
                content: "Memória ativa \(index)",
                importance: Double(10 - index) / 10.0
            )
        }
        let source = PromptContextFakeSource(memories: core + fallback)
        let builder = PromptContextBuilder(source: source)

        let context = await builder.buildSessionSnapshot(
            maxCharacters: 1600,
            generatedAt: Date(timeIntervalSince1970: 500)
        )

        XCTAssertLessThanOrEqual(context.coreMemories.count, 3)
        XCTAssertLessThanOrEqual(context.relevantMemories.count, 5)
        XCTAssertLessThanOrEqual(context.renderedContext(maxCharacters: 1600)?.count ?? 0, 1600)
        XCTAssertTrue(context.coreMemories.allSatisfy { $0.memory.kind == .coreProfile })
    }

    func testDiagnosticsContainCountsOnly() async {
        let secret = "SEGREDO-NAO-DEVE-IR-PARA-DIAGNOSTICO"
        let memory = makeMemory(content: "Café \(secret)")
        let source = PromptContextFakeSource(memories: [memory])
        let builder = PromptContextBuilder(source: source)

        let context = await builder.build(
            for: "café",
            maxCharacters: 1800,
            generatedAt: Date(timeIntervalSince1970: 500)
        )
        let diagnostics = String(describing: context.diagnostics)

        XCTAssertEqual(context.diagnostics.memoryCount, 1)
        XCTAssertFalse(diagnostics.contains(secret))
        XCTAssertFalse(diagnostics.contains(memory.content))
    }

    private func makeMemory(
        id: UUID = UUID(),
        kind: BrainMemoryKind = .semantic,
        content: String,
        status: BrainRecordStatus = .active,
        confidence: Double = 1.0,
        importance: Double = 0.5,
        updatedAt: Date = Date(timeIntervalSince1970: 100)
    ) -> BrainMemory {
        BrainMemory(
            id: id,
            kind: kind,
            content: content,
            legacyKey: nil,
            subjectEntityId: nil,
            status: status,
            confidence: confidence,
            importance: importance,
            createdAt: Date(timeIntervalSince1970: 50),
            updatedAt: updatedAt,
            lastConfirmedAt: updatedAt,
            expiresAt: nil
        )
    }
}

private actor PromptContextFakeSource: BrainRetrievalSource {
    let readinessState: BrainReadiness
    let memories: [BrainMemory]
    let storedFacts: [BrainFact]
    let people: [PersonProfile]
    let aliasesByPerson: [UUID: [PersonAlias]]

    init(
        readiness: BrainReadiness = .ready,
        memories: [BrainMemory] = [],
        facts: [BrainFact] = [],
        people: [PersonProfile] = [],
        aliasesByPerson: [UUID: [PersonAlias]] = [:]
    ) {
        self.readinessState = readiness
        self.memories = memories
        self.storedFacts = facts
        self.people = people
        self.aliasesByPerson = aliasesByPerson
    }

    func readiness() async -> BrainReadiness {
        readinessState
    }

    func listActiveMemories(limit: Int) async throws -> [BrainMemory] {
        Array(memories.filter { $0.status == .active }.prefix(limit))
    }

    func facts(subjectEntityId: UUID?, statuses: Set<BrainRecordStatus>) async throws -> [BrainFact] {
        storedFacts.filter { fact in
            statuses.contains(fact.status) && (subjectEntityId == nil || fact.subjectEntityId == subjectEntityId)
        }
    }

    func listPersonProfiles(limit: Int) async throws -> [PersonProfile] {
        Array(people.prefix(limit))
    }

    func aliases(personId: UUID) async throws -> [PersonAlias] {
        aliasesByPerson[personId] ?? []
    }
}
