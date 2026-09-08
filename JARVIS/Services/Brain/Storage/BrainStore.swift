import Foundation

protocol BrainStore: Sendable {
    func initialize() async throws

    func metadataValue(for key: String) async throws -> String?
    func setMetadataValue(_ value: String, for key: String, at: Date) async throws

    func createMemory(_ memory: BrainMemory, provenance: BrainProvenanceInput) async throws -> BrainMemory
    func updateMemoryContent(
        id: UUID,
        content: String,
        at: Date,
        provenance: BrainProvenanceInput
    ) async throws -> BrainMemory
    func memory(id: UUID) async throws -> BrainMemory?
    func memory(legacyKey: String) async throws -> BrainMemory?
    func listMemories(
        statuses: Set<BrainRecordStatus>,
        limit: Int
    ) async throws -> [BrainMemory]
    func searchMemories(
        query: String,
        statuses: Set<BrainRecordStatus>,
        limit: Int
    ) async throws -> [BrainMemory]
    func forgetMemory(
        id: UUID,
        at: Date,
        provenance: BrainProvenanceInput
    ) async throws -> Bool
    func forgetMemories(
        matching query: String,
        at: Date,
        provenance: BrainProvenanceInput
    ) async throws -> Int
    func importLegacyMemories(_ memories: [String: String], at: Date) async throws -> Int

    func createEntity(_ entity: BrainEntity) async throws -> BrainEntity
    func entity(id: UUID) async throws -> BrainEntity?
    func createPersonProfile(
        _ profile: PersonProfile,
        entity: BrainEntity
    ) async throws -> PersonProfile
    func personProfile(id: UUID) async throws -> PersonProfile?
    func listPersonProfiles(limit: Int) async throws -> [PersonProfile]
    func addAlias(
        _ alias: PersonAlias,
        provenance: BrainProvenanceInput
    ) async throws -> PersonAlias
    func aliases(personId: UUID) async throws -> [PersonAlias]
    func addBiometricReference(
        _ reference: BiometricReference,
        provenance: BrainProvenanceInput
    ) async throws -> BiometricReference
    func biometricReferences(personId: UUID) async throws -> [BiometricReference]

    func createFact(
        _ fact: BrainFact,
        provenance: BrainProvenanceInput
    ) async throws -> BrainFact
    func facts(
        subjectEntityId: UUID?,
        statuses: Set<BrainRecordStatus>
    ) async throws -> [BrainFact]
    func supersedeFact(
        oldFactId: UUID,
        with newFact: BrainFact,
        at: Date,
        provenance: BrainProvenanceInput
    ) async throws -> BrainFact

    func createRelation(
        _ relation: BrainRelation,
        provenance: BrainProvenanceInput
    ) async throws -> BrainRelation
    func relations(
        entityId: UUID,
        statuses: Set<BrainRecordStatus>
    ) async throws -> [BrainRelation]

    func appendLearningEvent(_ event: LearningEvent) async throws -> LearningEvent
    func learningEvents(targetRecordId: UUID?, limit: Int) async throws -> [LearningEvent]
}
