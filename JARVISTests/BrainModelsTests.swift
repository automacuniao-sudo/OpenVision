import XCTest
@testable import JARVIS

final class BrainModelsTests: XCTestCase {
    func testLifecycleValuesAreStable() {
        XCTAssertEqual(BrainRecordStatus.allCases.map(\.rawValue), [
            "candidate", "active", "superseded", "forgotten", "conflict_pending"
        ])
        XCTAssertEqual(BrainMemoryKind.allCases.map(\.rawValue), [
            "core_profile", "semantic", "episodic", "preference"
        ])
    }

    func testConfidenceRejectsValuesOutsideUnitInterval() {
        XCTAssertNoThrow(try BrainValidation.unitInterval(0.0, field: "confidence"))
        XCTAssertNoThrow(try BrainValidation.unitInterval(1.0, field: "confidence"))
        XCTAssertThrowsError(try BrainValidation.unitInterval(-0.01, field: "confidence"))
        XCTAssertThrowsError(try BrainValidation.unitInterval(1.01, field: "confidence"))
    }

    func testLegacyKeyNormalizationMatchesExistingToolSemantics() {
        XCTAssertEqual(BrainLegacyKey.normalize(" João do Financeiro "), "joao_do_financeiro")
        XCTAssertEqual(BrainLegacyKey.normalize("USER-ROLE"), "user_role")
        XCTAssertEqual(BrainLegacyKey.normalize("___"), "")
    }

    func testSearchTextIsCaseAndDiacriticInsensitive() {
        XCTAssertEqual(BrainLegacyKey.searchText("Café São João"), "cafe sao joao")
    }

    func testPersonIdentityDoesNotDependOnDisplayName() {
        let id = UUID()
        let now = Date()
        let profile = PersonProfile(
            id: id,
            displayName: "João",
            createdAt: now,
            updatedAt: now,
            firstSeenAt: nil,
            lastSeenAt: nil,
            status: .active,
            confidence: 1.0
        )
        XCTAssertEqual(profile.id, id)
        XCTAssertEqual(profile.displayName, "João")
    }
}
