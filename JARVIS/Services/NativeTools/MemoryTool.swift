// JARVIS - MemoryTool.swift
// Persistent voice-writable memory backed by SettingsManager.settings.memories.

import Foundation

struct MemoryTool: NativeTool {
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
        let action = (args["action"] as? String ?? "list").lowercased()

        switch action {
        case "remember":
            let value = (args["value"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return "Qual informação você quer que eu lembre?" }

            var key = Self.cleanKey(args["key"] as? String ?? "")
            if key.isEmpty {
                key = "memoria_" + Self.timestampKey()
            }

            await MainActor.run {
                SettingsManager.shared.setMemory(key: key, value: value)
                SettingsManager.shared.saveNow()
                DiagnosticLogger.shared.log("Memory", "Persistent memory saved key=\(key)")
            }
            return "Memória salva permanentemente com a chave \(key)."

        case "get":
            let key = Self.cleanKey(args["key"] as? String ?? "")
            guard !key.isEmpty else { return "Qual memória devo consultar?" }
            let value = await MainActor.run { SettingsManager.shared.settings.memories[key] }
            return value.map { "\(key): \($0)" } ?? "Não encontrei a memória \(key)."

        case "search":
            let query = (args["query"] as? String ?? args["key"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard !query.isEmpty else { return "O que devo procurar nas memórias?" }
            let memories = await MainActor.run { SettingsManager.shared.settings.memories }
            let matches = memories
                .filter { $0.key.lowercased().contains(query) || $0.value.lowercased().contains(query) }
                .sorted { $0.key < $1.key }
                .prefix(8)
            guard !matches.isEmpty else { return "Não encontrei memórias sobre \(query)." }
            return matches.map { "\($0.key): \($0.value)" }.joined(separator: "\n")

        case "forget":
            let exactKey = Self.cleanKey(args["key"] as? String ?? "")
            let query = (args["query"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

            if !exactKey.isEmpty {
                let existed = await MainActor.run { SettingsManager.shared.settings.memories[exactKey] != nil }
                guard existed else { return "Não encontrei a memória \(exactKey)." }
                await MainActor.run {
                    SettingsManager.shared.deleteMemory(key: exactKey)
                    SettingsManager.shared.saveNow()
                    DiagnosticLogger.shared.log("Memory", "Persistent memory deleted key=\(exactKey)")
                }
                return "Memória \(exactKey) apagada."
            }

            guard !query.isEmpty else { return "Qual memória você quer que eu esqueça?" }
            let keys = await MainActor.run {
                SettingsManager.shared.settings.memories
                    .filter { $0.key.lowercased().contains(query) || $0.value.lowercased().contains(query) }
                    .map(\.key)
            }
            guard !keys.isEmpty else { return "Não encontrei memórias sobre \(query)." }
            await MainActor.run {
                for key in keys { SettingsManager.shared.deleteMemory(key: key) }
                SettingsManager.shared.saveNow()
                DiagnosticLogger.shared.log("Memory", "Persistent memories deleted count=\(keys.count)")
            }
            return "Apaguei \(keys.count) memória(s) relacionadas a \(query)."

        default:
            let memories = await MainActor.run { SettingsManager.shared.settings.memories }
            guard !memories.isEmpty else { return "Ainda não tenho memórias persistentes." }
            let top = memories.sorted { $0.key < $1.key }.prefix(12)
            return top.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
        }
    }

    private static func cleanKey(_ raw: String) -> String {
        let folded = raw
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "pt_BR"))
            .lowercased()
        let cleaned = folded
            .replacingOccurrences(of: "[^a-z0-9_]+", with: "_", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return String(cleaned.prefix(64))
    }

    private static func timestampKey() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return formatter.string(from: Date())
    }
}
