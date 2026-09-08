import Foundation

enum BrainRecordStatus: String, Codable, CaseIterable, Sendable {
    case candidate
    case active
    case superseded
    case forgotten
    case conflictPending = "conflict_pending"
}

enum BrainMemoryKind: String, Codable, CaseIterable, Sendable {
    case coreProfile = "core_profile"
    case semantic
    case episodic
    case preference
}

enum BrainEntityType: String, Codable, CaseIterable, Sendable {
    case user, person, organization, place, thing, concept
}

enum BrainProvenanceSource: String, Codable, CaseIterable, Sendable {
    case explicitUser = "explicit_user"
    case legacyImport = "legacy_import"
    case toolResult = "tool_result"
    case systemSeed = "system_seed"
    case inference
    case manualEdit = "manual_edit"
}

enum LearningEventType: String, Codable, CaseIterable, Sendable {
    case explicitCorrection = "explicit_correction"
    case explicitPreference = "explicit_preference"
    case confirmation
    case aliasAdded = "alias_added"
    case merge
    case forget
    case legacyImport = "legacy_import"
    case manualEdit = "manual_edit"
}

enum BiometricKind: String, Codable, CaseIterable, Sendable {
    case face, speaker
}

enum BrainValidationError: Error, Equatable {
    case valueOutsideUnitInterval(field: String, value: Double)
}

enum BrainValidation {
    @discardableResult
    static func unitInterval(_ value: Double, field: String) throws -> Double {
        guard (0.0...1.0).contains(value) else {
            throw BrainValidationError.valueOutsideUnitInterval(field: field, value: value)
        }
        return value
    }
}

enum BrainLegacyKey {
    static func normalize(_ raw: String) -> String {
        let folded = raw
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "pt_BR"))
            .lowercased()
        let cleaned = folded
            .replacingOccurrences(of: "[^a-z0-9_]+", with: "_", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return String(cleaned.prefix(64))
    }

    static func searchText(_ raw: String) -> String {
        raw.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "pt_BR"))
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
