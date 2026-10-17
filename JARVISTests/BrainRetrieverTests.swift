import XCTest
#if !JARVIS_PURE_TESTS
@testable import JARVIS
#endif

final class BrainRetrieverTests: XCTestCase {
    func testTextNormalizerFoldsCaseAndDiacritics() {
        XCTAssertEqual(
            BrainTextNormalizer.tokens("  Café em SÃO Paulo!  "),
            Set(["cafe", "sao", "paulo"])
        )
    }

    func testTextNormalizerDropsLightweightPortugueseStopWords() {
        XCTAssertEqual(
            BrainTextNormalizer.tokens("qual é o meu café favorito"),
            Set(["cafe", "favorito"])
        )
    }

    func testRetrieverRanksKeywordMatchAboveUnrelatedMemory() async throws {
        let cafe = makeMemory(content: "Meu café favorito é espresso", importance: 0.4)
        let unrelated = makeMemory(content: "Prefiro caminhar de manhã", importance: 1.0)
        let source = FakeBrainRetrievalSource(memories: [unrelated, cafe])

        let result = try await BrainRetriever(source: source).retrieve(
            BrainRetrievalRequest(query: "qual meu café favorito")
        )

        XCTAssertEqual(result.memories.map(\.memory.id), [cafe.id])
    }

    func testRetrieverUsesImportanceAndConfidenceAsTieBreakers() async throws {
        let weaker = makeMemory(
            content: "Café espresso",
            confidence: 0.5,
            importance: 0.2,
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        let stronger = makeMemory(
            content: "Café coado",
            confidence: 1.0,
            importance: 0.9,
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        let source = FakeBrainRetrievalSource(memories: [weaker, stronger])

        let result = try await BrainRetriever(source: source).retrieve(
            BrainRetrievalRequest(query: "café")
        )

        XCTAssertEqual(result.memories.map(\.memory.id), [stronger.id, weaker.id])
    }

    func testRetrieverExcludesForgottenSupersededCandidateAndConflictPending() async throws {
        let active = makeMemory(content: "Café ativo", status: .active)
        let forgotten = makeMemory(content: "Café esquecido", status: .forgotten)
        let superseded = makeMemory(content: "Café antigo", status: .superseded)
        let candidate = makeMemory(content: "Café candidato", status: .candidate)
        let conflict = makeMemory(content: "Café conflito", status: .conflictPending)
        let source = FakeBrainRetrievalSource(memories: [forgotten, superseded, candidate, conflict, active])

        let result = try await BrainRetriever(source: source).retrieve(
            BrainRetrievalRequest(query: "café")
        )

        XCTAssertEqual(result.memories.map(\.memory.id), [active.id])
    }

    func testRetrieverMatchesPersonAliasAndPullsActiveFactsForThatPerson() async throws {
        let personID = UUID(uuidString: "00000000-0000-0000-0000-000000000101")!
        let person = PersonProfile(
            id: personID,
            displayName: "Kauê da Silva",
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 20)
        )
        let alias = PersonAlias(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000102")!,
            personId: personID,
            alias: "Kauê",
            normalizedAlias: "kaue",
            confidence: 1.0,
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 20)
        )
        let activeFact = makeFact(
            subjectEntityId: personID,
            predicate: "trabalho",
            value: "Cresol",
            status: .active
        )
        let forgottenFact = makeFact(
            subjectEntityId: personID,
            predicate: "cargo",
            value: "registro antigo",
            status: .forgotten
        )
        let source = FakeBrainRetrievalSource(
            facts: [forgottenFact, activeFact],
            people: [person],
            aliasesByPerson: [personID: [alias]]
        )

        let result = try await BrainRetriever(source: source).retrieve(
            BrainRetrievalRequest(query: "onde o Kauê trabalha")
        )

        XCTAssertEqual(result.people.map(\.profile.id), [personID])
        XCTAssertEqual(result.people.first?.matchedAlias?.id, alias.id)
        XCTAssertEqual(result.facts.map(\.fact.id), [activeFact.id])
    }

    func testRetrieverIsStableForIdenticalInputs() async throws {
        let first = makeMemory(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000201")!,
            content: "Café espresso",
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        let second = makeMemory(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000202")!,
            content: "Café coado",
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        let source = FakeBrainRetrievalSource(memories: [second, first])
        let retriever = BrainRetriever(source: source)
        let request = BrainRetrievalRequest(query: "café")

        let a = try await retriever.retrieve(request)
        let b = try await retriever.retrieve(request)

        XCTAssertEqual(a, b)
        XCTAssertEqual(a.memories.map(\.memory.id), [first.id, second.id])
    }

    func testRetrieverReturnsNoMatchWithoutDumpingAllSemanticMemories() async throws {
        let memory = makeMemory(content: "Meu café favorito é espresso")
        let source = FakeBrainRetrievalSource(memories: [memory])

        let result = try await BrainRetriever(source: source).retrieve(
            BrainRetrievalRequest(query: "qual a previsão do tempo")
        )

        XCTAssertTrue(result.memories.isEmpty)
        XCTAssertTrue(result.facts.isEmpty)
        XCTAssertTrue(result.people.isEmpty)
    }

    private func makeMemory(
        id: UUID = UUID(),
        kind: BrainMemoryKind = .semantic,
        content: String,
        legacyKey: String? = nil,
        subjectEntityId: UUID? = nil,
        status: BrainRecordStatus = .active,
        confidence: Double = 1.0,
        importance: Double = 0.5,
        updatedAt: Date = Date(timeIntervalSince1970: 100)
    ) -> BrainMemory {
        BrainMemory(
            id: id,
            kind: kind,
            content: content,
            legacyKey: legacyKey,
            subjectEntityId: subjectEntityId,
            status: status,
            confidence: confidence,
            importance: importance,
            createdAt: Date(timeIntervalSince1970: 50),
            updatedAt: updatedAt,
            lastConfirmedAt: updatedAt,
            expiresAt: nil
        )
    }

    private func makeFact(
        id: UUID = UUID(),
        subjectEntityId: UUID? = nil,
        predicate: String,
        value: String,
        status: BrainRecordStatus = .active,
        confidence: Double = 1.0,
        updatedAt: Date = Date(timeIntervalSince1970: 100)
    ) -> BrainFact {
        BrainFact(
            id: id,
            subjectEntityId: subjectEntityId,
            predicate: predicate,
            value: value,
            status: status,
            confidence: confidence,
            createdAt: Date(timeIntervalSince1970: 50),
            updatedAt: updatedAt,
            lastConfirmedAt: updatedAt,
            supersedesFactId: nil
        )
    }
}

private actor FakeBrainRetrievalSource: BrainRetrievalSource {
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
        Array(memories.prefix(limit))
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
