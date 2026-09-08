// JARVIS - MemoryTool.swift
// Persistent voice-writable memory backed by the canonical BrainService.

import Foundation

struct MemoryTool: NativeTool {
    private let brain: BrainService

    init(brain: BrainService = .shared) {
        self.brain = brain
    }

    let name = "memory"
    let description = """
    Save, search, list, read, or forget persistent JARVIS memories. Use this only when the user     explicitly wants JARVIS to remember/store a stable fact, or asks what JARVIS remembers.     Conversation context alone is temporary and must never be described as saved memory.
    """

    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "action": [
                "type": "string",
                "enum": ["remember", "get", "search", "list", "forget"]
            ],
            "key": [
                "type": "string",
                "description": "Short stable identifier, e.g. user_role, favorite_team, person_caua_role."
            ],
            "value": [
                "type": "string",
                "description": "Fact to store for remember."
            ],
            "query": [
                "type": "string",
                "description": "Keyword for search/forget when an exact key is unknown."
            ]
        ],
        "required": ["action"]
    ]

    func execute(args: [String: Any]) async throws -> String {
        do {
            return try await executeWithBrain(args: args)
        } catch BrainStoreError.notInitialized {
            return "A memória persistente está temporariamente indisponível."
        }
    }

    private func executeWithBrain(args: [String: Any]) async throws -> String {
        let action = (args["action"] as? String ?? "list").lowercased()

        switch action {
        case "remember":
            let value = (args["value"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return "Qual informação você quer que eu lembre?" }

            var key = BrainLegacyKey.normalize(args["key"] as? String ?? "")
            if key.isEmpty {
                key = "memoria_" + Self.timestampKey()
            }

            _ = try await brain.rememberLegacy(
                key: key,
                value: value,
                source: .explicitUser
            )
            return "Memória salva permanentemente com a chave \(key)."

        case "get":
            let key = BrainLegacyKey.normalize(args["key"] as? String ?? "")
            guard !key.isEmpty else { return "Qual memória devo consultar?" }

            let memory = try await brain.memory(legacyKey: key)
            return memory.map { "\(key): \($0.content)" } ?? "Não encontrei a memória \(key)."

        case "search":
            let query = (args["query"] as? String ?? args["key"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else { return "O que devo procurar nas memórias?" }

            let matches = try await brain.searchActiveMemories(query: query, limit: 8)
            guard !matches.isEmpty else { return "Não encontrei memórias sobre \(query)." }
            return matches.map(Self.formatMemory).joined(separator: "\n")

        case "forget":
            let exactKey = BrainLegacyKey.normalize(args["key"] as? String ?? "")
            let query = (args["query"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if !exactKey.isEmpty {
                let forgotten = try await brain.forgetLegacy(
                    key: exactKey,
                    source: .explicitUser
                )
                guard forgotten else { return "Não encontrei a memória \(exactKey)." }
                return "Memória \(exactKey) apagada."
            }

            guard !query.isEmpty else { return "Qual memória você quer que eu esqueça?" }
            let forgottenCount = try await brain.forgetMemories(
                matching: query,
                source: .explicitUser
            )
            guard forgottenCount > 0 else { return "Não encontrei memórias sobre \(query)." }
            return "Apaguei \(forgottenCount) memória(s) relacionadas a \(query)."

        default:
            let memories = try await brain.listActiveMemories(limit: 12)
            guard !memories.isEmpty else { return "Ainda não tenho memórias persistentes." }
            return memories.map(Self.formatMemory).joined(separator: "\n")
        }
    }

    private static func formatMemory(_ memory: BrainMemory) -> String {
        let label = memory.legacyKey ?? memory.id.uuidString.lowercased()
        return "\(label): \(memory.content)"
    }

    private static func timestampKey() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return formatter.string(from: Date())
    }
}
